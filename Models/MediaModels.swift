import Foundation

/// Concurrent file tasks, not CPU affinity or reserved cores.
enum WorkerConcurrency {
    static let defaultCount = 4

    static func limit(_ requested: Int,
                      activeProcessorCount: Int = ProcessInfo.processInfo.activeProcessorCount) -> Int {
        min(max(requested, 1), max(activeProcessorCount, 1))
    }

    /// Keep unfinished/non-integer edits visible so the UI can disable Start.
    /// Integer edits (including pasted values and overflow) clamp immediately.
    static func normalizedInput(_ text: String,
                                activeProcessorCount: Int = ProcessInfo.processInfo.activeProcessorCount) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = Int(trimmed) {
            return String(limit(number, activeProcessorCount: activeProcessorCount))
        }
        let digits = trimmed.hasPrefix("-") || trimmed.hasPrefix("+") ? String(trimmed.dropFirst()) : trimmed
        if !digits.isEmpty && digits.utf8.allSatisfy({ (48...57).contains($0) }) {
            return trimmed.hasPrefix("-") ? "1" : String(max(activeProcessorCount, 1))
        }
        return text
    }

    static func validatedCount(_ text: String,
                               activeProcessorCount: Int = ProcessInfo.processInfo.activeProcessorCount) -> Int? {
        guard let number = Int(text), (1...max(activeProcessorCount, 1)).contains(number) else { return nil }
        return number
    }
}

/// The visible count and fill ratio always describe the same completed work.
struct FileWorkProgress {
    let completed: Int
    let total: Int

    init(completed: Int = 0, total: Int = 0) {
        self.total = max(total, 0)
        self.completed = min(max(completed, 0), self.total)
    }

    var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
    var countText: String { "\(completed)/\(total)" }
}

final class WorkCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func check() throws {
        if isCancelled {
            throw WorkCancellationError.cancelled
        }
    }
}

enum WorkCancellationError: LocalizedError {
    case cancelled
    case afterFileProcessing

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Task cancelled by the user before any files were changed."
        case .afterFileProcessing:
            return "Renaming and sorting had already finished when cancellation was requested. Those results were kept; HEIC/AVIF conversion did not begin."
        }
    }
}

enum MediaKind: String, Codable, CaseIterable {
    case jpeg
    case raw
    case video
}

struct MediaItem: Identifiable, Hashable {
    let id: UUID
    let sourceURL: URL
    let originalStem: String
    let fileExtension: String
    let kind: MediaKind
    let captureDate: Date
    let captureDateDetails: String
    /// Absolute capture instant, when the original metadata contains an offset.
    /// Retains which occurrence of a repeated DST wall-clock hour was captured.
    let captureInstant: Date?

    init(
        id: UUID = UUID(),
        sourceURL: URL,
        originalStem: String,
        fileExtension: String,
        kind: MediaKind,
        captureDate: Date,
        captureDateDetails: String = "",
        captureInstant: Date? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.originalStem = originalStem
        self.fileExtension = fileExtension
        self.kind = kind
        self.captureDate = captureDate
        self.captureDateDetails = captureDateDetails
        self.captureInstant = captureInstant
    }
}

/// 같은 원본 stem을 가진 JPG/RAW 등의 묶음입니다.
/// 시퀀스 번호는 파일이 아니라 이 Shot 단위로 증가합니다.
struct MediaShot: Identifiable, Hashable {
    let id: String
    let originalStem: String
    let captureDate: Date
    let sequenceIndex: Int
    let items: [MediaItem]
}

struct RenamePlanItem: Identifiable, Hashable {
    let id: UUID
    let mediaItem: MediaItem
    let shotID: String
    let sequenceIndex: Int
    let destinationURL: URL
    let shouldRename: Bool

    init(
        id: UUID = UUID(),
        mediaItem: MediaItem,
        shotID: String,
        sequenceIndex: Int,
        destinationURL: URL,
        shouldRename: Bool
    ) {
        self.id = id
        self.mediaItem = mediaItem
        self.shotID = shotID
        self.sequenceIndex = sequenceIndex
        self.destinationURL = destinationURL
        self.shouldRename = shouldRename
    }
}

struct RenameCollision: Identifiable, Hashable {
    let id: UUID
    let destinationURL: URL
    let sourceURLs: [URL]
    let reason: String

    init(
        id: UUID = UUID(),
        destinationURL: URL,
        sourceURLs: [URL],
        reason: String
    ) {
        self.id = id
        self.destinationURL = destinationURL
        self.sourceURLs = sourceURLs
        self.reason = reason
    }
}

struct CaptureTimeZoneSummary: Identifiable, Hashable {
    let offsetSeconds: Int?
    let imageCount: Int
    let videoCount: Int

    var id: String {
        offsetSeconds.map(String.init) ?? "unknown"
    }

    var fileCount: Int {
        imageCount + videoCount
    }
}

struct MetadataReadWarning: Identifiable, Hashable {
    let id: UUID
    let sourceURL: URL
    let cameraName: String?
    let message: String

    init(
        id: UUID = UUID(),
        sourceURL: URL,
        cameraName: String? = nil,
        message: String
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.cameraName = cameraName
        self.message = message
    }
}

enum StageOneAnalysisPhase: Equatable, Sendable {
    case checkingFiles, readingMetadata, planning
}

struct StageOneAnalysisObserver {
    let phaseChanged: (StageOneAnalysisPhase) -> Void
    init(_ phaseChanged: @escaping (StageOneAnalysisPhase) -> Void) {
        self.phaseChanged = phaseChanged
    }
}

/// Immutable, in-memory, per-workflow data. No pixels or persistent cache.
/// Raw tag provenance is retained so Nikon/DST/video interpretation is identical
/// whether the user selects a time zone before or after the first metadata read.
final class StageOneMetadataSnapshot {
    let folderPath: String
    let bundlePath: String
    let calendar: Calendar
    let filePaths: [String]
    let fingerprints: [String: [Int64]]
    let records: [[String: Any]]
    let readWarnings: [MetadataReadWarning]
    let exifToolVersion: String?
    let fallbackItems: [String: MediaItem]
    let parsedDates: [String: Date]
    let unparseableDates: Set<String>

    init(folderPath: String, bundlePath: String, calendar: Calendar,
         filePaths: [String], fingerprints: [String: [Int64]], records: [[String: Any]],
         readWarnings: [MetadataReadWarning], exifToolVersion: String?, fallbackItems: [String: MediaItem],
         parsedDates: [String: Date], unparseableDates: Set<String>) {
        self.folderPath = folderPath
        self.bundlePath = bundlePath
        self.calendar = calendar
        self.filePaths = filePaths
        self.fingerprints = fingerprints
        self.records = records
        self.readWarnings = readWarnings
        self.exifToolVersion = exifToolVersion
        self.fallbackItems = fallbackItems
        self.parsedDates = parsedDates
        self.unparseableDates = unparseableDates
    }
}

struct StageOneResult {
    let mediaItems: [MediaItem]
    let shots: [MediaShot]
    let renamePlan: [RenamePlanItem]
    let collisions: [RenameCollision]
    let timeZoneSummaries: [CaptureTimeZoneSummary]
    let metadataWarnings: [MetadataReadWarning]
    let exifToolVersion: String?
    /// nil이면 카메라에 기록된 시간대를 그대로 사용합니다.
    /// 값이 있으면 Stage 2에서 처리본 메타데이터도 이 IANA 시간대로 갱신합니다.
    let timeZoneOverrideIdentifier: String?
    let applyDaylightSavingTime: Bool
    /// Released by the UI when the workflow finishes/cancels.
    var metadataSnapshot: StageOneMetadataSnapshot?
    let reusedMetadata: Bool

    init(
        mediaItems: [MediaItem],
        shots: [MediaShot],
        renamePlan: [RenamePlanItem],
        collisions: [RenameCollision],
        timeZoneSummaries: [CaptureTimeZoneSummary],
        metadataWarnings: [MetadataReadWarning] = [],
        exifToolVersion: String? = nil,
        timeZoneOverrideIdentifier: String?,
        applyDaylightSavingTime: Bool = true,
        metadataSnapshot: StageOneMetadataSnapshot? = nil,
        reusedMetadata: Bool = false
    ) {
        self.mediaItems = mediaItems
        self.shots = shots
        self.renamePlan = renamePlan
        self.collisions = collisions
        self.timeZoneSummaries = timeZoneSummaries
        self.metadataWarnings = metadataWarnings
        self.exifToolVersion = exifToolVersion
        self.timeZoneOverrideIdentifier = timeZoneOverrideIdentifier
        self.applyDaylightSavingTime = applyDaylightSavingTime
        self.metadataSnapshot = metadataSnapshot
        self.reusedMetadata = reusedMetadata
    }

    var canContinue: Bool {
        collisions.isEmpty
    }

    var renameCount: Int {
        renamePlan.filter(\.shouldRename).count
    }

    var skippedRenameCount: Int {
        renamePlan.count - renameCount
    }
}

enum StageOneAnalyzerError: LocalizedError {
    case folderDoesNotExist
    case selectedURLIsNotFolder
    case cannotReadFolder(String)

    var errorDescription: String? {
        switch self {
        case .folderDoesNotExist:
            return "The selected folder could not be found."
        case .selectedURLIsNotFolder:
            return "The selected item is not a folder."
        case .cannotReadFolder(let message):
            return "Cannot read the folder: \(message)"
        }
    }
}

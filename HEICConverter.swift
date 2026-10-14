import Foundation
import ImageIO
import UniformTypeIdentifiers
import Darwin

enum EfficientImageFormat: String, CaseIterable, Identifiable {
    case heic
    case avif

    var id: String { rawValue }
    var displayName: String { rawValue.uppercased() }
    var typeIdentifier: String {
        switch self {
        case .heic: return "public.heic"
        case .avif: return "public.avif"
        }
    }
    var folderName: String { displayName }
    var fileExtension: String { rawValue }
}

struct StageThreeResult {
    let convertedCount: Int
    let skippedCount: Int
    let peakConcurrentTasks: Int
    init(convertedCount: Int, skippedCount: Int, peakConcurrentTasks: Int = 0) {
        self.convertedCount = convertedCount
        self.skippedCount = skippedCount
        self.peakConcurrentTasks = peakConcurrentTasks
    }
}

enum HEICConverterError: LocalizedError {
    case invalidQuality
    case sourceFileMissing(String)
    case duplicateDestination(String)
    case destinationAlreadyExists(String)
    case cannotOpenSource(String)
    case cannotCreateDestination(String)
    case cannotFinalize(String)
    case cannotWriteOutput(String)
    case cannotWriteRotation(String)
    case cancelled(removedCount: Int)
    case rollbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidQuality:
            return "Image quality must be between 1 and 100."
        case .sourceFileMissing(let filename):
            return "Conversion source file not found: \(filename)"
        case .duplicateDestination(let filename):
            return "Multiple shots have the same HEIC/AVIF destination: \(filename)"
        case .destinationAlreadyExists(let filename):
            return "A HEIC/AVIF file with the same name already exists: \(filename)"
        case .cannotOpenSource(let filename):
            return "Cannot open the image: \(filename)"
        case .cannotCreateDestination(let filename):
            return "Cannot create the HEIC/AVIF output file: \(filename)"
        case .cannotFinalize(let filename):
            return "HEIC/AVIF conversion could not be completed: \(filename)"
        case .cannotWriteOutput(let filename):
            return "Cannot save the HEIC/AVIF image to the folder: \(filename)"
        case .cannotWriteRotation(let filename):
            return "Cannot save AVIF rotation metadata: \(filename)"
        case .cancelled(let count):
            return "Conversion cancelled. The \(count) files created in this stage were removed. Renaming and sorting results were kept."
        case .rollbackFailed(let detail):
            return "Conversion stopped, but some generated files could not be removed: \(detail). Renaming and sorting results were kept."
        }
    }
}

struct HEICConverter {
    typealias ProgressHandler = (_ completed: Int, _ total: Int) -> Void

    private struct ConversionItem {
        let inputURL: URL
        let outputURL: URL
    }

    private let fileManager: FileManager
    private let bundle: Bundle
    private let workerCount: Int

    init(
        fileManager: FileManager = .default,
        bundle: Bundle = .main,
        workerCount: Int = WorkerConcurrency.defaultCount
    ) {
        self.fileManager = fileManager
        self.bundle = bundle
        self.workerCount = WorkerConcurrency.limit(workerCount)
    }

    /// shot당 선택한 고효율 이미지 한 장을 만듭니다.
    /// Converts only shots containing a JPEG; RAW-only shots are skipped.
    func convert(
        stageOneResult: StageOneResult,
        format: EfficientImageFormat,
        quality: Int,
        cancellationToken: WorkCancellationToken? = nil,
        progress: ProgressHandler? = nil
    ) throws -> StageThreeResult {
        try cancellationToken?.check()
        guard (1...100).contains(quality) else {
            throw HEICConverterError.invalidQuality
        }

        let planByMediaID = Dictionary(
            uniqueKeysWithValues: stageOneResult.renamePlan.map {
                ($0.mediaItem.id, $0)
            }
        )

        var conversionItems: [ConversionItem] = []
        conversionItems.reserveCapacity(stageOneResult.shots.count)

        for shot in stageOneResult.shots {
            try cancellationToken?.check()
            let candidates = shot.items
                .filter { $0.kind == .jpeg }
                .sorted { left, right in
                    left.sourceURL.lastPathComponent
                        .localizedStandardCompare(
                            right.sourceURL.lastPathComponent
                        ) == .orderedAscending
                }


            guard let selectedItem = candidates.first,
                  let renamePlan = planByMediaID[selectedItem.id] else {
                continue
            }

            let inputURL = renamePlan.destinationURL
            let workFolderURL = inputURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let outputFolderURL = workFolderURL.appendingPathComponent(
                format.folderName,
                isDirectory: true
            )
            let outputURL = outputFolderURL
                .appendingPathComponent(inputURL.lastPathComponent)
                .deletingPathExtension()
                .appendingPathExtension(format.fileExtension)

            conversionItems.append(
                ConversionItem(
                    inputURL: inputURL,
                    outputURL: outputURL
                )
            )
        }

        try preflight(
            conversionItems,
            cancellationToken: cancellationToken
        )

        let total = conversionItems.count
        progress?(0, total)
        guard !conversionItems.isEmpty else {
            return StageThreeResult(
                convertedCount: 0,
                skippedCount: stageOneResult.shots.count
            )
        }

        let outputDirectories = Set(conversionItems.map {
            $0.outputURL.deletingLastPathComponent()
        })
        do {
            for directory in outputDirectories {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
            }
        } catch {
            throw HEICConverterError.cannotWriteOutput(format.folderName)
        }

        let state = ConversionState(total: total, progress: progress)
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "com.byastra.photomuri.image-workers", qos: .userInitiated, attributes: .concurrent)
        let items = conversionItems
        for _ in 0..<min(workerCount, total) {
            group.enter()
            queue.async {
                defer { group.leave() }
                let worker = HEICConverter(fileManager: FileManager(), bundle: bundle, workerCount: 1)
                // A session must never be shared by concurrent AVIF writers.
                let rotationSession = format == .avif ? bundle.url(
                    forResource: "exiftool", withExtension: nil, subdirectory: "ExifTool"
                ).map { ExifToolSession(toolURL: $0) } : nil
                defer { rotationSession?.close() }
                let cancelled = { state.stop.isCancelled || cancellationToken?.isCancelled == true }
                while let index = state.claim(cancelled: cancelled()) {
                    let item = items[index]
                    do {
                        try autoreleasepool {
                            if cancelled() { throw WorkCancellationError.cancelled }
                            // ImageIO may create additional private temporary files
                            // on interrupted encoding. Own the entire staging folder
                            // so none of those partial files escape rollback.
                            let staging = item.outputURL.deletingLastPathComponent().appendingPathComponent(
                                ".photomuri-convert-\(UUID().uuidString)", isDirectory: true)
                            guard Darwin.mkdir(staging.path, S_IRWXU) == 0 else {
                                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                            }
                            state.record(staging)
                            let temporary = staging.appendingPathComponent("output.\(format.fileExtension)")
                            try worker.convertOne(inputURL: item.inputURL, outputURL: temporary,
                                format: format, quality: quality, rotationSession: rotationSession, cancelled: cancelled)
                            if cancelled() { throw WorkCancellationError.cancelled }
                            // Do not overwrite a destination created since preflight.
                            // Only paths actually published by us enter rollback.
                            try worker.fileManager.moveItem(at: temporary, to: item.outputURL)
                            state.record(item.outputURL, published: true)
                            try worker.fileManager.removeItem(at: staging)
                            if cancelled() { throw WorkCancellationError.cancelled }
                            state.finish()
                        }
                    } catch {
                        if error is WorkCancellationError { state.fail(error) }
                        else {
                            let original = error as NSError
                            state.fail(NSError(domain: original.domain, code: original.code, userInfo: [
                                NSLocalizedDescriptionKey: "3/3 \(format.displayName) conversion — \(item.inputURL.lastPathComponent): \(original.localizedDescription) [\(original.domain) code \(original.code)]",
                                NSUnderlyingErrorKey: original, "PhotomuriStage": "3/3 conversion"
                            ]))
                        }
                    }
                }
            }
        }
        // Wait for native encoding, all child writers and session shutdown before
        // deleting outputs. Native ImageIO calls cannot be interrupted midway.
        group.wait()
        let failure = state.error ?? (cancellationToken?.isCancelled == true ? WorkCancellationError.cancelled : nil)
        if let failure {
            var cleanupErrors: [String] = []
            for url in state.artifacts.reversed() where fileManager.fileExists(atPath: url.path) {
                do { try fileManager.removeItem(at: url) }
                catch { cleanupErrors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            if !cleanupErrors.isEmpty { throw HEICConverterError.rollbackFailed(cleanupErrors.joined(separator: " / ")) }
            if failure is WorkCancellationError { throw HEICConverterError.cancelled(removedCount: state.publishedCount) }
            throw failure
        }

        return StageThreeResult(
            convertedCount: conversionItems.count,
            skippedCount: stageOneResult.shots.count - conversionItems.count,
            peakConcurrentTasks: state.peak
        )
    }

    private func preflight(
        _ items: [ConversionItem],
        cancellationToken: WorkCancellationToken?
    ) throws {
        let grouped = Dictionary(grouping: items) {
            pathKey($0.outputURL)
        }

        if let duplicate = grouped.values.first(where: { $0.count > 1 }) {
            throw HEICConverterError.duplicateDestination(
                duplicate[0].outputURL.lastPathComponent
            )
        }

        for item in items {
            try cancellationToken?.check()
            guard fileManager.fileExists(atPath: item.inputURL.path) else {
                throw HEICConverterError.sourceFileMissing(
                    item.inputURL.lastPathComponent
                )
            }

            if fileManager.fileExists(atPath: item.outputURL.path) {
                throw HEICConverterError.destinationAlreadyExists(
                    item.outputURL.lastPathComponent
                )
            }
        }
    }

    private func convertOne(
        inputURL: URL,
        outputURL: URL,
        format: EfficientImageFormat,
        quality: Int,
        rotationSession: ExifToolSession?,
        cancelled: () -> Bool
    ) throws {
        if cancelled() { throw WorkCancellationError.cancelled }
        guard let source = CGImageSourceCreateWithURL(
            inputURL as CFURL,
            nil
        ) else {
            throw HEICConverterError.cannotOpenSource(
                inputURL.lastPathComponent
            )
        }

        // Encode straight to our unique temporary file rather than retaining a
        // second full compressed-output buffer per concurrent image in memory.
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            format.typeIdentifier as CFString,
            1,
            nil
        ) else {
            throw HEICConverterError.cannotCreateDestination(
                outputURL.lastPathComponent
            )
        }

        let options = [
            kCGImageDestinationLossyCompressionQuality:
                Double(quality) / 100.0
        ] as CFDictionary

        CGImageDestinationAddImageFromSource(
            destination,
            source,
            0,
            options
        )

        if cancelled() { throw WorkCancellationError.cancelled }
        guard CGImageDestinationFinalize(destination) else {
            throw HEICConverterError.cannotFinalize(
                outputURL.lastPathComponent
            )
        }

        if cancelled() { throw WorkCancellationError.cancelled }

        if format == .avif,
           let rotation = containerRotation(from: source),
           rotation != 0 {
            do {
                try writeAVIFContainerRotation(
                    rotation,
                    to: outputURL,
                    session: rotationSession,
                    cancelled: cancelled
                )
            } catch {
                try? fileManager.removeItem(at: outputURL)
                throw error
            }
        }
    }

    private func containerRotation(
        from source: CGImageSource
    ) -> Int? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(
            source,
            0,
            nil
        ) as? [CFString: Any],
        let value = properties[kCGImagePropertyOrientation] as? NSNumber else {
            return nil
        }

        switch value.intValue {
        case 1: return 0
        case 3: return 180
        case 6: return 90
        case 8: return 270
        default: return nil
        }
    }

    private func writeAVIFContainerRotation(
        _ rotation: Int,
        to outputURL: URL,
        session: ExifToolSession?,
        cancelled: () -> Bool
    ) throws {
        guard let session else {
            throw HEICConverterError.cannotWriteRotation(
                outputURL.lastPathComponent
            )
        }

        let arguments = [
            "-overwrite_original_in_place",
            "-QuickTime:Rotation=\(rotation)",
            outputURL.path
        ]
        let toolTemporary = URL(fileURLWithPath: outputURL.path + "_exiftool_tmp")
        guard !fileManager.fileExists(atPath: toolTemporary.path) else {
            throw HEICConverterError.cannotWriteRotation(toolTemporary.lastPathComponent)
        }
        defer { try? fileManager.removeItem(at: toolTemporary) }
        let result = try session.run(arguments: arguments,
            stage: "3/3 AVIF rotation", filenames: [outputURL.lastPathComponent],
            cancelled: cancelled)
        guard result.status == 0 else {
            let detail = (result.error.isEmpty ? result.output : result.error)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message = "3/3 AVIF rotation — \(outputURL.lastPathComponent), ExifTool exit \(result.status): \(detail)"
            throw HEICConverterError.cannotWriteRotation(message)
        }
    }

    private final class ConversionState: @unchecked Sendable {
        private let lock = NSRecursiveLock()
        private let total: Int
        private let progress: ProgressHandler?
        private var next = 0, active = 0, highest = 0, completed = 0, published = 0
        private var urls: [URL] = []
        private var failure: Error?
        let stop = WorkCancellationToken()
        init(total: Int, progress: ProgressHandler?) { self.total = total; self.progress = progress }
        func claim(cancelled: Bool) -> Int? {
            lock.lock(); defer { lock.unlock() }
            if cancelled && failure == nil { failure = WorkCancellationError.cancelled; stop.cancel() }
            guard failure == nil, next < total else { return nil }
            defer { next += 1 }
            active += 1; highest = max(highest, active)
            return next
        }
        func record(_ url: URL, published: Bool = false) {
            lock.lock(); defer { lock.unlock() }
            urls.append(url); if published { self.published += 1 }
        }
        func finish() {
            lock.lock(); defer { lock.unlock() }
            active -= 1; completed += 1
            progress?(completed, total)
        }
        func fail(_ error: Error) {
            lock.lock(); defer { lock.unlock() }
            active -= 1
            if failure == nil { failure = error }
            stop.cancel()
        }
        var error: Error? { lock.lock(); defer { lock.unlock() }; return failure }
        var artifacts: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
        var publishedCount: Int { lock.lock(); defer { lock.unlock() }; return published }
        var peak: Int { lock.lock(); defer { lock.unlock() }; return highest }
    }

    private func pathKey(_ url: URL) -> String {
        url.standardizedFileURL.path.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
    }
}

import Foundation
import Darwin

struct StageTwoResult {
    let classifiedCount: Int
    let renamedCount: Int
    let copiedCount: Int
    let metadataUpdatedCount: Int
    let skippedCount: Int
}

struct WorkSafetyPreflightResult {
    let requiredBytes: Int64
    let availableBytes: Int64
}

enum WorkSafetyPreflightError: LocalizedError {
    case cannotWrite(String)
    case cannotReadFileSize(String)
    case cannotReadAvailableCapacity
    case insufficientSpace(required: Int64, available: Int64)

    var errorDescription: String? {
        switch self {
        case .cannotWrite(let message):
            return "Cannot write to the working folder: \(message)"
        case .cannotReadFileSize(let filename):
            return "Cannot determine the file size: \(filename)"
        case .cannotReadAvailableCapacity:
            return "Cannot determine the available disk space."
        case .insufficientSpace(let required, let available):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return "Insufficient disk space. Approximately \(formatter.string(fromByteCount: required)) required; \(formatter.string(fromByteCount: available)) available."
        }
    }
}

struct WorkSafetyPreflight {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func validate(
        workFolderURL: URL,
        stageOneResult: StageOneResult,
        preserveOriginals: Bool,
        updateCaptureMetadata: Bool,
        createEfficientVersion: Bool,
        cancellationToken: WorkCancellationToken? = nil
    ) throws -> WorkSafetyPreflightResult {
        try cancellationToken?.check()

        try verifyWriteAccess(to: workFolderURL)

        let allBytes = try stageOneResult.mediaItems.reduce(Int64(0)) {
            partial, item in
            try cancellationToken?.check()
            return partial + (try fileSize(at: item.sourceURL))
        }

        let metadataNeedsCopy = updateCaptureMetadata &&
        stageOneResult.timeZoneOverrideIdentifier != nil
        let stageTwoBytes = (preserveOriginals || metadataNeedsCopy)
        ? allBytes
        : 0

        var conversionBytes: Int64 = 0
        if createEfficientVersion {
            for shot in stageOneResult.shots {
                try cancellationToken?.check()
                if let jpeg = shot.items.first(where: { $0.kind == .jpeg }) {
                    conversionBytes += try fileSize(at: jpeg.sourceURL)
                }
            }
        }

        let estimatedBytes = stageTwoBytes + conversionBytes
        let safetyMargin = max(Int64(256 * 1_024 * 1_024), estimatedBytes / 10)
        let requiredBytes = estimatedBytes + safetyMargin
        let availableBytes = try availableCapacity(at: workFolderURL)
        guard availableBytes >= requiredBytes else {
            throw WorkSafetyPreflightError.insufficientSpace(
                required: requiredBytes,
                available: availableBytes
            )
        }

        return WorkSafetyPreflightResult(
            requiredBytes: requiredBytes,
            availableBytes: availableBytes
        )
    }

    private func verifyWriteAccess(to folderURL: URL) throws {
        let probeURL = folderURL.appendingPathComponent(
            ".media-organizer-write-test-\(UUID().uuidString)"
        )
        do {
            try Data().write(to: probeURL, options: .atomic)
            try fileManager.removeItem(at: probeURL)
        } catch {
            try? fileManager.removeItem(at: probeURL)
            throw WorkSafetyPreflightError.cannotWrite(error.localizedDescription)
        }
    }

    private func fileSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize else {
            throw WorkSafetyPreflightError.cannotReadFileSize(
                url.lastPathComponent
            )
        }
        return Int64(size)
    }

    private func availableCapacity(at folderURL: URL) throws -> Int64 {
        let values = try folderURL.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ])
        if let capacity = values.volumeAvailableCapacityForImportantUsage,
           capacity > 0 {
            return capacity
        }
        if let capacity = values.volumeAvailableCapacity,
           capacity > 0 {
            return Int64(capacity)
        }

        let attributes = try fileManager.attributesOfFileSystem(
            forPath: folderURL.path
        )
        if let number = attributes[.systemFreeSize] as? NSNumber,
           number.int64Value > 0 {
            return number.int64Value
        }
        throw WorkSafetyPreflightError.cannotReadAvailableCapacity
    }
}

enum StageTwoExecutorError: LocalizedError {
    case renamePlanHasCollisions(Int)
    case sourceFileMissing(String)
    case destinationBecameOccupied(String)
    case exifToolUnavailable
    case metadataUpdateFailed(String)
    case fileOperationFailed(String)
    case rollbackFailed(String)
    case cancelled(rolledBackCount: Int)

    var errorDescription: String? {
        switch self {
        case .renamePlanHasCollisions(let count):
            return "Cannot begin processing because \(count) filename conflicts were found."
        case .sourceFileMissing(let filename):
            return "Source file not found: \(filename)"
        case .destinationBecameOccupied(let filename):
            return "A file with the same name appeared after analysis: \(filename)"
        case .exifToolUnavailable:
            return "Cannot update metadata because the bundled ExifTool could not be found."
        case .metadataUpdateFailed(let message):
            return "An error occurred while updating metadata: \(message)"
        case .fileOperationFailed(let message):
            return "An error occurred while processing files: \(message)"
        case .rollbackFailed(let message):
            return "Some files could not be restored after an error: \(message)"
        case .cancelled(let count):
            return "Task cancelled. The \(count) files processed in this stage were restored."
        }
    }
}

struct StageTwoExecutor {
    typealias ProgressHandler = (_ completed: Int, _ total: Int) -> Void

    private struct StagedItem {
        let planItem: RenamePlanItem
        let temporaryURL: URL
    }

    private let fileManager: FileManager
    private let bundle: Bundle
    private let workerCount: Int

    init(fileManager: FileManager = .default, bundle: Bundle = .main,
         workerCount: Int = WorkerConcurrency.defaultCount) {
        self.fileManager = fileManager
        self.bundle = bundle
        self.workerCount = WorkerConcurrency.limit(workerCount)
    }

    func execute(
        stageOneResult: StageOneResult,
        preserveOriginals: Bool,
        updateCaptureMetadata: Bool,
        cancellationToken: WorkCancellationToken? = nil,
        progress: ProgressHandler? = nil
    ) throws -> StageTwoResult {
        try cancellationToken?.check()
        guard stageOneResult.collisions.isEmpty else {
            throw StageTwoExecutorError.renamePlanHasCollisions(
                stageOneResult.collisions.count
            )
        }

        let items = stageOneResult.renamePlan.filter {
            pathKey($0.mediaItem.sourceURL) != pathKey($0.destinationURL)
        }
        progress?(0, items.count)
        guard !items.isEmpty else {
            return StageTwoResult(
                classifiedCount: 0,
                renamedCount: 0,
                copiedCount: 0,
                metadataUpdatedCount: 0,
                skippedCount: stageOneResult.renamePlan.count
            )
        }

        try preflight(items, preserveOriginals: preserveOriginals)
        try cancellationToken?.check()
        do {
            try createDestinationDirectories(for: items)
        } catch {
            throw StageTwoExecutorError.fileOperationFailed(
                "Cannot create the format folder: \(error.localizedDescription)"
            )
        }

        let renamedCount = items.filter(\.shouldRename).count
        let skippedRenameCount = items.count - renamedCount

        let targetTimeZone = updateCaptureMetadata
        ? stageOneResult.timeZoneOverrideIdentifier.flatMap {
            CaptureTimeZonePolicy(identifier: $0,
                                  applyDaylightSavingTime: stageOneResult.applyDaylightSavingTime)
        }
        : nil
        if updateCaptureMetadata,
           stageOneResult.timeZoneOverrideIdentifier != nil,
           targetTimeZone == nil {
            throw StageTwoExecutorError.metadataUpdateFailed(
                "Cannot reload the selected time zone."
            )
        }
        if targetTimeZone != nil { try preflightMetadataArtifacts(items) }

        if preserveOriginals {
            return try executeByCopying(
                items,
                targetTimeZone: targetTimeZone,
                renamedCount: renamedCount,
                skippedCount: skippedRenameCount,
                cancellationToken: cancellationToken,
                progress: progress
            )
        }
        return try executeByMoving(
            items,
            targetTimeZone: targetTimeZone,
            renamedCount: renamedCount,
            skippedCount: skippedRenameCount,
            cancellationToken: cancellationToken,
            progress: progress
        )
    }

    private func executeByCopying(
        _ items: [RenamePlanItem],
        targetTimeZone: CaptureTimeZonePolicy?,
        renamedCount: Int,
        skippedCount: Int,
        cancellationToken: WorkCancellationToken?,
        progress: ProgressHandler?
    ) throws -> StageTwoResult {
        let state = WorkState(total: items.count, progress: progress)

        do {
            try runWorkers(state: state, metadata: targetTimeZone != nil, cancellationToken: cancellationToken) {
                index, session, manager, cancelled in
                let item = items[index]
                if let targetTimeZone, let session {
                    try writeProcessedCopy(from: item.mediaItem.sourceURL, to: item.destinationURL,
                        item: item.mediaItem, targetTimeZone: targetTimeZone, session: session,
                        manager: manager, state: state, cancelled: cancelled)
                } else {
                    try copyForProcessing(from: item.mediaItem.sourceURL, to: item.destinationURL,
                                          manager: manager, state: state)
                }
                if cancelled() { throw WorkCancellationError.cancelled }
                state.finish(metadata: targetTimeZone != nil)
            }
        } catch {
            let cleanupErrors = removeCreatedFiles(state.artifacts)
            if !cleanupErrors.isEmpty {
                throw StageTwoExecutorError.rollbackFailed(
                    cleanupErrors.joined(separator: " / ")
                )
            }
            if error is WorkCancellationError {
                throw StageTwoExecutorError.cancelled(
                    rolledBackCount: state.completed
                )
            }
            throw normalized(error)
        }

        return StageTwoResult(
            classifiedCount: items.count,
            renamedCount: renamedCount,
            copiedCount: items.count,
            metadataUpdatedCount: state.metadataCount,
            skippedCount: skippedCount
        )
    }

    private func executeByMoving(
        _ items: [RenamePlanItem],
        targetTimeZone: CaptureTimeZonePolicy?,
        renamedCount: Int,
        skippedCount: Int,
        cancellationToken: WorkCancellationToken?,
        progress: ProgressHandler?
    ) throws -> StageTwoResult {
        var staged: [StagedItem] = []
        let state = WorkState(total: items.count, progress: progress)

        do {
            for item in items {
                try cancellationToken?.check()
                let temporaryURL = makeTemporaryURL(
                    beside: item.mediaItem.sourceURL,
                    fileExtension: item.mediaItem.fileExtension
                )
                try fileManager.moveItem(at: item.mediaItem.sourceURL, to: temporaryURL)
                staged.append(StagedItem(planItem: item, temporaryURL: temporaryURL))
            }

            let stagedItems = staged
            try runWorkers(state: state, metadata: targetTimeZone != nil, cancellationToken: cancellationToken) {
                index, session, manager, cancelled in
                let stagedItem = stagedItems[index]
                if let targetTimeZone {
                    // 원본 임시본은 모든 메타데이터 쓰기가 끝날 때까지 보관합니다.
                    try writeProcessedCopy(from: stagedItem.temporaryURL, to: stagedItem.planItem.destinationURL,
                        item: stagedItem.planItem.mediaItem, targetTimeZone: targetTimeZone, session: session!,
                        manager: manager, state: state, cancelled: cancelled)
                } else {
                    try manager.moveItem(
                        at: stagedItem.temporaryURL,
                        to: stagedItem.planItem.destinationURL
                    )
                    state.record(stagedItem.planItem.destinationURL)
                }
                if cancelled() { throw WorkCancellationError.cancelled }
                state.finish(metadata: targetTimeZone != nil)
            }
            try cancellationToken?.check()
        } catch {
            let rollbackErrors = rollback(
                staged: staged,
                createdURLs: state.artifacts,
                sidecarURLs: [],
                metadataWasUpdated: targetTimeZone != nil
            )
            if !rollbackErrors.isEmpty {
                throw StageTwoExecutorError.rollbackFailed(
                    rollbackErrors.joined(separator: " / ")
                )
            }
            if error is WorkCancellationError {
                throw StageTwoExecutorError.cancelled(
                    rolledBackCount: max(state.completed, staged.count)
                )
            }
            throw normalized(error)
        }

        // Commit only after all workers have stopped successfully. Once original
        // cleanup starts, never roll back by deleting the successful outputs.
        if targetTimeZone != nil {
            let cleanupErrors = removeCreatedFiles(staged.map(\.temporaryURL))
            if !cleanupErrors.isEmpty {
                throw StageTwoExecutorError.fileOperationFailed(
                    "Processing completed and output files were kept, but some original temporary files could not be removed: " + cleanupErrors.joined(separator: " / "))
            }
        }

        return StageTwoResult(
            classifiedCount: items.count,
            renamedCount: renamedCount,
            copiedCount: 0,
            metadataUpdatedCount: state.metadataCount,
            skippedCount: skippedCount
        )
    }

    /// Export the modified media straight from the preserved/staged source.
    /// Never combine -o with -overwrite_original (that would delete the source).
    /// An atomically-owned private directory contains partial/tool temp files;
    /// only a completed, attribute-restored file is published without overwrite.
    private func writeProcessedCopy(
        from source: URL, to destination: URL, item: MediaItem,
        targetTimeZone: CaptureTimeZonePolicy, session: ExifToolSession,
        manager: FileManager, state: WorkState, cancelled: () -> Bool
    ) throws {
        if metadataSidecar(for: destination, item: item) != nil {
            // Sidecar-only formats still need an unchanged media copy and an
            // XMP export. Keep their existing routing/publication semantics.
            try copyForProcessing(from: source, to: destination, manager: manager, state: state)
            try updateMetadata(at: destination, item: item, targetTimeZone: targetTimeZone,
                               session: session, state: state, cancelled: cancelled)
            return
        }
        let directory = destination.deletingLastPathComponent().appendingPathComponent(".media-organizer-\(UUID())")
        let created = directory.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.mkdir($0, S_IRWXU) } ?? -1
        }
        guard created == 0 else { throw fileProcessingError(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)), source: item.sourceURL) }
        state.record(directory)
        let output = directory.appendingPathComponent("output").appendingPathExtension(item.fileExtension)
        do {
            if cancelled() { throw WorkCancellationError.cancelled }
            let values = metadataValues(wallClockDate: item.captureDate, captureInstant: item.captureInstant,
                                        targetTimeZone: targetTimeZone)
            let tags = item.kind == .video ? videoMetadataArguments(values) : imageMetadataArguments(values)
            let result = try session.run(arguments: ["-o", output.path] + tags + [source.path],
                stage: "2/3 metadata export", filenames: [item.sourceURL.lastPathComponent], cancelled: cancelled)
            guard result.status == 0 else {
                let detail = result.error.isEmpty ? result.output : result.error
                throw StageTwoExecutorError.metadataUpdateFailed(
                    "2/3 metadata export — \(item.sourceURL.lastPathComponent), ExifTool exit \(result.status): \(detail.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            if cancelled() { throw WorkCancellationError.cancelled }
            try restoreFileAttributes(from: source, to: output, manager: manager)
            if cancelled() { throw WorkCancellationError.cancelled }
            try manager.moveItem(at: output, to: destination)
            state.record(destination)
            try manager.removeItem(at: directory)
        } catch {
            if error is WorkCancellationError || error is StageTwoExecutorError || (error as NSError).userInfo["PhotomuriStage"] != nil { throw error }
            throw fileProcessingError(error, source: item.sourceURL)
        }
    }

    /// Copy filesystem metadata only: never COPYFILE_DATA, so edited bytes are
    /// not replaced by original bytes. Includes xattrs/resource fork and ACLs.
    /// Restore birth time explicitly and retain the edited file's mtime, matching
    /// the prior in-place write behavior (which didn't request -P).
    private func restoreFileAttributes(from source: URL, to output: URL, manager: FileManager) throws {
        let sourceAttributes = try manager.attributesOfItem(atPath: source.path)
        let outputAttributes = try manager.attributesOfItem(atPath: output.path)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let target = try FileHandle(forUpdating: output)
        defer { try? target.close() }
        guard Darwin.fcopyfile(input.fileDescriptor, target.fileDescriptor, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var attributes: [FileAttributeKey: Any] = [:]
        if let date = sourceAttributes[.creationDate] { attributes[.creationDate] = date }
        if let date = outputAttributes[.modificationDate] { attributes[.modificationDate] = date }
        try manager.setAttributes(attributes, ofItemAtPath: output.path)
    }

    private func fileProcessingError(_ error: Error, source: URL) -> NSError {
        let original = error as NSError
        return NSError(domain: original.domain, code: original.code, userInfo: [
            NSLocalizedDescriptionKey: "2/3 file processing — \(source.lastPathComponent): \(original.localizedDescription) [\(original.domain) code \(original.code)]",
            NSUnderlyingErrorKey: original, "PhotomuriStage": "2/3 file processing"
        ])
    }

    private func updateMetadata(
        at url: URL,
        item: MediaItem,
        targetTimeZone: CaptureTimeZonePolicy,
        session: ExifToolSession,
        state: WorkState,
        cancelled: () -> Bool
    ) throws {
        let values = metadataValues(
            wallClockDate: item.captureDate,
            captureInstant: item.captureInstant,
            targetTimeZone: targetTimeZone
        )
        var arguments: [String] = []
        let sidecarURL = metadataSidecar(for: url, item: item)
        let temporarySidecar = sidecarURL.map { makeTemporaryURL(beside: $0, fileExtension: "xmp") }
        if let temporarySidecar { state.record(temporarySidecar) }
        let toolTemporary = URL(fileURLWithPath: url.path + "_exiftool_tmp")
        guard !fileManager.fileExists(atPath: toolTemporary.path) else {
            throw StageTwoExecutorError.destinationBecameOccupied(toolTemporary.lastPathComponent)
        }
        state.record(toolTemporary)

        switch item.kind {
        case .jpeg:
            arguments.append("-overwrite_original_in_place")
            arguments += imageMetadataArguments(values)
            arguments.append(url.path)
        case .raw:
            if Self.directlyWritableRAWExtensions.contains(
                item.fileExtension.lowercased()
            ) {
                arguments.append("-overwrite_original_in_place")
                arguments += imageMetadataArguments(values)
                arguments.append(url.path)
            } else {
                let xmpURL = temporarySidecar!
                arguments += [
                    "-o", xmpURL.path,
                    "-XMP-exif:DateTimeOriginal=\(values.isoValue)",
                    "-XMP-xmp:CreateDate=\(values.isoValue)",
                    url.path
                ]
            }
        case .video:
            if Self.directlyWritableVideoExtensions.contains(
                item.fileExtension.lowercased()
            ) {
                arguments.append("-overwrite_original_in_place")
                arguments += videoMetadataArguments(values)
                arguments.append(url.path)
            } else {
                let xmpURL = temporarySidecar!
                arguments += [
                    "-o", xmpURL.path,
                    "-XMP-exif:DateTimeOriginal=\(values.isoValue)",
                    "-XMP-xmp:CreateDate=\(values.isoValue)",
                    "-XMP-xmp:ModifyDate=\(values.isoValue)",
                    url.path
                ]
            }
        }

        let result = try session.run(arguments: arguments, stage: "2/3 metadata update",
                                     filenames: [item.sourceURL.lastPathComponent], cancelled: cancelled)
        guard result.status == 0 else {
            let detail = result.error.isEmpty ? result.output : result.error
            throw StageTwoExecutorError.metadataUpdateFailed(
                "2/3 metadata update — \(item.sourceURL.lastPathComponent) (\(url.lastPathComponent)), ExifTool exit \(result.status): \(detail.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
        if let sidecarURL, let temporarySidecar {
            try FileManager().moveItem(at: temporarySidecar, to: sidecarURL)
            state.record(sidecarURL)
        }
    }

    private func videoMetadataArguments(_ values: MetadataValues) -> [String] {
        ["-api", "QuickTimeUTC=1",
         "-QuickTime:CreateDate=\(values.isoValue)", "-QuickTime:ModifyDate=\(values.isoValue)",
         "-QuickTime:TrackCreateDate=\(values.isoValue)", "-QuickTime:TrackModifyDate=\(values.isoValue)",
         "-QuickTime:MediaCreateDate=\(values.isoValue)", "-QuickTime:MediaModifyDate=\(values.isoValue)",
         "-Keys:CreationDate=\(values.isoValue)"]
    }

    private func imageMetadataArguments(_ values: MetadataValues) -> [String] {
        [
            "-EXIF:DateTimeOriginal=\(values.exifValue)",
            "-EXIF:CreateDate=\(values.exifValue)",
            "-EXIF:OffsetTimeOriginal=\(values.offsetValue)",
            "-EXIF:OffsetTimeDigitized=\(values.offsetValue)",
            "-EXIF:OffsetTime=\(values.offsetValue)",
            "-Nikon:TimeZone=\(values.nikonBaseOffsetValue)",
            "-Nikon:DaylightSavings=\(values.nikonDaylightSavings ? "Yes" : "No")",
            "-XMP-exif:DateTimeOriginal=\(values.isoValue)",
            "-XMP-xmp:CreateDate=\(values.isoValue)"
        ]
    }

    private func metadataValues(
        wallClockDate: Date,
        captureInstant: Date?,
        targetTimeZone: CaptureTimeZonePolicy
    ) -> MetadataValues {
        var localCalendar = Calendar(identifier: .gregorian)
        localCalendar.locale = Locale(identifier: "en_US_POSIX")
        localCalendar.timeZone = .current
        let components = localCalendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: wallClockDate
        )

        let absoluteDate = captureInstant ?? targetTimeZone.absoluteDate(from: components) ?? wallClockDate
        let effectiveOffset = targetTimeZone.offsetSeconds(on: absoluteDate)
        let offset = Self.offsetString(effectiveOffset)
        // Nikon WorldTime's boolean DST flag represents exactly one hour.
        // For a 30-minute (or other) shift, store the effective offset with
        // DST off rather than encoding a base + flag that cannot represent it.
        let daylightShift = targetTimeZone.applyDaylightSavingTime
            ? Int(targetTimeZone.timeZone.daylightSavingTimeOffset(for: absoluteDate)) : 0
        let nikonDST = daylightShift == 3600
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let day = components.day ?? 1
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        let second = components.second ?? 0

        return MetadataValues(
            exifValue: String(
                format: "%04d:%02d:%02d %02d:%02d:%02d",
                year, month, day, hour, minute, second
            ),
            isoValue: String(
                format: "%04d:%02d:%02d %02d:%02d:%02d%@",
                year, month, day, hour, minute, second, offset
            ),
            offsetValue: offset,
            nikonBaseOffsetValue: Self.offsetString(effectiveOffset - (nikonDST ? 3600 : 0)),
            nikonDaylightSavings: nikonDST
        )
    }

    /// All claims, artifacts, errors and progress are serialized. The callback
    /// is delivered in completion-count order, never in original file order.
    private final class WorkState: @unchecked Sendable {
        private let lock = NSRecursiveLock()
        private let total: Int
        private let progress: ProgressHandler?
        private var next = 0
        private var urls: [URL] = []
        private var count = 0
        private var updated = 0
        private var failure: Error?
        let stop = WorkCancellationToken()
        init(total: Int, progress: ProgressHandler?) { self.total = total; self.progress = progress }
        func claim(cancelled: Bool) -> Int? {
            lock.lock(); defer { lock.unlock() }
            if cancelled && failure == nil { failure = WorkCancellationError.cancelled; stop.cancel() }
            guard failure == nil, next < total else { return nil }
            defer { next += 1 }
            return next
        }
        func record(_ url: URL) { lock.lock(); defer { lock.unlock() }; urls.append(url) }
        func fail(_ error: Error) {
            lock.lock(); defer { lock.unlock() }
            if failure == nil { failure = error }
            stop.cancel()
        }
        func finish(metadata: Bool) {
            lock.lock(); defer { lock.unlock() }
            count += 1
            if metadata { updated += 1 }
            progress?(count, total)
        }
        var artifacts: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
        var completed: Int { lock.lock(); defer { lock.unlock() }; return count }
        var metadataCount: Int { lock.lock(); defer { lock.unlock() }; return updated }
        var error: Error? { lock.lock(); defer { lock.unlock() }; return failure }
    }

    private func runWorkers(
        state: WorkState, metadata: Bool, cancellationToken: WorkCancellationToken?,
        body: @escaping (Int, ExifToolSession?, FileManager, () -> Bool) throws -> Void
    ) throws {
        let toolURL = bundle.url(forResource: "exiftool", withExtension: nil, subdirectory: "ExifTool")
        if metadata && toolURL == nil { throw StageTwoExecutorError.exifToolUnavailable }
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "com.byastra.photomuri.file-workers", qos: .userInitiated, attributes: .concurrent)
        for _ in 0..<workerCount {
            group.enter()
            queue.async {
                defer { group.leave() }
                let manager = FileManager()
                let session = metadata ? ExifToolSession(toolURL: toolURL!) : nil
                defer { session?.close() }
                let cancelled = { state.stop.isCancelled || cancellationToken?.isCancelled == true }
                while let index = state.claim(cancelled: cancelled()) {
                    do {
                        try autoreleasepool {
                            if cancelled() { throw WorkCancellationError.cancelled }
                            try body(index, session, manager, cancelled)
                        }
                    } catch { state.fail(error) }
                }
            }
        }
        // Includes session shutdown: rollback must never race a child writer.
        group.wait()
        if let error = state.error { throw error }
        try cancellationToken?.check()
    }

    private func copyForProcessing(from source: URL, to destination: URL,
                                   manager: FileManager, state: WorkState) throws {
        // Copy to an owned unique path first. A partial copy can be removed
        // without mistaking a concurrently-created destination for our output.
        let temporary = makeTemporaryURL(beside: destination, fileExtension: destination.pathExtension)
        state.record(temporary)
        do {
            try manager.copyItem(at: source, to: temporary)
            try manager.moveItem(at: temporary, to: destination)
            state.record(destination)
        } catch {
            let original = error as NSError
            throw NSError(domain: original.domain, code: original.code, userInfo: [
                NSLocalizedDescriptionKey: "2/3 file processing — \(source.lastPathComponent): \(original.localizedDescription) [\(original.domain) code \(original.code)]",
                NSUnderlyingErrorKey: original, "PhotomuriStage": "2/3 file processing"
            ])
        }
    }

    private func metadataSidecar(for url: URL, item: MediaItem) -> URL? {
        switch item.kind {
        case .jpeg: return nil
        case .raw:
            return Self.directlyWritableRAWExtensions.contains(item.fileExtension.lowercased())
                ? nil : url.deletingPathExtension().appendingPathExtension("xmp")
        case .video:
            return Self.directlyWritableVideoExtensions.contains(item.fileExtension.lowercased())
                ? nil : url.appendingPathExtension("xmp")
        }
    }

    private func preflightMetadataArtifacts(_ items: [RenamePlanItem]) throws {
        var destinations = Set(items.map { pathKey($0.destinationURL) })
        for item in items {
            let url = item.destinationURL
            let temporary = URL(fileURLWithPath: url.path + "_exiftool_tmp")
            let artifacts = [temporary] + (metadataSidecar(for: url, item: item.mediaItem).map { [$0] } ?? [])
            for artifact in artifacts {
                guard destinations.insert(pathKey(artifact)).inserted,
                      !fileManager.fileExists(atPath: artifact.path) else {
                    throw StageTwoExecutorError.destinationBecameOccupied(artifact.lastPathComponent)
                }
            }
        }
    }

    private func preflight(
        _ items: [RenamePlanItem],
        preserveOriginals: Bool
    ) throws {
        let sourceKeys = preserveOriginals
        ? Set<String>()
        : Set(items.map { pathKey($0.mediaItem.sourceURL) })
        for item in items {
            guard fileManager.fileExists(atPath: item.mediaItem.sourceURL.path) else {
                throw StageTwoExecutorError.sourceFileMissing(
                    item.mediaItem.sourceURL.lastPathComponent
                )
            }
            if fileManager.fileExists(atPath: item.destinationURL.path),
               !sourceKeys.contains(pathKey(item.destinationURL)) {
                throw StageTwoExecutorError.destinationBecameOccupied(
                    item.destinationURL.lastPathComponent
                )
            }
        }
    }

    private func createDestinationDirectories(
        for items: [RenamePlanItem]
    ) throws {
        let directories = Set(items.map {
            $0.destinationURL.deletingLastPathComponent()
        })
        for directory in directories {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
    }

    private func rollback(
        staged: [StagedItem],
        createdURLs: [URL],
        sidecarURLs: [URL],
        metadataWasUpdated: Bool
    ) -> [String] {
        var errors: [String] = []
        if metadataWasUpdated {
            errors.append(contentsOf: removeCreatedFiles(createdURLs + sidecarURLs))
        } else {
            // Vacate every completed destination before restoring any original
            // name. This also makes cyclic/swap rename plans safe to roll back.
            let owned = Set(createdURLs.map(pathKey))
            for item in staged where !fileManager.fileExists(atPath: item.temporaryURL.path)
                && owned.contains(pathKey(item.planItem.destinationURL)) {
                do {
                    try fileManager.moveItem(at: item.planItem.destinationURL, to: item.temporaryURL)
                } catch { errors.append(error.localizedDescription) }
            }
        }
        for item in staged.reversed() {
            guard fileManager.fileExists(atPath: item.temporaryURL.path) else {
                continue
            }
            do {
                try fileManager.moveItem(
                    at: item.temporaryURL,
                    to: item.planItem.mediaItem.sourceURL
                )
            } catch { errors.append(error.localizedDescription) }
        }
        return errors
    }

    private func removeCreatedFiles(_ urls: [URL]) -> [String] {
        var errors: [String] = []
        for url in urls.reversed() where fileManager.fileExists(atPath: url.path) {
            do { try fileManager.removeItem(at: url) }
            catch { errors.append(error.localizedDescription) }
        }
        return errors
    }

    private func makeTemporaryURL(
        beside sourceURL: URL,
        fileExtension: String
    ) -> URL {
        let folder = sourceURL.deletingLastPathComponent()
        while true {
            let candidate = folder.appendingPathComponent(
                ".media-organizer-\(UUID().uuidString).\(fileExtension)"
            )
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
    }

    private func normalized(_ error: Error) -> Error {
        if error is StageTwoExecutorError { return error }
        if (error as NSError).userInfo["PhotomuriStage"] != nil { return error }
        return StageTwoExecutorError.fileOperationFailed(error.localizedDescription)
    }

    private func pathKey(_ url: URL) -> String {
        url.standardizedFileURL.path.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
    }

    private struct MetadataValues {
        let exifValue: String
        let isoValue: String
        let offsetValue: String
        let nikonBaseOffsetValue: String
        let nikonDaylightSavings: Bool
    }

    private static func offsetString(_ seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : "+"
        let absolute = abs(seconds)
        return String(
            format: "%@%02d:%02d",
            sign, absolute / 3600, (absolute % 3600) / 60
        )
    }

    private static let directlyWritableRAWExtensions: Set<String> = [
        "arw", "cr2", "cr3", "dng", "erf", "fff", "iiq", "mef",
        "mos", "mrw", "nef", "nrw", "orf", "pef", "raf", "raw",
        "rw2", "rwl", "sr2", "srw", "x3f"
    ]

    /// ExifTool can write QuickTime container dates directly for these types.
    /// Other recognized video formats receive a sibling `<filename>.xmp` file.
    private static let directlyWritableVideoExtensions: Set<String> = [
        "m4v", "mov", "mp4"
    ]
}

/// One session is exclusively owned by one worker. Do not share it between
/// concurrent callers. Poll/drain both pipes during writes, with bounded waits
/// for cancellation and timeouts; no extra reader thread or leaked descriptors.
final class ExifToolSession {
    private let toolURL: URL
    private let executableURL: URL
    private let timeout: TimeInterval
    private var process: Process?
    private var handles: [FileHandle] = []
    private var input: FileHandle?
    private var output: FileHandle?
    private var errors: FileHandle?
    private var serial = 0
    private let identity = UUID().uuidString

    init(toolURL: URL, timeout: TimeInterval = 600,
         executableURL: URL = URL(fileURLWithPath: "/usr/bin/perl")) {
        self.toolURL = toolURL
        self.timeout = timeout
        self.executableURL = executableURL
    }
    deinit { close() }

    private func start() throws {
        guard process == nil else { return }
        let child = Process(), stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        handles = [stdinPipe.fileHandleForReading, stdinPipe.fileHandleForWriting,
                   stdoutPipe.fileHandleForReading, stdoutPipe.fileHandleForWriting,
                   stderrPipe.fileHandleForReading, stderrPipe.fileHandleForWriting]
        input = stdinPipe.fileHandleForWriting
        output = stdoutPipe.fileHandleForReading
        errors = stderrPipe.fileHandleForReading
        child.executableURL = executableURL
        child.arguments = [toolURL.path, "-stay_open", "True", "-@", "-"]
        child.environment = ProcessInfo.processInfo.environment.merging(
            ["PERL5LIB": toolURL.deletingLastPathComponent().appendingPathComponent("lib").path]) { _, bundled in bundled }
        child.standardInput = stdinPipe
        child.standardOutput = stdoutPipe
        child.standardError = stderrPipe
        process = child
        try child.run()
        try stdinPipe.fileHandleForReading.close()
        try stdoutPipe.fileHandleForWriting.close()
        try stderrPipe.fileHandleForWriting.close()
        for handle in [input!, output!, errors!] {
            let descriptor = handle.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
        guard fcntl(input!.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    func run(arguments: [String], stage: String, filenames: [String],
             cancelled: () -> Bool = { false }) throws -> (status: Int32, output: String, error: String) {
        try autoreleasepool {
            do {
                if cancelled() { throw WorkCancellationError.cancelled }
                // -@ is line-oriented. Rare newline filenames must use ordinary
                // argv rather than becoming additional ExifTool commands.
                if arguments.contains(where: { $0.isEmpty || $0.hasPrefix("#") || $0.contains("\n") || $0.contains("\r") }) {
                    let result = try withoutActuallyEscaping(cancelled) { cancellation in try ExifToolProcessRunner.run(
                        arguments: [toolURL.path] + arguments,
                        libraryURL: toolURL.deletingLastPathComponent().appendingPathComponent("lib"),
                        stage: stage, filenames: filenames, executableURL: executableURL,
                        cancelled: cancellation, timeout: timeout) }
                    if cancelled() { throw WorkCancellationError.cancelled }
                    return result
                }
                try start()
                serial += 1
                let marker = "__PHOTOMURI_\(identity)_\(serial)__"
                let ready = "{ready\(serial)}"
                let command = (["-charset", "filename=UTF8"] + arguments + [
                    "-echo3", marker + "${status}", "-echo4", marker + "${status}", "-execute\(serial)"
                ]).joined(separator: "\n") + "\n"
                let payload = Data(command.utf8)
                var sent = 0, pendingOut = Data(), pendingError = Data(), stdout = Data(), stderr = Data()
                var stdoutStatus: Int32?, stderrStatus: Int32?
                var receivedReady = false
                let deadline = ProcessInfo.processInfo.systemUptime + timeout

                func parse(_ pending: inout Data, collected: inout Data, status: inout Int32?, isOutput: Bool) throws {
                    while let newline = pending.firstIndex(of: 10) {
                        let bytes = pending[..<newline]
                        let line = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .newlines)
                        if line.hasPrefix(marker) {
                            guard let value = Int32(line.dropFirst(marker.count)) else {
                                throw NSError(domain: "Photomuri.ExifToolSession", code: 2,
                                              userInfo: [NSLocalizedDescriptionKey: "Invalid ExifTool command status."])
                            }
                            status = value
                        } else if isOutput && line == ready {
                            receivedReady = true
                        } else {
                            collected.append(bytes); collected.append(10)
                        }
                        pending.removeSubrange(...newline)
                    }
                    guard pending.count + collected.count <= 16 * 1024 * 1024 else {
                        throw NSError(domain: "Photomuri.ExifToolSession", code: 3,
                                      userInfo: [NSLocalizedDescriptionKey: "ExifTool output exceeded the safety limit."])
                    }
                }

                while !(receivedReady && stdoutStatus != nil && stderrStatus != nil) {
                    if cancelled() { throw WorkCancellationError.cancelled }
                    if ProcessInfo.processInfo.systemUptime >= deadline {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT),
                                      userInfo: [NSLocalizedDescriptionKey: "ExifTool metadata write timed out."])
                    }
                    var descriptors = [
                        pollfd(fd: output!.fileDescriptor, events: Int16(POLLIN), revents: 0),
                        pollfd(fd: errors!.fileDescriptor, events: Int16(POLLIN), revents: 0),
                        pollfd(fd: sent < payload.count ? input!.fileDescriptor : -1, events: Int16(POLLOUT), revents: 0)
                    ]
                    let polled = descriptors.withUnsafeMutableBufferPointer { Darwin.poll($0.baseAddress, 3, 100) }
                    if polled < 0 {
                        if errno == EINTR { continue }
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                    }
                    if descriptors[2].revents & Int16(POLLOUT) != 0 {
                        let written = payload.withUnsafeBytes {
                            Darwin.write(input!.fileDescriptor, $0.baseAddress!.advanced(by: sent), payload.count - sent)
                        }
                        if written > 0 { sent += written }
                        else if written < 0 && errno != EAGAIN && errno != EINTR {
                            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                        }
                    }
                    for index in 0...1 where descriptors[index].revents != 0 {
                        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                        let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptors[index].fd, $0.baseAddress, $0.count) }
                        if count > 0 {
                            if index == 0 {
                                pendingOut.append(contentsOf: buffer.prefix(count))
                                try parse(&pendingOut, collected: &stdout, status: &stdoutStatus, isOutput: true)
                            } else {
                                pendingError.append(contentsOf: buffer.prefix(count))
                                try parse(&pendingError, collected: &stderr, status: &stderrStatus, isOutput: false)
                            }
                        } else if count == 0 {
                            throw NSError(domain: "Photomuri.ExifToolSession", code: 4,
                                userInfo: [NSLocalizedDescriptionKey: "ExifTool exited before completing the file. " + String(decoding: stderr + pendingError, as: UTF8.self)])
                        } else if errno != EAGAIN && errno != EINTR {
                            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                        }
                    }
                }
                guard stdoutStatus == stderrStatus else {
                    throw NSError(domain: "Photomuri.ExifToolSession", code: 5,
                                  userInfo: [NSLocalizedDescriptionKey: "ExifTool command framing was inconsistent."])
                }
                return (stdoutStatus!, String(decoding: stdout, as: UTF8.self), String(decoding: stderr, as: UTF8.self))
            } catch {
                // Never replay a failed write: it may have partially succeeded.
                // Reap this child before returning so rollback can safely begin.
                close(abort: true)
                if error is WorkCancellationError { throw error }
                let original = error as NSError
                throw NSError(domain: original.domain, code: original.code, userInfo: [
                    NSLocalizedDescriptionKey: "\(stage) — \(filenames.joined(separator: ", ")): \(original.localizedDescription) [\(original.domain) code \(original.code)]",
                    NSUnderlyingErrorKey: original, "PhotomuriStage": stage
                ])
            }
        }
    }

    func close(abort: Bool = false) {
        guard let child = process else { return }
        if child.isRunning {
            if abort { child.terminate() }
            else if let input {
                let shutdown = Data("-stay_open\nFalse\n".utf8)
                _ = shutdown.withUnsafeBytes { Darwin.write(input.fileDescriptor, $0.baseAddress, $0.count) }
            }
            try? input?.close()
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while child.isRunning && ProcessInfo.processInfo.systemUptime < deadline { _ = Darwin.poll(nil, 0, 20) }
            if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
            child.waitUntilExit()
        }
        for handle in handles { try? handle.close() }
        handles.removeAll(); input = nil; output = nil; errors = nil; process = nil
    }
}

/// Shared by analysis and the rare argv-only metadata-write fallback. Drain both streams
/// concurrently: reading stdout to EOF before stderr can deadlock on a full
/// stderr pipe. Explicit closure and the pool bound descriptors per invocation.
enum ExifToolProcessRunner {
    private final class ReadResult: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<Data, Error>?
        func store(_ result: Result<Data, Error>) { lock.lock(); defer { lock.unlock() }; value = result }
        func get() throws -> Data { lock.lock(); defer { lock.unlock() }; return try value!.get() }
    }

    static func run(arguments: [String], libraryURL: URL, stage: String,
                    filenames: [String], executableURL: URL = URL(fileURLWithPath: "/usr/bin/perl"),
                    stderrLineHandler: ((String) -> Void)? = nil,
                    cancelled: (() -> Bool)? = nil, timeout: TimeInterval? = nil) throws
    -> (status: Int32, output: String, error: String) {
        try autoreleasepool {
            let process = Process()
            let outputPipe = Pipe(), errorPipe = Pipe()
            let handles = [outputPipe.fileHandleForReading, outputPipe.fileHandleForWriting,
                           errorPipe.fileHandleForReading, errorPipe.fileHandleForWriting]
            defer { for handle in handles { try? handle.close() } }
            process.executableURL = executableURL
            process.arguments = arguments
            process.environment = ProcessInfo.processInfo.environment.merging(
                ["PERL5LIB": libraryURL.path]) { _, bundled in bundled }
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            do {
                try process.run()
                try? outputPipe.fileHandleForWriting.close()
                try? errorPipe.fileHandleForWriting.close()
                let group = DispatchGroup()
                let output = ReadResult(), errors = ReadResult()
                for (handle, result) in [(outputPipe.fileHandleForReading, output),
                                         (errorPipe.fileHandleForReading, errors)] {
                    let receiveLine = handle === errorPipe.fileHandleForReading ? stderrLineHandler : nil
                    group.enter()
                    DispatchQueue.global(qos: .utility).async {
                        defer { group.leave() }
                        autoreleasepool {
                            let read = Result {
                                if let receiveLine {
                                    return try readLines(from: handle, receive: receiveLine)
                                }
                                return try handle.readToEnd() ?? Data()
                            }
                            result.store(read)
                            if case .failure = read {
                                try? handle.close()
                                if process.isRunning { process.terminate() }
                            }
                        }
                    }
                }
                var interrupted: Error?
                if cancelled != nil || timeout != nil {
                    let deadline = ProcessInfo.processInfo.systemUptime + (timeout ?? .infinity)
                    while process.isRunning {
                        if cancelled?() == true { interrupted = WorkCancellationError.cancelled }
                        else if ProcessInfo.processInfo.systemUptime >= deadline {
                            interrupted = NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT))
                        }
                        if interrupted != nil {
                            process.terminate()
                            let stopDeadline = ProcessInfo.processInfo.systemUptime + 2
                            while process.isRunning && ProcessInfo.processInfo.systemUptime < stopDeadline {
                                _ = Darwin.poll(nil, 0, 20)
                            }
                            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                            break
                        }
                        _ = Darwin.poll(nil, 0, 50)
                    }
                }
                process.waitUntilExit()
                group.wait()
                if let interrupted { throw interrupted }
                return (process.terminationStatus,
                        String(decoding: try output.get(), as: UTF8.self),
                        String(decoding: try errors.get(), as: UTF8.self))
            } catch {
                if error is WorkCancellationError { throw error }
                let original = error as NSError
                throw NSError(domain: original.domain, code: original.code, userInfo: [
                    NSLocalizedDescriptionKey: "\(stage) — \(filenames.joined(separator: ", ")): \(original.localizedDescription) [\(original.domain) code \(original.code)]",
                    NSUnderlyingErrorKey: original, "PhotomuriStage": stage
                ])
            }
        }
    }

    /// Read without waiting for EOF so ExifTool progress reaches the UI while
    /// the child is still working. Buffer bytes until newline to preserve UTF-8
    /// filenames across pipe chunks; retain stderr for normal error reporting.
    private static func readLines(from handle: FileHandle, receive: (String) -> Void) throws -> Data {
        var output = Data(), pending = Data()
        let capacity = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: capacity)
        while true {
            // FileHandle.read(upToCount:) can wait to fill its requested buffer.
            // POSIX read returns the bytes currently available on a pipe, so a
            // short progress line is delivered before the child finishes.
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(handle.fileDescriptor, $0.baseAddress, capacity)
            }
            if count == 0 { break }
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            let chunk = Data(buffer.prefix(count))
            output.append(chunk)
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 10) {
                receive(String(decoding: pending[..<newline], as: UTF8.self))
                pending.removeSubrange(...newline)
            }
        }
        if !pending.isEmpty { receive(String(decoding: pending, as: UTF8.self)) }
        return output
    }
}

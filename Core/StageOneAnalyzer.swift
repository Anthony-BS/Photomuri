import Foundation
import ImageIO
import Darwin

struct StageOneAnalyzer {
    typealias ProgressHandler = (_ completed: Int, _ total: Int) -> Void
    
    private let fileManager: FileManager
    private let calendar: Calendar
    private let bundle: Bundle
    private let applyDaylightSavingTime: Bool
    private var dateParsingCache: DateParsingCache?
    
    init(
        fileManager: FileManager = .default,
        calendar: Calendar = .current,
        bundle: Bundle = .main,
        applyDaylightSavingTime: Bool = true
    ) {
        self.fileManager = fileManager
        self.calendar = calendar
        self.bundle = bundle
        self.applyDaylightSavingTime = applyDaylightSavingTime
    }
    
    /// Stage 1은 파일을 읽고 rename 계획만 계산합니다.
    /// 이 함수는 파일명 변경, 이동, 삭제를 전혀 수행하지 않습니다.
    func analyze(
        folderURL: URL,
        renameTemplate: String,
        timeZoneOverride: TimeZone? = nil,
        renameEnabled: Bool = true,
        preserveOriginals: Bool = false,
        metadataSnapshot: StageOneMetadataSnapshot? = nil,
        cancellationToken: WorkCancellationToken? = nil,
        observer: StageOneAnalysisObserver? = nil,
        progress: ProgressHandler? = nil
    ) throws -> StageOneResult {
        // A separate parser cache for each invocation: safe even when callers
        // invoke the same analyzer value concurrently. No global mutable cache.
        var analyzer = self
        analyzer.dateParsingCache = DateParsingCache()
        return try analyzer.analyzePrepared(folderURL: folderURL, renameTemplate: renameTemplate,
            timeZoneOverride: timeZoneOverride, renameEnabled: renameEnabled, preserveOriginals: preserveOriginals,
            metadataSnapshot: metadataSnapshot, cancellationToken: cancellationToken, observer: observer, progress: progress)
    }

    private func analyzePrepared(
        folderURL: URL, renameTemplate: String, timeZoneOverride: TimeZone?, renameEnabled: Bool,
        preserveOriginals: Bool, metadataSnapshot: StageOneMetadataSnapshot?,
        cancellationToken: WorkCancellationToken?, observer: StageOneAnalysisObserver?, progress: ProgressHandler?
    ) throws -> StageOneResult {
        try cancellationToken?.check()
        observer?.phaseChanged(.checkingFiles)
        let fileURLs = try mediaFileURLs(in: folderURL)
        let before = try fileFingerprints(fileURLs, cancellationToken: cancellationToken)
        let reusable = metadataSnapshot.flatMap { snapshot -> StageOneMetadataSnapshot? in
            guard let before,
                  snapshot.folderPath == folderURL.standardizedFileURL.path,
                  snapshot.bundlePath == bundle.bundleURL.standardizedFileURL.path,
                  snapshot.calendar == calendar,
                  snapshot.filePaths == fileURLs.map(\.path),
                  snapshot.fingerprints == before else { return nil }
            return snapshot
        }
        let total = fileURLs.count
        let progressState = AnalysisProgressReporter(total: total, handler: progress)
        progressState.report(0)
        let raw: RawExifToolMetadata
        if let reusable {
            dateParsingCache?.dates = reusable.parsedDates
            dateParsingCache?.invalid = reusable.unparseableDates
            raw = RawExifToolMetadata(records: reusable.records, warnings: reusable.readWarnings,
                                      version: reusable.exifToolVersion)
        } else {
            observer?.phaseChanged(.readingMetadata)
            raw = try readExifToolMetadata(for: fileURLs, cancellationToken: cancellationToken) { completed in
                progressState.report(min(completed, max(total - 1, 0)))
            }
        }
        observer?.phaseChanged(.planning)
        let metadata = try resolveExifToolMetadata(raw, for: fileURLs, timeZoneOverride: timeZoneOverride,
            cancellationToken: cancellationToken) { completed in
                progressState.report(min(completed, max(total - 1, 0)))
            }
        
        var mediaItems: [MediaItem] = []
        mediaItems.reserveCapacity(fileURLs.count)
        
        for (index, fileURL) in fileURLs.enumerated() {
            try cancellationToken?.check()
            if let item = makeMediaItem(
                from: fileURL,
                exifDate: metadata.captureDates[pathKey(fileURL)],
                captureInstant: metadata.captureInstants[pathKey(fileURL)],
                metadataDetails: metadata.detailsByPath[pathKey(fileURL)] ?? "",
                cachedFallback: reusable?.fallbackItems[fileURL.path]
            ) {
                mediaItems.append(item)
            }
            progressState.report(min(index + 1, max(total - 1, 0)))
        }
        
        try cancellationToken?.check()
        
        let shots = makeShots(from: mediaItems)
        let plan = makeRenamePlan(
            shots: shots,
            folderURL: folderURL,
            renameTemplate: renameTemplate,
            renameEnabled: renameEnabled
        )
        let collisions = findCollisions(
            in: plan,
            preserveOriginals: preserveOriginals
        )
        try cancellationToken?.check()
        let finalFiles = try mediaFileURLs(in: folderURL)
        let listUnchanged = fileURLs.map(\.path) == finalFiles.map(\.path)
        let after = try fileFingerprints(finalFiles, cancellationToken: cancellationToken)
        if reusable != nil && (!listUnchanged || before != after) {
            // A file changed while recalculating. Never publish a cached plan
            // for it; do a fresh read. This path cannot recurse on cache reuse.
            return try analyze(folderURL: folderURL, renameTemplate: renameTemplate,
                timeZoneOverride: timeZoneOverride, renameEnabled: renameEnabled,
                preserveOriginals: preserveOriginals, cancellationToken: cancellationToken,
                observer: observer, progress: progress)
        }
        let snapshot: StageOneMetadataSnapshot?
        if let before, let after, listUnchanged, before == after, raw.cacheable {
            snapshot = reusable ?? StageOneMetadataSnapshot(
                folderPath: folderURL.standardizedFileURL.path,
                bundlePath: bundle.bundleURL.standardizedFileURL.path, calendar: calendar,
                filePaths: fileURLs.map(\.path), fingerprints: after, records: raw.records,
                readWarnings: raw.warnings, exifToolVersion: raw.version,
                fallbackItems: Dictionary(uniqueKeysWithValues: mediaItems.filter {
                    metadata.captureDates[pathKey($0.sourceURL)] == nil
                }.map { ($0.sourceURL.path, $0) }),
                parsedDates: dateParsingCache?.dates ?? [:], unparseableDates: dateParsingCache?.invalid ?? [])
        } else {
            snapshot = nil
        }
        progressState.report(total)
        
        return StageOneResult(
            mediaItems: mediaItems,
            shots: shots,
            renamePlan: plan,
            collisions: collisions,
            timeZoneSummaries: metadata.timeZoneSummaries,
            metadataWarnings: metadata.warnings,
            exifToolVersion: metadata.exifToolVersion,
            timeZoneOverrideIdentifier: timeZoneOverride?.identifier,
            applyDaylightSavingTime: applyDaylightSavingTime,
            metadataSnapshot: snapshot,
            reusedMetadata: reusable != nil
        )
    }
    
    // MARK: - File scan

    /// Fresh stat calls bypass URLResourceValues' cached timestamps. Include
    /// inode/device, size, mtime, ctime, birth time and mode, at nanosecond
    /// resolution. ctime catches a same-size edit with restored mtime.
    /// nil means validation is unavailable: always fall back to a fresh read.
    private func fileFingerprints(_ urls: [URL], cancellationToken: WorkCancellationToken?) throws -> [String: [Int64]]? {
        var stamps: [String: [Int64]] = [:]
        for url in urls {
            try cancellationToken?.check()
            var info = stat()
            guard url.withUnsafeFileSystemRepresentation({ path in
                path.map { Darwin.fstatat(AT_FDCWD, $0, &info, 0) } ?? -1
            }) == 0 else { return nil }
            stamps[url.path] = [Int64(info.st_dev), Int64(bitPattern: info.st_ino), info.st_size,
                Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec),
                Int64(info.st_ctimespec.tv_sec), Int64(info.st_ctimespec.tv_nsec),
                Int64(info.st_birthtimespec.tv_sec), Int64(info.st_birthtimespec.tv_nsec), Int64(info.st_mode)]
        }
        return stamps
    }
    
    private func mediaFileURLs(in folderURL: URL) throws -> [URL] {
        var isDirectory: ObjCBool = false
        
        guard fileManager.fileExists(
            atPath: folderURL.path,
            isDirectory: &isDirectory
        ) else {
            throw StageOneAnalyzerError.folderDoesNotExist
        }
        
        guard isDirectory.boolValue else {
            throw StageOneAnalyzerError.selectedURLIsNotFolder
        }
        
        do {
            let keys: Set<URLResourceKey> = [
                .isRegularFileKey,
                .isHiddenKey,
                .creationDateKey,
                .contentModificationDateKey
            ]
            
            return try fileManager.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
            .filter { url in
                guard let values = try? url.resourceValues(forKeys: keys) else {
                    return false
                }
                
                return values.isRegularFile == true
                && values.isHidden != true
                && mediaKind(for: url.pathExtension) != nil
            }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare(
                    $1.lastPathComponent
                ) == .orderedAscending
            }
        } catch {
            throw StageOneAnalyzerError.cannotReadFolder(
                error.localizedDescription
            )
        }
    }
    
    private func makeMediaItem(
        from url: URL,
        exifDate: Date?,
        captureInstant: Date?,
        metadataDetails: String,
        cachedFallback: MediaItem? = nil
    ) -> MediaItem? {
        guard let kind = mediaKind(for: url.pathExtension) else {
            return nil
        }
        if exifDate == nil, let cachedFallback { return cachedFallback }
        
        let values = try? url.resourceValues(forKeys: [
            .creationDateKey,
            .contentModificationDateKey
        ])
        
        // ExifTool covers photos, RAW files and videos. ImageIO and file dates
        // remain safe fallbacks when metadata is missing or ExifTool cannot run.
        let imageDate = exifDate == nil ? imageCaptureDate(from: url, kind: kind) : nil
        let date = exifDate
        ?? imageDate
        ?? values?.creationDate
        ?? values?.contentModificationDate
        ?? Date(timeIntervalSince1970: 0)
        
        return MediaItem(
            sourceURL: url,
            originalStem: url.deletingPathExtension().lastPathComponent,
            fileExtension: url.pathExtension,
            kind: kind,
            captureDate: date,
            captureDateDetails: "Capture time source: " + (exifDate != nil ? "ExifTool" : imageDate != nil ? "ImageIO" : values?.creationDate != nil ? "File creation date" : values?.contentModificationDate != nil ? "File modification date" : "No date available (1970 fallback)") + "\n" + metadataDetails,
            captureInstant: captureInstant
        )
    }

    // MARK: - ExifTool metadata

    private func readExifToolMetadata(
        for fileURLs: [URL],
        cancellationToken: WorkCancellationToken?,
        progress: @escaping (Int) -> Void
    ) throws -> RawExifToolMetadata {
        guard !fileURLs.isEmpty,
              let executableURL = bundle.url(
                forResource: "exiftool",
                withExtension: nil,
                subdirectory: "ExifTool"
              ) else {
            return RawExifToolMetadata(
                records: [],
                warnings: exifToolUnavailableWarnings(for: fileURLs),
                version: nil, available: false, cacheable: false
            )
        }

        let libraryURL = executableURL
            .deletingLastPathComponent()
            .appendingPathComponent("lib", isDirectory: true)

        guard fileManager.fileExists(atPath: libraryURL.path) else {
            return RawExifToolMetadata(
                records: [],
                warnings: exifToolUnavailableWarnings(for: fileURLs),
                version: nil, available: false, cacheable: false
            )
        }

        var metadataRecords: [[String: Any]] = []
        var warnings: [MetadataReadWarning] = []
        var version: String?
        var cacheable = true
        do { version = try exifToolVersion(executableURL: executableURL, libraryURL: libraryURL) }
        catch {
            cacheable = false
            warnings.append(contentsOf: fileURLs.map {
                MetadataReadWarning(sourceURL: $0, message: error.localizedDescription)
            })
        }

        // Keep each Process invocation comfortably below the command-line
        // argument limit even when a folder contains many files.
        var completedInEarlierBatches = 0
        for batch in fileURLs.chunked(into: 200) {
            try cancellationToken?.check()
            let batchBase = completedInEarlierBatches
            defer {
                completedInEarlierBatches += batch.count
                progress(completedInEarlierBatches)
            }
            let arguments = [
                executableURL.path,
                "-json",
                "-progress",
                "-a", "-G1:4:5",
                "-charset", "filename=UTF8",
                // Keep native date text. ExifTool's %z invents the Mac's
                // system offset for zone-less camera dates; that is not a
                // recorded camera offset and must not override WorldTime.
                "-Error",
                "-Warning",
                "-Make",
                "-Model",
                "-FileType",
                "-SubSecDateTimeOriginal",
                "-DateTimeOriginal",
                "-OffsetTimeOriginal",
                "-TimeZone",
                "-DaylightSavings",
                "-CreationDate",
                // Avoid Nikon's maker-note CreateDate shadowing the raw
                // QuickTime timestamp in native camera videos.
                "-EXIF:CreateDate",
                "-QuickTime:CreateDate",
                "-MediaCreateDate",
                "-TrackCreateDate"
            ] + batch.map(\.path)
            do {
                let result = try ExifToolProcessRunner.run(arguments: arguments, libraryURL: libraryURL,
                    stage: "1/3 metadata analysis", filenames: batch.map(\.lastPathComponent),
                    stderrLineHandler: { line in
                        guard let started = Self.exifToolProgressIndex(in: line, batchTotal: batch.count) else { return }
                        // ExifTool reports just before opening the next file.
                        // Its predecessor is complete; do not count the current
                        // file until the next marker or batch exit arrives.
                        progress(batchBase + started - 1)
                    })
                guard result.status == 0 else {
                    cacheable = false
                    warnings.append(contentsOf: batch.map {
                        MetadataReadWarning(
                            sourceURL: $0,
                            message: "1/3 metadata analysis — \($0.lastPathComponent): ExifTool exit \(result.status). \(result.error) Using the file date instead."
                        )
                    })
                    continue
                }

                guard let records = try JSONSerialization.jsonObject(
                        with: Data(result.output.utf8)
                      ) as? [[String: Any]] else {
                    cacheable = false
                    warnings.append(contentsOf: batch.map {
                        MetadataReadWarning(
                            sourceURL: $0,
                            message: "1/3 metadata analysis — \($0.lastPathComponent): Cannot parse the ExifTool analysis results. Using the file date instead."
                        )
                    })
                    continue
                }

                metadataRecords.append(contentsOf: records.map(normalizedMetadataRecord))
            } catch {
                cacheable = false
                if cancellationToken?.isCancelled == true {
                    throw WorkCancellationError.cancelled
                }
                // Analysis still continues through ImageIO and file dates.
                let original = error as NSError
                warnings.append(contentsOf: batch.map {
                    MetadataReadWarning(
                        sourceURL: $0,
                        message: "1/3 metadata analysis — \($0.lastPathComponent): \(error.localizedDescription) [\(original.domain) code \(original.code)] Using the file date instead."
                    )
                })
                continue
            }
        }

        try cancellationToken?.check()

        return RawExifToolMetadata(records: metadataRecords, warnings: warnings, version: version, cacheable: cacheable)
    }

    /// Pure tag interpretation uses the SAME rules for fresh and cached reads.
    private func resolveExifToolMetadata(
        _ raw: RawExifToolMetadata, for fileURLs: [URL], timeZoneOverride: TimeZone?,
        cancellationToken: WorkCancellationToken?, progress: (Int) -> Void
    ) throws -> ExifToolMetadata {
        let metadataRecords = raw.records
        guard raw.available else {
            return ExifToolMetadata(captureDates: [:], timeZoneSummaries: unknownTimeZoneSummaries(for: fileURLs),
                warnings: raw.warnings, exifToolVersion: raw.version)
        }
        var warnings = raw.warnings
        var timeZoneAnchors: [TimeZoneAnchor] = []
        for record in metadataRecords {
            try cancellationToken?.check()
            if let anchor = timeZoneAnchor(from: record) { timeZoneAnchors.append(anchor) }
        }
        var datesByPath: [String: Date] = [:]
        var instantsByPath: [String: Date] = [:]
        var recordsByPath: [String: [String: Any]] = [:]

        for (index, record) in metadataRecords.enumerated() {
            try cancellationToken?.check()
            defer { progress(index + 1) }
            guard let sourcePath = record["SourceFile"] as? String else {
                continue
            }

            let sourceURL = URL(fileURLWithPath: sourcePath)
            recordsByPath[pathKey(sourceURL)] = record
            guard let kind = mediaKind(for: sourceURL.pathExtension) else {
                continue
            }

            if let errorMessage = record["Error"] as? String {
                warnings.append(
                    metadataWarning(
                        sourceURL: sourceURL,
                        record: record,
                        message: "ExifTool error: \(errorMessage)"
                    )
                )
            } else if let warningMessage = record["Warning"] as? String,
                      isSeriousExifToolWarning(warningMessage) {
                warnings.append(
                    metadataWarning(
                        sourceURL: sourceURL,
                        record: record,
                        message: "ExifTool warning: \(warningMessage)"
                    )
                )
            }

            let date: Date?
            if kind == .video {
                date = videoCaptureDate(
                    from: record,
                    sourceURL: sourceURL,
                    timeZoneAnchors: timeZoneAnchors,
                    timeZoneOverride: timeZoneOverride
                )
            } else {
                let metadataValue = metadataDateValue(
                    from: record,
                    kind: kind
                )
                date = adjustedDate(
                    metadataValue?.date,
                    sourceOffsetSeconds: metadataOffsetSeconds(from: record),
                    timeZoneOverride: timeZoneOverride
                )
            }

            if let date {
                datesByPath[pathKey(sourceURL)] = date
                instantsByPath[pathKey(sourceURL)] = metadataCaptureInstant(from: record, kind: kind)
            }
        }

        for fileURL in fileURLs where
        mediaKind(for: fileURL.pathExtension) == .raw &&
        datesByPath[pathKey(fileURL)] == nil {
            warnings.append(
                metadataWarning(
                    sourceURL: fileURL,
                    record: recordsByPath[pathKey(fileURL)],
                    message: "RAW capture time was not found. Using the file creation date instead. Check camera support in the latest ExifTool version."
                )
            )
        }

        if timeZoneOverride != nil {
            for fileURL in fileURLs where
            Self.sidecarOnlyMetadataExtensions.contains(
                fileURL.pathExtension.lowercased()
            ) {
                warnings.append(
                    metadataWarning(
                        sourceURL: fileURL,
                        record: recordsByPath[pathKey(fileURL)],
                        message: "This format does not support direct metadata writes. Time zone changes will be saved in an XMP sidecar file."
                    )
                )
            }
        }

        return ExifToolMetadata(
            captureDates: datesByPath,
            timeZoneSummaries: makeTimeZoneSummaries(
                fileURLs: fileURLs,
                metadataRecords: metadataRecords
            ),
            warnings: deduplicatedWarnings(warnings),
            exifToolVersion: raw.version,
            detailsByPath: recordsByPath.mapValues { record in
                let kind = (record["SourceFile"] as? String).flatMap {
                    mediaKind(for: URL(fileURLWithPath: $0).pathExtension)
                }
                return record.keys.sorted().filter {
                    ["SubSecDateTimeOriginal", "DateTimeOriginal", "OffsetTimeOriginal", "TimeZone", "DaylightSavings", "CreationDate", "CreateDate", "MediaCreateDate", "TrackCreateDate"].contains(String($0.split(separator: ":").last ?? ""))
                }.compactMap { key in record[key].map { "\(key): \($0)" } }
                    .joined(separator: "\n") + "\nResolved capture offset (seconds): \(metadataOffsetSeconds(from: record, kind: kind).map(String.init) ?? "unknown")"
            },
            captureInstants: instantsByPath
        )
    }

    private static func exifToolProgressIndex(in line: String, batchTotal: Int) -> Int? {
        guard line.hasPrefix("======== "), line.hasSuffix("]"),
              let bracket = line.lastIndex(of: "[") else { return nil }
        let values = line[line.index(after: bracket)..<line.index(before: line.endIndex)]
            .split(separator: "/")
        guard values.count == 2, let index = Int(values[0]), let total = Int(values[1]),
              total == batchTotal, (1...total).contains(index) else { return nil }
        return index
    }

    private func metadataDateValue(
        from record: [String: Any],
        kind: MediaKind? = nil
    ) -> MetadataDateValue? {
        let preferredKeys: [String]

        if kind == .video {
            // A native MOV can contain a camera-clock DateTimeOriginal and a
            // different QuickTime CreateDate. The QuickTime value represents
            // the video timeline; prefer it before maker-note timestamps.
            preferredKeys = [
                "CreationDate",
                "CreateDate",
                "MediaCreateDate",
                "TrackCreateDate",
                "SubSecDateTimeOriginal",
                "DateTimeOriginal"
            ]
        } else {
            preferredKeys = [
                "SubSecDateTimeOriginal",
                "DateTimeOriginal",
                "CreationDate",
                "CreateDate",
                "MediaCreateDate",
                "TrackCreateDate"
            ]
        }

        for key in preferredKeys {
            guard let value = record[key] as? String else { continue }
            if let date = parseMetadataDate(value) {
                return MetadataDateValue(date: date, key: key)
            }
        }

        return nil
    }

    private func videoCaptureDate(
        from record: [String: Any],
        sourceURL: URL,
        timeZoneAnchors: [TimeZoneAnchor],
        timeZoneOverride: TimeZone?
    ) -> Date? {
        let quickTimeValue = firstMetadataDateValue(
            in: record,
            keys: [
                "CreationDate",
                "CreateDate",
                "MediaCreateDate",
                "TrackCreateDate"
            ]
        )
        let cameraValue = firstMetadataDateValue(
            in: record,
            keys: ["SubSecDateTimeOriginal", "DateTimeOriginal"]
        )

        // Photomuri가 갱신한 영상에는 현지시각과 UTC offset이
        // Keys:CreationDate에 함께 기록됩니다. 이 값이 있으면 오래된
        // 카메라 maker-note보다 우선하여 재작업 시에도 같은 시각을 씁니다.
        if let creationDate = record["CreationDate"] as? String,
           let date = parseMetadataDate(creationDate) {
            return adjustedDate(
                date,
                sourceOffsetSeconds: timeZoneSuffixSeconds(in: creationDate),
                timeZoneOverride: timeZoneOverride
            )
        }

        if let cameraValue {
            return adjustedDate(
                cameraValue.date,
                sourceOffsetSeconds: metadataOffsetSeconds(from: record),
                timeZoneOverride: timeZoneOverride
            )
        }

        guard let quickTimeValue else {
            return nil
        }

        if Self.utcVideoDateKeys.contains(quickTimeValue.key),
           let timeZoneOverride {
            return convertedWallClockDate(
                quickTimeValue.date,
                sourceOffsetSeconds: 0,
                targetTimeZone: timeZoneOverride
            )
        }

        // A recorded Nikon offset is stronger evidence than neighboring photos.
        // QuickTime's integer timestamp stays UTC; apply the effective camera
        // offset once when constructing the local wall clock.
        if Self.utcVideoDateKeys.contains(quickTimeValue.key),
           let offset = metadataOffsetSeconds(from: record, kind: .video) {
            return quickTimeValue.date.addingTimeInterval(TimeInterval(offset))
        }

        // Transcoded videos commonly retain only a timezone-less QuickTime
        // UTC timestamp. Without a user override, recover its local wall-clock
        // from a same-day photo or a consistent anchor within 48 hours.
        if Self.utcVideoDateKeys.contains(quickTimeValue.key),
           let anchor = closestTimeZoneAnchor(
            to: quickTimeValue.date,
            sourceURL: sourceURL,
            among: timeZoneAnchors
           ),
           let offsetSeconds = anchor.offsetSeconds {
            return quickTimeValue.date.addingTimeInterval(
                TimeInterval(offsetSeconds)
            )
        }

        return quickTimeValue.date
    }

    private func metadataCaptureInstant(from record: [String: Any], kind: MediaKind) -> Date? {
        let localDate: Date?
        let offset: Int?
        if kind == .video {
            if let creation = record["CreationDate"] as? String,
               let date = parseMetadataDate(creation) {
                localDate = date
                offset = timeZoneSuffixSeconds(in: creation)
            } else if let camera = firstMetadataDateValue(
                in: record, keys: ["SubSecDateTimeOriginal", "DateTimeOriginal"]
            ) {
                localDate = camera.date
                offset = metadataOffsetSeconds(from: record)
            } else if let quickTime = firstMetadataDateValue(
                in: record, keys: ["CreateDate", "MediaCreateDate", "TrackCreateDate"]
            ), Self.utcVideoDateKeys.contains(quickTime.key) {
                localDate = quickTime.date
                offset = 0
            } else {
                return nil
            }
        } else {
            localDate = metadataDateValue(from: record, kind: kind)?.date
            offset = metadataOffsetSeconds(from: record)
        }
        guard let localDate, let offset,
              let sourceZone = TimeZone(secondsFromGMT: offset) else { return nil }
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond], from: localDate
        )
        var sourceCalendar = Calendar(identifier: .gregorian)
        sourceCalendar.timeZone = sourceZone
        return sourceCalendar.date(from: components)
    }

    private func adjustedDate(
        _ localDate: Date?,
        sourceOffsetSeconds: Int?,
        timeZoneOverride: TimeZone?
    ) -> Date? {
        guard let localDate else { return nil }
        guard let timeZoneOverride,
              let sourceOffsetSeconds else {
            return localDate
        }

        return convertedWallClockDate(
            localDate,
            sourceOffsetSeconds: sourceOffsetSeconds,
            targetTimeZone: timeZoneOverride
        )
    }

    private func convertedWallClockDate(
        _ localDate: Date,
        sourceOffsetSeconds: Int,
        targetTimeZone: TimeZone
    ) -> Date? {
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond],
            from: localDate
        )

        guard let sourceTimeZone = TimeZone(
            secondsFromGMT: sourceOffsetSeconds
        ) else {
            return localDate
        }

        var sourceCalendar = Calendar(identifier: .gregorian)
        sourceCalendar.locale = Locale(identifier: "en_US_POSIX")
        sourceCalendar.timeZone = sourceTimeZone

        guard let absoluteDate = sourceCalendar.date(from: components) else {
            return localDate
        }

        var targetCalendar = Calendar(identifier: .gregorian)
        targetCalendar.locale = Locale(identifier: "en_US_POSIX")
        targetCalendar.timeZone = CaptureTimeZonePolicy(
            timeZone: targetTimeZone,
            applyDaylightSavingTime: applyDaylightSavingTime
        ).effectiveTimeZone(on: absoluteDate)
        let targetComponents = targetCalendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond],
            from: absoluteDate
        )

        var wallClockCalendar = calendar
        wallClockCalendar.timeZone = calendar.timeZone
        return wallClockCalendar.date(from: targetComponents) ?? localDate
    }

    private func firstMetadataDateValue(
        in record: [String: Any],
        keys: [String]
    ) -> MetadataDateValue? {
        for key in keys {
            guard let value = record[key] as? String,
                  let date = parseMetadataDate(value) else {
                continue
            }
            return MetadataDateValue(date: date, key: key)
        }

        return nil
    }

    private func timeZoneAnchor(
        from record: [String: Any]
    ) -> TimeZoneAnchor? {
        guard let sourcePath = record["SourceFile"] as? String else {
            return nil
        }

        let sourceURL = URL(fileURLWithPath: sourcePath)
        guard mediaKind(for: sourceURL.pathExtension) != .video,
              let localDate = metadataDateValue(
                from: record,
                kind: mediaKind(for: sourceURL.pathExtension)
              )?.date else {
            return nil
        }

        return TimeZoneAnchor(
            sourceURL: sourceURL,
            localDate: localDate,
            offsetSeconds: metadataOffsetSeconds(from: record)
        )
    }

    private func metadataOffsetSeconds(
        from record: [String: Any],
        kind: MediaKind? = nil
    ) -> Int? {
        if kind == .video,
           let creationDate = record["CreationDate"] as? String,
           let seconds = timeZoneSuffixSeconds(in: creationDate) {
            return seconds
        }

        // EXIF offsets and offsets embedded in date strings already include DST.
        for key in ["OffsetTimeOriginal"] {
            if let explicitOffset = record[key] as? String,
               let seconds = parseTimeZoneOffset(explicitOffset) {
                return seconds
            }
        }

        for key in ["SubSecDateTimeOriginal", "DateTimeOriginal"] {
            if let value = record[key] as? String,
               let seconds = timeZoneSuffixSeconds(in: value) {
                return seconds
            }
        }

        // Family 5 records the metadata path. Keep the WorldTime base offset
        // paired with its own DST flag, not a duplicate NikonTags effective offset.
        let worldTimeKeys = record.keys.sorted().filter {
            $0.contains("WorldTime") && $0.hasSuffix(":TimeZone")
        }
        for key in worldTimeKeys {
            guard let text = record[key] as? String,
                  let base = parseTimeZoneOffset(text) else { continue }
            if let daylight = pairedNikonDaylightSavings(for: key, in: record) {
                return base + (nikonDaylightSavings(daylight) ? 3600 : 0)
            }
        }
        // Older metadata records may have a Nikon group without a path.
        for key in record.keys.sorted() where key.hasSuffix(":TimeZone") && key.contains("Nikon") {
            guard let text = record[key] as? String,
                  let offset = parseTimeZoneOffset(text) else { continue }
            if let daylight = pairedNikonDaylightSavings(for: key, in: record) {
                return offset + (nikonDaylightSavings(daylight) ? 3600 : 0)
            }
        }
        // NikonTags outside WorldTime can carry an already effective offset.
        // Never attach another group's DST flag to that value.
        for key in record.keys.sorted() where key.hasSuffix(":TimeZone") {
            if let text = record[key] as? String,
               let offset = parseTimeZoneOffset(text) { return offset }
        }
        if let text = record["TimeZone"] as? String,
           let offset = parseTimeZoneOffset(text) {
            let isNikon = (record["Make"] as? String)?.lowercased().contains("nikon") == true
            return offset + (isNikon && nikonDaylightSavings(record["DaylightSavings"]) ? 3600 : 0)
        }

        return nil
    }

    private func nikonDaylightSavings(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.intValue == 1 }
        return ["yes", "on", "1", "true"].contains((value as? String)?.lowercased() ?? "")
    }

    private func pairedNikonDaylightSavings(for offsetKey: String, in record: [String: Any]) -> Any? {
        func source(_ key: String) -> [String] {
            key.split(separator: ":").dropLast().map(String.init).filter {
                !$0.hasPrefix("Copy")
            }
        }
        return record.keys.sorted().first {
            $0.hasSuffix(":DaylightSavings") && source($0) == source(offsetKey)
        }.flatMap { record[$0] }
    }

    /// Preserve every grouped tag for source-sensitive offset interpretation,
    /// while supplying deterministic aliases to existing date/camera readers.
    private func normalizedMetadataRecord(_ record: [String: Any]) -> [String: Any] {
        var normalized = record
        let tags = ["SourceFile", "Error", "Warning", "Make", "Model", "FileType",
                    "SubSecDateTimeOriginal", "DateTimeOriginal", "OffsetTimeOriginal",
                    "CreationDate", "CreateDate", "MediaCreateDate", "TrackCreateDate"]
        for tag in tags {
            let keys = record.keys.filter { $0 == tag || $0.hasSuffix(":" + tag) }
                .sorted { left, right in
                    func rank(_ key: String) -> Int {
                        if tag == "CreateDate", key.hasPrefix("QuickTime:") { return 0 }
                        if tag == "CreationDate", key.hasPrefix("Keys:") { return 0 }
                        if key.hasPrefix("ExifIFD:") { return 1 }
                        if key.hasPrefix("Composite:") { return 1 }
                        if key == tag { return 2 }
                        if key.hasPrefix("Nikon:") { return 3 }
                        return 4
                    }
                    let l = rank(left), r = rank(right)
                    return l == r ? left < right : l < r
                }
            if let key = keys.first { normalized[tag] = record[key] }
        }
        return normalized
    }

    private func timeZoneSuffixSeconds(in value: String) -> Int? {
        guard let range = value.range(
            of: #"([+-]\d{2}:?\d{2}|Z)$"#,
            options: .regularExpression
        ) else {
            return nil
        }

        let suffix = String(value[range])
        return suffix == "Z" ? 0 : parseTimeZoneOffset(suffix)
    }

    private func parseTimeZoneOffset(_ value: String) -> Int? {
        let compact = value.replacingOccurrences(of: ":", with: "")
        guard compact.count == 5,
              let signCharacter = compact.first,
              signCharacter == "+" || signCharacter == "-",
              let hours = Int(compact.dropFirst().prefix(2)),
              let minutes = Int(compact.suffix(2)),
              (0...23).contains(hours),
              (0...59).contains(minutes) else {
            return nil
        }

        let sign = signCharacter == "-" ? -1 : 1
        return sign * ((hours * 60 + minutes) * 60)
    }

    private func makeTimeZoneSummaries(
        fileURLs: [URL],
        metadataRecords: [[String: Any]]
    ) -> [CaptureTimeZoneSummary] {
        let recordsByPath: [String: [String: Any]] = Dictionary(
            uniqueKeysWithValues: metadataRecords.compactMap { record in
                guard let sourcePath = record["SourceFile"] as? String else {
                    return nil
                }
                return (pathKey(URL(fileURLWithPath: sourcePath)), record)
            }
        )

        var counts: [String: TimeZoneCount] = [:]

        for fileURL in fileURLs {
            guard let kind = mediaKind(for: fileURL.pathExtension) else {
                continue
            }

            let offsetSeconds = recordsByPath[pathKey(fileURL)].flatMap {
                metadataOffsetSeconds(from: $0, kind: kind)
            }
            let key = offsetSeconds.map(String.init) ?? "unknown"
            var count = counts[key] ?? TimeZoneCount(
                offsetSeconds: offsetSeconds,
                imageCount: 0,
                videoCount: 0
            )

            if kind == .video {
                count.videoCount += 1
            } else {
                count.imageCount += 1
            }
            counts[key] = count
        }

        return counts.values.map {
            CaptureTimeZoneSummary(
                offsetSeconds: $0.offsetSeconds,
                imageCount: $0.imageCount,
                videoCount: $0.videoCount
            )
        }
        .sorted { left, right in
            switch (left.offsetSeconds, right.offsetSeconds) {
            case let (left?, right?):
                return left < right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return false
            }
        }
    }

    private func unknownTimeZoneSummaries(
        for fileURLs: [URL]
    ) -> [CaptureTimeZoneSummary] {
        let imageCount = fileURLs.filter {
            guard let kind = mediaKind(for: $0.pathExtension) else {
                return false
            }
            return kind != .video
        }.count
        let videoCount = fileURLs.filter {
            mediaKind(for: $0.pathExtension) == .video
        }.count

        guard imageCount + videoCount > 0 else { return [] }
        return [
            CaptureTimeZoneSummary(
                offsetSeconds: nil,
                imageCount: imageCount,
                videoCount: videoCount
            )
        ]
    }

    private func closestTimeZoneAnchor(
        to videoDate: Date,
        sourceURL: URL,
        among anchors: [TimeZoneAnchor]
    ) -> TimeZoneAnchor? {
        let usableAnchors = anchors.filter { $0.offsetSeconds != nil }
        let sameDayAnchors = usableAnchors.filter {
            calendar.isDate($0.localDate, inSameDayAs: videoDate)
        }

        if let sameDay = bestAnchor(
            in: sameDayAnchors,
            sourceURL: sourceURL,
            referenceDates: [videoDate]
        ) {
            return sameDay
        }

        guard let closest = bestAnchor(
            in: usableAnchors,
            sourceURL: sourceURL,
            referenceDates: [videoDate]
        ) else {
            return nil
        }

        // A nearby photo is useful for timezone recovery after transcoding,
        // but a week-wide window can accidentally mix separate trips.
        let maximumDistance: TimeInterval = 48 * 60 * 60
        guard abs(closest.localDate.timeIntervalSince(videoDate))
                <= maximumDistance else {
            return nil
        }

        return closest
    }

    private func closestSameDayAnchor(
        toEither firstDate: Date,
        or secondDate: Date,
        sourceURL: URL,
        among anchors: [TimeZoneAnchor]
    ) -> TimeZoneAnchor? {
        let sameDayAnchors = anchors.filter {
            calendar.isDate($0.localDate, inSameDayAs: firstDate)
            || calendar.isDate($0.localDate, inSameDayAs: secondDate)
        }

        return bestAnchor(
            in: sameDayAnchors,
            sourceURL: sourceURL,
            referenceDates: [firstDate, secondDate]
        )
    }

    private func bestAnchor(
        in anchors: [TimeZoneAnchor],
        sourceURL: URL,
        referenceDates: [Date]
    ) -> TimeZoneAnchor? {
        guard !anchors.isEmpty else { return nil }

        let sourceStem = sourceURL.deletingPathExtension().lastPathComponent
        let sourceSequence = filenameSequence(in: sourceStem)

        return anchors.min { left, right in
            let leftSequenceDistance = sequenceDistance(
                sourceSequence,
                filenameSequence(
                    in: left.sourceURL.deletingPathExtension().lastPathComponent
                )
            )
            let rightSequenceDistance = sequenceDistance(
                sourceSequence,
                filenameSequence(
                    in: right.sourceURL.deletingPathExtension().lastPathComponent
                )
            )

            if leftSequenceDistance != rightSequenceDistance {
                return leftSequenceDistance < rightSequenceDistance
            }

            let leftTimeDistance = referenceDates.map {
                abs(left.localDate.timeIntervalSince($0))
            }.min() ?? .greatestFiniteMagnitude
            let rightTimeDistance = referenceDates.map {
                abs(right.localDate.timeIntervalSince($0))
            }.min() ?? .greatestFiniteMagnitude

            return leftTimeDistance < rightTimeDistance
        }
    }

    private func filenameSequence(
        in stem: String
    ) -> FilenameSequence? {
        guard let range = stem.range(
            of: #"\d+$"#,
            options: .regularExpression
        ),
        let number = Int(stem[range]) else {
            return nil
        }

        let prefix = String(stem[..<range.lowerBound]).folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        return FilenameSequence(prefix: prefix, number: number)
    }

    private func sequenceDistance(
        _ first: FilenameSequence?,
        _ second: FilenameSequence?
    ) -> Int {
        guard let first, let second, first.prefix == second.prefix else {
            return Int.max
        }
        return abs(first.number - second.number)
    }
    
    private func imageCaptureDate(
        from url: URL,
        kind: MediaKind
    ) -> Date? {
        guard kind != .video,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                0,
                nil
              ) as NSDictionary? else {
            return nil
        }
        
        var dateTexts: [String] = []
        
        if let exif = properties[
            kCGImagePropertyExifDictionary
        ] as? NSDictionary {
            if let original = exif[
                kCGImagePropertyExifDateTimeOriginal
            ] as? String {
                dateTexts.append(original)
            }
            
            if let digitized = exif[
                kCGImagePropertyExifDateTimeDigitized
            ] as? String {
                dateTexts.append(digitized)
            }
        }
        
        if let tiff = properties[
            kCGImagePropertyTIFFDictionary
        ] as? NSDictionary,
           let dateTime = tiff[
            kCGImagePropertyTIFFDateTime
           ] as? String {
            dateTexts.append(dateTime)
        }
        
        for dateText in dateTexts {
            if let date = parseMetadataDate(dateText) {
                return date
            }
        }
        
        return nil
    }
    
    private func parseMetadataDate(_ value: String) -> Date? {
        if let date = dateParsingCache?.dates[value] { return date }
        if dateParsingCache?.invalid.contains(value) == true { return nil }
        // A filename should keep the wall-clock time recorded at the capture
        // location. Do not convert it to the Mac's current time zone.
        let localCaptureValue = value.replacingOccurrences(
            of: #"([+-]\d{2}:?\d{2}|Z)$"#,
            with: "",
            options: .regularExpression
        )

        let formats = [
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy:MM:dd HH:mm:ss.SSSSSS",
            "yyyy:MM:dd HH:mm:ss.SSS",
            "yyyy:MM:dd HH:mm:ss",
        ]
        
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = format
            formatter.isLenient = false
            
            if let date = formatter.date(from: localCaptureValue) {
                dateParsingCache?.dates[value] = date
                return date
            }
        }
        
        dateParsingCache?.invalid.insert(value)
        return nil
    }
    
    private func mediaKind(for fileExtension: String) -> MediaKind? {
        
        let ext = fileExtension.lowercased()
        
        if Self.jpegExtensions.contains(ext) {
            return .jpeg
        }
        if Self.rawExtensions.contains(ext) {
            return .raw
        }
        if Self.videoExtensions.contains(ext) {
            return .video
        }
        return nil
    }
    
    // MARK: - Shot grouping
    
    private func makeShots(from items: [MediaItem]) -> [MediaShot] {
        let groups = Dictionary(grouping: items) {
            $0.originalStem.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
        }
        
        let sortedGroups = groups.values.sorted { left, right in
            let leftDate = left.map(\.captureDate).min() ?? .distantPast
            let rightDate = right.map(\.captureDate).min() ?? .distantPast
            
            if leftDate != rightDate {
                return leftDate < rightDate
            }
            
            let leftName = left.first?.originalStem ?? ""
            let rightName = right.first?.originalStem ?? ""
            return leftName.localizedStandardCompare(rightName) == .orderedAscending
        }
        
        return sortedGroups.enumerated().map { offset, group in
            let sortedItems = group.sorted {
                $0.sourceURL.lastPathComponent.localizedStandardCompare(
                    $1.sourceURL.lastPathComponent
                ) == .orderedAscending
            }
            let stem = sortedItems.first?.originalStem ?? ""
            
            return MediaShot(
                id: stem.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                ),
                originalStem: stem,
                captureDate: sortedItems.map(\.captureDate).min() ?? .distantPast,
                sequenceIndex: offset + 1,
                items: sortedItems
            )
        }
    }
    
    // MARK: - Rename plan
    
    private func makeRenamePlan(
        shots: [MediaShot],
        folderURL: URL,
        renameTemplate: String,
        renameEnabled: Bool
    ) -> [RenamePlanItem] {
        shots.flatMap { shot in
            shot.items.map { item in
                let shouldRename = renameEnabled
                && !hasDatePrefix(item.originalStem)
                let destinationFolder = folderURL.appendingPathComponent(
                    classificationFolderName(for: item.kind),
                    isDirectory: true
                )
                let destinationFilename: String
                if shouldRename {
                    destinationFilename = RenameTemplateParser.render(
                        template: renameTemplate,
                        date: shot.captureDate,
                        originalStem: item.originalStem,
                        sequenceIndex: shot.sequenceIndex,
                        fileExtension: item.fileExtension
                    )
                } else {
                    destinationFilename = item.sourceURL.lastPathComponent
                }
                let destinationURL = destinationFolder.appendingPathComponent(
                    destinationFilename
                )
                
                return RenamePlanItem(
                    mediaItem: item,
                    shotID: shot.id,
                    sequenceIndex: shot.sequenceIndex,
                    destinationURL: destinationURL,
                    shouldRename: shouldRename
                )
            }
        }
    }

    private func classificationFolderName(for kind: MediaKind) -> String {
        switch kind {
        case .jpeg:
            return "JPG"
        case .raw:
            return "RAW"
        case .video:
            return "VIDEO"
        }
    }
    
    /// stem의 시작이 유효한 YYMMDD 또는 YYYYMMDD 날짜이면 rename을 건너뜁니다.
    private func hasDatePrefix(_ stem: String) -> Bool {
        let digits = String(stem.prefix { $0.isNumber })
        
        if digits.count >= 8,
           isValidDatePrefix(String(digits.prefix(8)), fourDigitYear: true) {
            return true
        }
        
        if digits.count >= 6,
           isValidDatePrefix(String(digits.prefix(6)), fourDigitYear: false) {
            return true
        }
        
        return false
    }
    
    private func isValidDatePrefix(
        _ value: String,
        fourDigitYear: Bool
    ) -> Bool {
        let yearLength = fourDigitYear ? 4 : 2
        let expectedLength = yearLength + 4
        guard value.count == expectedLength else { return false }
        
        let characters = Array(value)
        let yearText = String(characters[0..<yearLength])
        let monthText = String(characters[yearLength..<(yearLength + 2)])
        let dayText = String(characters[(yearLength + 2)..<expectedLength])
        
        guard let parsedYear = Int(yearText),
              let month = Int(monthText),
              let day = Int(dayText) else {
            return false
        }
        
        let year = fourDigitYear ? parsedYear : 2000 + parsedYear
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day
        )
        
        guard let date = calendar.date(from: components) else {
            return false
        }
        
        let checked = calendar.dateComponents(
            [.year, .month, .day],
            from: date
        )
        return checked.year == year
        && checked.month == month
        && checked.day == day
    }
    
    // MARK: - Collision check
    
    private func findCollisions(
        in plan: [RenamePlanItem],
        preserveOriginals: Bool
    ) -> [RenameCollision] {
        let groupedByDestination = Dictionary(grouping: plan) {
            pathKey($0.destinationURL)
        }
        var collisions: [RenameCollision] = []
        
        for group in groupedByDestination.values where group.count > 1 {
            collisions.append(
                RenameCollision(
                    destinationURL: group[0].destinationURL,
                    sourceURLs: group.map { $0.mediaItem.sourceURL },
                    reason: "Multiple files have the same final filename."
                )
            )
        }
        
        let duplicatedKeys = Set(
            groupedByDestination.compactMap { key, value in
                value.count > 1 ? key : nil
            }
        )
        let itemsToClassify = plan.filter {
            pathKey($0.mediaItem.sourceURL) != pathKey($0.destinationURL)
        }
        let vacatedSourceKeys: Set<String> = preserveOriginals
        ? []
        : Set(
            itemsToClassify.map {
                pathKey($0.mediaItem.sourceURL)
            }
        )
        
        for item in itemsToClassify {
            let destinationKey = pathKey(item.destinationURL)
            guard !duplicatedKeys.contains(destinationKey) else { continue }
            
            if fileManager.fileExists(atPath: item.destinationURL.path),
               !vacatedSourceKeys.contains(destinationKey) {
                collisions.append(
                    RenameCollision(
                        destinationURL: item.destinationURL,
                        sourceURLs: [item.mediaItem.sourceURL],
                        reason: "A file with the same name already exists at the destination."
                    )
                )
            }
        }
        
        return collisions.sorted {
            $0.destinationURL.path.localizedStandardCompare(
                $1.destinationURL.path
            ) == .orderedAscending
        }
    }
    
    private func pathKey(_ url: URL) -> String {
        url.standardizedFileURL.path.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
    }

    private func exifToolVersion(
        executableURL: URL,
        libraryURL: URL
    ) throws -> String? {
        let result = try ExifToolProcessRunner.run(arguments: [executableURL.path, "-ver"],
            libraryURL: libraryURL, stage: "1/3 ExifTool version query", filenames: [executableURL.lastPathComponent])
        guard result.status == 0 else {
            throw NSError(domain: "Photomuri.ExifToolExit", code: Int(result.status), userInfo: [
                NSLocalizedDescriptionKey: "1/3 ExifTool version query — \(executableURL.lastPathComponent): exit \(result.status). \(result.error)"
            ])
        }
        let version = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
    }

    private func exifToolUnavailableWarnings(
        for fileURLs: [URL]
    ) -> [MetadataReadWarning] {
        fileURLs.compactMap { fileURL in
            guard mediaKind(for: fileURL.pathExtension) == .raw else {
                return nil
            }
            return MetadataReadWarning(
                sourceURL: fileURL,
                message: "RAW metadata could not be checked because the bundled ExifTool is unavailable."
            )
        }
    }

    private func metadataWarning(
        sourceURL: URL,
        record: [String: Any]?,
        message: String
    ) -> MetadataReadWarning {
        let make = (record?["Make"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (record?["Model"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cameraName = [make, model]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " ")

        return MetadataReadWarning(
            sourceURL: sourceURL,
            cameraName: cameraName.isEmpty ? nil : cameraName,
            message: message
        )
    }

    private func isSeriousExifToolWarning(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return ["unsupported", "error", "corrupt", "invalid"]
            .contains { normalized.contains($0) }
    }

    private func deduplicatedWarnings(
        _ warnings: [MetadataReadWarning]
    ) -> [MetadataReadWarning] {
        var seen: Set<String> = []
        return warnings.filter { warning in
            let key = pathKey(warning.sourceURL) + "|" + warning.message
            return seen.insert(key).inserted
        }
    }

    private struct MetadataDateValue {
        let date: Date
        let key: String
    }

    private final class DateParsingCache {
        var dates: [String: Date] = [:]
        var invalid: Set<String> = []
    }

    private struct RawExifToolMetadata {
        let records: [[String: Any]]
        let warnings: [MetadataReadWarning]
        let version: String?
        var available = true
        var cacheable = true
    }

    private struct ExifToolMetadata {
        let captureDates: [String: Date]
        let timeZoneSummaries: [CaptureTimeZoneSummary]
        let warnings: [MetadataReadWarning]
        let exifToolVersion: String?
        var detailsByPath: [String: String] = [:]
        var captureInstants: [String: Date] = [:]
    }

    private struct TimeZoneCount {
        let offsetSeconds: Int?
        var imageCount: Int
        var videoCount: Int
    }

    private struct TimeZoneAnchor {
        let sourceURL: URL
        let localDate: Date
        let offsetSeconds: Int?
    }

    private struct FilenameSequence {
        let prefix: String
        let number: Int
    }

    private static let utcVideoDateKeys: Set<String> = [
        "CreateDate", "MediaCreateDate", "TrackCreateDate"
    ]

    private static let jpegExtensions: Set<String> = [
        "jpg", "jpeg"
    ]
    
    private static let rawExtensions: Set<String> = [
        "3fr", "arw", "cr2", "cr3", "dng", "erf", "fff", "iiq",
        "kdc", "mef", "mos", "mrw", "nef", "nrw", "orf", "pef",
        "raf", "raw", "rw2", "rwl", "sr2", "srf", "srw", "x3f"
    ]
    
    private static let videoExtensions: Set<String> = [
        "avi", "m4v", "mkv", "mov", "mp4", "mts", "m2ts", "webm"
    ]

    /// Read/classify support exists, but ExifTool 13.59 does not write these
    /// containers directly. Stage 2 stores requested metadata in XMP instead.
    private static let sidecarOnlyMetadataExtensions: Set<String> = [
        "3fr", "kdc", "srf",
        "avi", "mkv", "mts", "m2ts", "webm"
    ]
}

/// Metadata reading and plan assembly share one file counter. Never move it
/// backwards when the cached records are later converted into MediaItems.
private final class AnalysisProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private let total: Int
    private let handler: StageOneAnalyzer.ProgressHandler?
    private var completed = -1

    init(total: Int, handler: StageOneAnalyzer.ProgressHandler?) {
        self.total = max(total, 0)
        self.handler = handler
    }

    func report(_ value: Int) {
        lock.lock()
        let next = min(max(value, 0), total)
        guard next > completed else { lock.unlock(); return }
        completed = next
        lock.unlock()
        handler?(next, total)
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }

        return stride(from: 0, to: count, by: size).map { start in
            Array(self[start..<Swift.min(start + size, count)])
        }
    }
}

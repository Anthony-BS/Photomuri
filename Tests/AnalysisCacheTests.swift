import Foundation
import ImageIO
import CoreGraphics
import Darwin

@main
struct AnalysisCacheTests {
    static let fm = FileManager.default
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError(message) }
    }
    static func signature(_ result: StageOneResult) -> [String] {
        let items = result.mediaItems.map { "\($0.sourceURL.path)|\($0.captureDate.timeIntervalSince1970)|\($0.captureInstant?.timeIntervalSince1970.description ?? "nil")|\($0.captureDateDetails)" }.sorted()
        let plans = result.renamePlan.map { "\($0.destinationURL.path)|\($0.sequenceIndex)|\($0.shouldRename)|\($0.shotID)" }.sorted()
        let warnings = result.metadataWarnings.map { "\($0.sourceURL.path)|\($0.cameraName ?? "")|\($0.message)" }.sorted()
        let collisions = result.collisions.map { "\($0.destinationURL.path)|\($0.reason)|\($0.sourceURLs.map(\.path).sorted())" }.sorted()
        let summaries = result.timeZoneSummaries.map { "\($0.offsetSeconds?.description ?? "nil")|\($0.imageCount)|\($0.videoCount)" }.sorted()
        return items + plans + warnings + collisions + summaries + [result.exifToolVersion ?? "", result.timeZoneOverrideIdentifier ?? "", String(result.applyDaylightSavingTime)]
    }
    static func fakeBundle(_ root: URL) throws -> (Bundle, URL) {
        let bundleRoot = root.appendingPathComponent("Fake.bundle")
        let resources = bundleRoot.appendingPathComponent("Contents/Resources/ExifTool")
        try fm.createDirectory(at: resources.appendingPathComponent("lib"), withIntermediateDirectories: true)
        try Data("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>Photomuri.CacheTests</string></dict></plist>".utf8)
            .write(to: bundleRoot.appendingPathComponent("Contents/Info.plist"))
        let script = #"""
        use JSON::PP;
        open my $log, '>>', "$0.calls" or die $!;
        print $log join(' ', @ARGV), "\n"; close $log;
        if (grep { $_ eq '-ver' } @ARGV) { print '13.59'; exit 0; }
        if (-e "$0.fail") { print STDERR 'test read failure'; exit 1; }
        die 'Missing provenance groups' unless grep { $_ eq '-G1:4:5' } @ARGV;
        my @records;
        for my $path (@ARGV) {
            next unless $path =~ /\.(JPG|NEF|MOV|MKV)$/;
            my $record = {
                'ExifIFD:DateTimeOriginal' => '2026:10:07 11:47:28',
                'ExifIFD:OffsetTimeOriginal' => '+11:00',
                'Nikon:WorldTime:TimeZone' => '+10:00',
                'Nikon:WorldTime:DaylightSavings' => 'Yes',
            };
            if ($path =~ /video\.MOV$/) {
                $record = {
                    'QuickTime:CreateDate' => '2026:10:07 00:47:58',
                    'Nikon:NikonTags:TimeZone' => '+11:00',
                    'Nikon:Copy1:NikonTags-WorldTime:TimeZone' => '+10:00',
                    'Nikon:NikonTags-WorldTime:DaylightSavings' => 'Yes',
                };
            } elsif ($path =~ /utc\.(MOV|MKV)$/) {
                $record = {'QuickTime:CreateDate' => '2026:10:07 00:48:58'};
            } elsif ($path =~ /explicit\.MOV$/) {
                $record = {'Keys:CreationDate' => '2026:10:07 11:47:58-07:00'};
            } elsif ($path =~ /fallback\.(JPG|NEF)$/) { $record = {}; }
            $record->{SourceFile} = $path;
            push @records, $record;
        }
        print encode_json(\@records);
        """#
        let tool = resources.appendingPathComponent("exiftool")
        try Data(script.utf8).write(to: tool)
        return (Bundle(path: bundleRoot.path)!, tool)
    }
    static func calls(_ tool: URL) -> Int {
        ((try? String(contentsOfFile: tool.path + ".calls", encoding: .utf8)) ?? "").split(separator: "\n").count
    }
    static func jpeg(_ url: URL) throws {
        let context = CGContext(data: nil, width: 32, height: 48, bitsPerComponent: 8, bytesPerRow: 128,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let output = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(output, context.makeImage()!, [kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: "2026:10:07 11:47:28", kCGImagePropertyExifOffsetTimeOriginal: "+11:00"
        ]] as CFDictionary)
        check(CGImageDestinationFinalize(output), "Fixture JPEG")
    }
    static func main() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("Photomuri-CacheTests-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let (bundle, tool) = try fakeBundle(root)
        let folder = root.appendingPathComponent("mixed")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["photo.JPG", "photo.NEF", "video.MOV", "utc.MOV", "utc.MKV", "explicit.MOV", "fallback.NEF"] {
            try Data("fixture".utf8).write(to: folder.appendingPathComponent(name))
        }
        try jpeg(folder.appendingPathComponent("fallback.JPG"))
        let template = "YYMMDD_hhmmss [original]_[s5]"
        let first = try StageOneAnalyzer(bundle: bundle).analyze(folderURL: folder, renameTemplate: template, preserveOriginals: true)
        check(first.metadataSnapshot != nil && !first.reusedMetadata, "First read snapshot")
        for dst in [true, false] {
            for zoneID in ["Australia/Sydney", "Australia/Lord_Howe", "Europe/London", "America/New_York", "Asia/Seoul"] {
                let analyzer = StageOneAnalyzer(bundle: bundle, applyDaylightSavingTime: dst)
                let zone = TimeZone(identifier: zoneID)!
                let before = calls(tool)
                var phases: [StageOneAnalysisPhase] = [], counts: [Int] = []
                let cached = try analyzer.analyze(folderURL: folder, renameTemplate: template, timeZoneOverride: zone,
                    preserveOriginals: true, metadataSnapshot: first.metadataSnapshot,
                    observer: StageOneAnalysisObserver { phases.append($0) }) { completed, _ in counts.append(completed) }
                check(calls(tool) == before && cached.reusedMetadata, "Cached read must launch NO ExifTool including version query")
                check(!phases.contains(.readingMetadata) && phases.contains(.planning), "Cached phase labels")
                check(counts == Array(0...8), "Cached progress 0..8")
                let fresh = try analyzer.analyze(folderURL: folder, renameTemplate: template, timeZoneOverride: zone, preserveOriginals: true)
                check(signature(cached) == signature(fresh), "Fresh/cached equivalence: \(zoneID), DST \(dst)")
            }
        }
        let recorded = try StageOneAnalyzer(bundle: bundle).analyze(folderURL: folder, renameTemplate: template,
            preserveOriginals: true, metadataSnapshot: first.metadataSnapshot)
        check(recorded.reusedMetadata && signature(recorded) == signature(first), "Keep recorded time zone also safely reuses raw read")
        print("PASS: zero ExifTool launches on cache hit; exact photo/RAW pair, Nikon effective/base DST offsets, UTC/explicit video, sidecar warnings, ImageIO/file fallback equivalence across 5 zones x DST ON/OFF")

        func invalidation(_ name: String, mutation: (URL) throws -> Void) throws {
            let directory = root.appendingPathComponent(name)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("photo.JPG")
            try Data("fixture".utf8).write(to: file)
            let old = try StageOneAnalyzer(bundle: bundle).analyze(folderURL: directory, renameTemplate: template)
            try mutation(file)
            let before = calls(tool)
            let result = try StageOneAnalyzer(bundle: bundle).analyze(folderURL: directory, renameTemplate: template,
                timeZoneOverride: TimeZone(identifier: "Australia/Sydney")!, metadataSnapshot: old.metadataSnapshot)
            check(!result.reusedMetadata && (calls(tool) > before || result.mediaItems.isEmpty), "Invalidation: \(name)")
        }
        try invalidation("same-size-restored-mtime") { file in
            let date = try fm.attributesOfItem(atPath: file.path)[.modificationDate] as! Date
            // Non-atomic, same size: inode unchanged. Only ctime reveals edit.
            let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
            try handle.write(contentsOf: Data("changed".utf8))
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        }
        try invalidation("replaced") { file in
            let date = try fm.attributesOfItem(atPath: file.path)[.modificationDate] as! Date
            try Data("fixture".utf8).write(to: file, options: .atomic)
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        }
        try invalidation("added") { file in try Data().write(to: file.deletingLastPathComponent().appendingPathComponent("added.JPG")) }
        try invalidation("deleted") { file in try fm.removeItem(at: file) }
        try invalidation("renamed") { file in try fm.moveItem(at: file, to: file.deletingLastPathComponent().appendingPathComponent("new.JPG")) }
        try invalidation("creation-date") { file in try fm.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: file.path) }
        print("PASS: source edit with restored mtime, inode replacement, added/deleted/renamed file, creation-date change => fresh metadata read")

        let collisionDir = root.appendingPathComponent("collision")
        try fm.createDirectory(at: collisionDir, withIntermediateDirectories: true)
        try Data().write(to: collisionDir.appendingPathComponent("photo.JPG"))
        let base = try StageOneAnalyzer(bundle: bundle).analyze(folderURL: collisionDir, renameTemplate: template, preserveOriginals: true)
        let planned = try StageOneAnalyzer(bundle: bundle).analyze(folderURL: collisionDir, renameTemplate: template,
            timeZoneOverride: TimeZone(identifier: "Asia/Seoul")!, preserveOriginals: true, metadataSnapshot: base.metadataSnapshot)
        let destination = planned.renamePlan[0].destinationURL
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("foreign".utf8).write(to: destination)
        let beforeCollision = calls(tool)
        let blocked = try StageOneAnalyzer(bundle: bundle).analyze(folderURL: collisionDir, renameTemplate: template,
            timeZoneOverride: TimeZone(identifier: "Asia/Seoul")!, preserveOriginals: true, metadataSnapshot: base.metadataSnapshot)
        check(blocked.reusedMetadata && !blocked.collisions.isEmpty && calls(tool) == beforeCollision, "Destination collisions checked even on cache hit")

        let token = WorkCancellationToken()
        let beforeCancel = calls(tool)
        do {
            _ = try StageOneAnalyzer(bundle: bundle).analyze(folderURL: folder, renameTemplate: template,
                metadataSnapshot: first.metadataSnapshot, cancellationToken: token) { completed, _ in
                    if completed == 1 { token.cancel() }
                }
            fatalError("Expected cancellation")
        } catch is WorkCancellationError {}
        check(calls(tool) == beforeCancel, "Cached cancellation cannot launch child processes")

        var injected = false
        let during = try StageOneAnalyzer(bundle: bundle).analyze(folderURL: folder, renameTemplate: template,
            metadataSnapshot: first.metadataSnapshot, observer: StageOneAnalysisObserver { phase in
                if phase == .planning && !injected {
                    injected = true
                    try! Data().write(to: folder.appendingPathComponent("during.JPG"))
                }
            })
        check(!during.reusedMetadata && during.mediaItems.count == 9, "Addition during cached plan => fresh retry")
        print("PASS: cached destination collision checks, cancellation, concurrent source addition during planning => safe fresh retry")

        try Data().write(to: URL(fileURLWithPath: tool.path + ".fail"))
        let failed = try StageOneAnalyzer(bundle: bundle).analyze(folderURL: folder, renameTemplate: template)
        check(failed.metadataSnapshot == nil && !failed.metadataWarnings.isEmpty, "Failed metadata reads must not be cached")
        try fm.removeItem(atPath: tool.path + ".fail")
        let recovered = try StageOneAnalyzer(bundle: bundle).analyze(folderURL: folder, renameTemplate: template, metadataSnapshot: failed.metadataSnapshot)
        check(recovered.metadataSnapshot != nil && !recovered.reusedMetadata, "Retry transient failures")
        print("PASS: failed reads not cached; recovery retries ExifTool")

        let large = root.appendingPathComponent("1001")
        try fm.createDirectory(at: large, withIntermediateDirectories: true)
        for n in 0..<1001 { try Data().write(to: large.appendingPathComponent(String(format: "photo_%04d.JPG", n))) }
        let largeBase = try StageOneAnalyzer(bundle: bundle).analyze(folderURL: large, renameTemplate: template)
        let beforeLarge = calls(tool)
        var largeCounts: [Int] = []
        let largeCached = try StageOneAnalyzer(bundle: bundle).analyze(folderURL: large, renameTemplate: template,
            timeZoneOverride: TimeZone(identifier: "Australia/Sydney")!, metadataSnapshot: largeBase.metadataSnapshot) { n, total in
                largeCounts.append(n); check(total == 1001, "Large cached total")
            }
        check(largeCached.reusedMetadata && calls(tool) == beforeLarge && largeCounts == Array(0...1001), "1001 cached counters, no repeated batches")
        var releasable = try StageOneAnalyzer(bundle: bundle).analyze(folderURL: collisionDir, renameTemplate: template)
        weak var weakSnapshot = releasable.metadataSnapshot
        check(weakSnapshot != nil, "Weak snapshot exists")
        releasable.metadataSnapshot = nil
        check(weakSnapshot == nil, "Releasing workflow snapshot frees cache without cycles")
        weakSnapshot = nil
        var otherCalendar = Calendar(identifier: .gregorian)
        otherCalendar.timeZone = TimeZone(secondsFromGMT: largeBase.metadataSnapshot!.calendar.timeZone.secondsFromGMT() == 0 ? 3600 : 0)!
        let differentContext = try StageOneAnalyzer(calendar: otherCalendar, bundle: bundle).analyze(folderURL: large,
            renameTemplate: template, metadataSnapshot: largeBase.metadataSnapshot)
        check(!differentContext.reusedMetadata, "Different parsing calendar must invalidate date cache")
        print("PASS: 1001-file cached counts 0..1001 and zero new batches; workflow cache releases; calendar context invalidation")
    }
}

import Foundation
import CryptoKit
import Darwin

@main
struct WriteBenchmark {
    static let fm = FileManager.default
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError(message) }
    }
    static func hash(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var digest = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func exif(_ args: [String], bundle: Bundle) throws -> [[String: Any]] {
        let tool = bundle.url(forResource: "exiftool", withExtension: nil, subdirectory: "ExifTool")!
        let result = try ExifToolProcessRunner.run(arguments: [tool.path, "-j"] + args,
            libraryURL: tool.deletingLastPathComponent().appendingPathComponent("lib"), stage: "benchmark verification", filenames: [])
        check(result.status == 0, result.error)
        return try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as! [[String: Any]]
    }
    static func setAttribute(_ url: URL, key: String, data: Data) throws {
        let rc = data.withUnsafeBytes { setxattr(url.path, key, $0.baseAddress, $0.count, 0, 0) }
        guard rc == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
    static func attribute(_ url: URL, key: String) throws -> Data {
        let size = getxattr(url.path, key, nil, 0, 0, 0)
        guard size >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, key, $0.baseAddress, $0.count, 0, 0) }
        check(read == size, "xattr read")
        return data
    }
    static func main() throws {
        let args = CommandLine.arguments
        let bundle = Bundle(path: args[1])!, root = URL(fileURLWithPath: args[3])
        let label = args[4], keep = args[5] == "true", output = URL(fileURLWithPath: args[6])
        defer { try? fm.removeItem(at: root) }
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[2]))) as! [[String: Any]]
        let originals = Array(manifest.prefix(100)).map { URL(fileURLWithPath: $0["path"] as! String) }
        let originalHashes = try originals.map(hash)
        let folder = root.appendingPathComponent("work")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let tags = try PropertyListSerialization.data(fromPropertyList: ["PhotomuriBenchmark\n6"], format: .binary, options: 0)
        let custom = Data("preserve custom attribute".utf8)
        let fork = Data("resource fork sentinel".utf8)
        let tagKey = "com.apple.metadata:_kMDItemUserTags", customKey = "com.byastra.photomuri.test", forkKey = "com.apple.ResourceFork"
        let creation = Date(timeIntervalSince1970: 1_600_000_000)
        for (n, original) in originals.enumerated() {
            let url = folder.appendingPathComponent(String(format: "sample_%03d.JPG", n))
            try fm.copyItem(at: original, to: url)
            try fm.setAttributes([.creationDate: creation, .posixPermissions: 0o640], ofItemAtPath: url.path)
            try setAttribute(url, key: tagKey, data: tags)
            try setAttribute(url, key: customKey, data: custom)
            try setAttribute(url, key: forkKey, data: fork)
        }
        let beforeEncoded = try exif(["-ImageDataHash", "-Orientation", "-Make", "-Model", "-LensModel", "-ISO", "-ExposureTime"] + originals.map(\.path), bundle: bundle)
        check(beforeEncoded.count == 100 && beforeEncoded.allSatisfy { $0["ImageDataHash"] != nil }, "Encoded-image hash must be present on every JPEG")
        let base = try StageOneAnalyzer(bundle: bundle).analyze(folderURL: folder, renameTemplate: "YYMMDD_hhmmss [original]_[s5]", preserveOriginals: keep)
        let plan = try StageOneAnalyzer(bundle: bundle).analyze(folderURL: folder, renameTemplate: "YYMMDD_hhmmss [original]_[s5]",
            timeZoneOverride: TimeZone(identifier: "Australia/Sydney")!, preserveOriginals: keep, metadataSnapshot: base.metadataSnapshot)
        check(plan.mediaItems.count == 100 && plan.collisions.isEmpty, "Plan")
        let byStem = Dictionary(uniqueKeysWithValues: base.mediaItems.map { ($0.originalStem, $0.captureDate) })
        check(plan.mediaItems.filter { $0.captureDate != byStem[$0.originalStem] }.count == 100, "All 100 times must change")
        let inputHashes = try Dictionary(uniqueKeysWithValues: plan.mediaItems.map { ($0.sourceURL.path, try hash($0.sourceURL)) })
        var progress: [Int] = []
        let start = ProcessInfo.processInfo.systemUptime
        let result = try StageTwoExecutor(bundle: bundle, workerCount: 4).execute(stageOneResult: plan,
            preserveOriginals: keep, updateCaptureMetadata: true) { completed, total in
                progress.append(completed); check(total == 100, "Progress total")
            }
        let time = ProcessInfo.processInfo.systemUptime - start
        check(result.renamedCount == 100 && result.metadataUpdatedCount == 100 && progress == Array(0...100), "Counts")
        let ordered = plan.renamePlan.sorted { $0.mediaItem.originalStem < $1.mediaItem.originalStem }
        let afterEncoded = try exif(["-ImageDataHash", "-Orientation", "-Make", "-Model", "-LensModel", "-ISO", "-ExposureTime"] + ordered.map { $0.destinationURL.path }, bundle: bundle)
        for (n, record) in afterEncoded.enumerated() {
            for key in ["ImageDataHash", "Orientation", "Make", "Model", "LensModel", "ISO", "ExposureTime"] {
                check(String(describing: record[key]) == String(describing: beforeEncoded[n][key]), "\(key) changed on sample \(n)")
            }
        }
        for item in plan.renamePlan {
            let attrs = try fm.attributesOfItem(atPath: item.destinationURL.path)
            check(abs((attrs[.creationDate] as! Date).timeIntervalSince(creation)) < 0.001, "Creation date changed")
            check((attrs[.posixPermissions] as! NSNumber).intValue == 0o640, "Permissions changed")
            for (key, expected) in [(tagKey, tags), (customKey, custom), (forkKey, fork)] {
                let actual = try attribute(item.destinationURL, key: key)
                check(actual == expected, "Attribute changed: \(key)")
            }
            if keep {
                let actual = try hash(item.mediaItem.sourceURL)
                check(actual == inputHashes[item.mediaItem.sourceURL.path], "Preserved source changed")
            } else { check(!fm.fileExists(atPath: item.mediaItem.sourceURL.path), "Move source left") }
        }
        let read = try StageOneAnalyzer(bundle: bundle).analyze(folderURL: folder.appendingPathComponent("JPG"), renameTemplate: "[original]")
        let planned = Dictionary(uniqueKeysWithValues: plan.renamePlan.map { ($0.destinationURL.lastPathComponent, $0.mediaItem) })
        for item in read.mediaItems {
            let expected = planned[item.sourceURL.lastPathComponent]!
            check(item.captureDate == expected.captureDate && item.captureInstant == expected.captureInstant, "Capture date/instant round-trip")
        }
        check(read.mediaItems.count == 100, "Reanalysis count")
        let remaining = fm.enumerator(at: folder, includingPropertiesForKeys: nil)!.allObjects as! [URL]
        check(!remaining.contains { $0.lastPathComponent.hasPrefix(".media-organizer-") || $0.path.hasSuffix("_exiftool_tmp") }, "Leftover staging files")
        let originalAfter = try originals.map(hash)
        check(originalHashes == originalAfter, "Original media changed")
        let payload: [String: Any] = ["mode": label, "count": 100, "workers": 4, "seconds": time,
            "preserveOriginals": keep, "updateCaptureMetadata": true, "sourceBytes": manifest.prefix(100).reduce(0) { $0 + ($1["bytes"] as! Int) },
            "verification": "PASS: exact encoded JPEG hashes, orientation and camera/exposure tags; changed times/instants; creation date, mode, Finder tags, custom xattr/resource fork; originals; no temp leftovers",
            "configuration": "Debug -Onone arm64; actual bundled ExifTool; local copies; only Stage 2 timed"]
        try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
        print(String(format: "%@ preserve=%@ 100 real JPG / 4 workers: %.3fs PASS", label, String(keep), time)); fflush(stdout)
    }
}

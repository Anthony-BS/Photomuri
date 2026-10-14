import Foundation
import CryptoKit
import Darwin

@main
struct MovieWriteTest {
    static let fm = FileManager.default
    static func check(_ ok: @autoclosure () -> Bool, _ message: String) { if !ok() { fatalError(message) } }
    static func digest(_ url: URL, mediaOnly: Bool = false) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        if !mediaOnly {
            while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        } else {
            let length = try file.seekToEnd()
            var position: UInt64 = 0, blocks = 0
            func number(_ bytes: Data) -> UInt64 { bytes.reduce(0) { ($0 << 8) | UInt64($1) } }
            while position < length {
                try file.seek(toOffset: position)
                let header = try file.read(upToCount: 8)!
                check(header.count == 8, "Movie box header")
                var size = number(header.prefix(4)), headerSize: UInt64 = 8
                let kind = String(decoding: header.suffix(4), as: UTF8.self)
                if size == 1 { size = number(try file.read(upToCount: 8)!); headerSize = 16 }
                if size == 0 { size = length - position }
                check(size >= headerSize && position + size <= length, "Movie box bounds")
                if kind == "mdat" {
                    blocks += 1
                    var remaining = size - headerSize
                    while remaining > 0 {
                        let data = try file.read(upToCount: Int(min(remaining, 1_048_576)))!
                        check(!data.isEmpty, "Truncated media payload")
                        hash.update(data: data); remaining -= UInt64(data.count)
                    }
                }
                position += size
            }
            check(blocks > 0, "No encoded media boxes")
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func main() throws {
        let original = URL(fileURLWithPath: CommandLine.arguments[1]), bundle = Bundle(path: CommandLine.arguments[2])!
        let before = try digest(original), beforeMedia = try digest(original, mediaOnly: true)
        for keep in [true, false] {
            let root = fm.temporaryDirectory.appendingPathComponent("Photomuri-FusedMOV-\(UUID())")
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: root) }
            let source = root.appendingPathComponent("video.MOV")
            try fm.copyItem(at: original, to: source)
            let creation = try fm.attributesOfItem(atPath: source.path)[.creationDate] as! Date
            let tags = try PropertyListSerialization.data(fromPropertyList: ["PhotomuriMOV\n6"], format: .binary, options: 0)
            let key = "com.apple.metadata:_kMDItemUserTags"
            check(tags.withUnsafeBytes { setxattr(source.path, key, $0.baseAddress, $0.count, 0, 0) } == 0, "Fixture tags")
            let analysis = try StageOneAnalyzer(bundle: bundle).analyze(folderURL: root, renameTemplate: "YYMMDD_hhmmss [original]",
                timeZoneOverride: TimeZone(identifier: "Asia/Seoul")!, preserveOriginals: keep)
            let result = try StageTwoExecutor(bundle: bundle, workerCount: 4).execute(stageOneResult: analysis,
                preserveOriginals: keep, updateCaptureMetadata: true)
            check(result.metadataUpdatedCount == 1 && result.renamedCount == 1, "Movie counts")
            let output = analysis.renamePlan[0].destinationURL
            let afterMedia = try digest(output, mediaOnly: true)
            check(afterMedia == beforeMedia, "Encoded video/audio payload changed")
            let attrs = try fm.attributesOfItem(atPath: output.path)
            check(abs((attrs[.creationDate] as! Date).timeIntervalSince(creation)) < 0.001, "Movie birth time")
            var actual = Data(count: tags.count)
            let size = actual.withUnsafeMutableBytes { getxattr(output.path, key, $0.baseAddress, $0.count, 0, 0) }
            check(size == tags.count && actual == tags, "Movie Finder tags")
            let reread = try StageOneAnalyzer(bundle: bundle).analyze(folderURL: output.deletingLastPathComponent(), renameTemplate: "[original]")
            check(reread.mediaItems[0].captureDate == analysis.mediaItems[0].captureDate &&
                reread.mediaItems[0].captureInstant == analysis.mediaItems[0].captureInstant, "Movie capture round-trip")
            check(fm.fileExists(atPath: source.path) == keep, "Movie original handling")
            print("PASS: real 189MB Nikon MOV Preserve \(keep), exact mdat encoded video/audio SHA256, capture date/instant, birth time and Finder tags")
        }
        let after = try digest(original)
        check(after == before, "Actual original MOV changed")
    }
}

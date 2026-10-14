import Foundation
import ImageIO
import CoreGraphics
import Darwin

@main
struct PhotomuriProgressTests {
    final class Trace: @unchecked Sendable {
        let lock = NSLock()
        private var values: [(Int, Int)] = []
        func append(_ completed: Int, _ total: Int) {
            lock.lock(); defer { lock.unlock() }
            values.append((completed, total))
        }
        var snapshots: [(Int, Int)] { lock.lock(); defer { lock.unlock() }; return values }
    }
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8)); exit(1) }
    }
    static func main() throws {
        let realBundle = Bundle(path: CommandLine.arguments[1])!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Photomuri-Progress-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try liveAnalysis(root: root)
        try realAnalysis(root: root, bundle: realBundle)
        try stageCounts(root: root, bundle: realBundle)
        try streamingResources(root: root)
        check(FileWorkProgress(completed: 12, total: 3000).countText == "12/3000", "Count label")
        check(FileWorkProgress(completed: 12, total: 3000).fraction == 0.004, "Fill ratio")
        check(FileWorkProgress(total: 0).fraction == 0, "Empty ratio")
        print("PASS: count text and fill ratio agree, including zero totals")
    }
    static func validate(_ trace: Trace, total: Int) {
        let values = trace.snapshots
        check(values.first?.0 == 0 && values.last?.0 == total, "Counter endpoints")
        check(values.allSatisfy { $0.1 == total && (0...total).contains($0.0) }, "Total and count bounds")
        check(zip(values, values.dropFirst()).allSatisfy { $0.0.0 <= $0.1.0 }, "Counter moved backwards")
    }
    static func liveAnalysis(root: URL) throws {
        let resources = root.appendingPathComponent("Live.bundle/Contents/Resources/ExifTool")
        try FileManager.default.createDirectory(at: resources.appendingPathComponent("lib"), withIntermediateDirectories: true)
        try Data("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>Photomuri.LiveProgress</string></dict></plist>".utf8)
            .write(to: root.appendingPathComponent("Live.bundle/Contents/Info.plist"))
        let folder = root.appendingPathComponent("live")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = """
        use JSON::PP;
        use Time::HiRes qw(usleep);
        if (grep { $_ eq '-ver' } @ARGV) { print '13.00'; exit 0; }
        die 'No progress argument' unless grep { $_ eq '-progress' } @ARGV;
        my @files = grep { /\\.JPG$/ } @ARGV;
        my @records;
        my $index = 0;
        for my $file (@files) {
            ++$index;
            print STDERR "======== $file [$index/" . scalar(@files) . "]\\n";
            if ($index == 2) {
                my $ack = "$file.ack";
                for (1..200) { last if -e $ack; usleep(10000); }
                die 'Live callback did not arrive before process exit' unless -e $ack;
            }
            push @records, {SourceFile=>$file, 'ExifIFD:DateTimeOriginal'=>'2026:10:07 11:47:28', 'ExifIFD:OffsetTimeOriginal'=>'+11:00'};
        }
        print encode_json(\\@records);
        """
        try Data(script.utf8).write(to: resources.appendingPathComponent("exiftool"))
        for index in 0..<203 {
            try Data().write(to: folder.appendingPathComponent(String(format: "사진 [%04d].JPG", index)))
        }
        let trace = Trace()
        let result = try StageOneAnalyzer(bundle: Bundle(path: root.appendingPathComponent("Live.bundle").path)!).analyze(
            folderURL: folder, renameTemplate: "YYMMDD_hhmmss [original]"
        ) { completed, total in
            trace.append(completed, total)
            // ExifTool announces the file being opened. At completed 1 / 201,
            // acknowledge the second file in its current 200-file batch.
            if completed == 1 || completed == 201 {
                let path = folder.appendingPathComponent(String(format: "사진 [%04d].JPG.ack", completed))
                try! Data("ack".utf8).write(to: path)
            }
        }
        validate(trace, total: 203)
        check(result.metadataWarnings.isEmpty && result.mediaItems.count == 203,
              "Live batch metadata: \(result.metadataWarnings.first?.message ?? "none"); counts \(trace.snapshots.prefix(10)); files \(result.mediaItems.count)")
        check(trace.snapshots.map(\.0) == Array(0...203), "Per-file callbacks across batch boundary")
        print("PASS: live progress before process exit; 203 per-file counts across 200-file batches; UTF-8/bracket filenames; no backwards jump")
    }
    static func jpegData() -> Data {
        let context = CGContext(data: nil, width: 32, height: 48, bitsPerComponent: 8, bytesPerRow: 128,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: "2026:10:07 11:47:28",
            kCGImagePropertyExifOffsetTimeOriginal: "+11:00"
        ]] as CFDictionary)
        check(CGImageDestinationFinalize(destination), "JPEG fixture generation")
        return data as Data
    }
    static func realAnalysis(root: URL, bundle: Bundle) throws {
        let folder = root.appendingPathComponent("1001-jpegs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = jpegData()
        for index in 0..<1001 {
            try data.write(to: folder.appendingPathComponent(String(format: "photo_%04d.JPG", index)))
        }
        let trace = Trace()
        let result = try StageOneAnalyzer(bundle: bundle).analyze(folderURL: folder, renameTemplate: "YYMMDD_hhmmss [original]") {
            trace.append($0, $1)
        }
        validate(trace, total: 1001)
        check(trace.snapshots.map(\.0) == Array(0...1001), "Real ExifTool per-file progress")
        check(result.mediaItems.count == 1001 && result.metadataWarnings.isEmpty && result.exifToolVersion != nil, "Real metadata analysis")
        print("PASS: actual bundled ExifTool analysis of 1001 generated JPEGs; callbacks 0/1001 through 1001/1001")
    }
    static func stageCounts(root: URL, bundle: Bundle) throws {
        let folder = root.appendingPathComponent("mixed")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = jpegData()
        for name in ["pair.JPG", "pair.NEF", "solo.JPG"] {
            // The NEF-named synthetic entry tests shot counting/classification,
            // not real Nikon RAW decoding or metadata writes.
            try data.write(to: folder.appendingPathComponent(name))
        }
        let analysis = try StageOneAnalyzer(bundle: bundle).analyze(folderURL: folder, renameTemplate: "YYMMDD_hhmmss [original]")
        let rename = Trace(), convert = Trace()
        _ = try StageTwoExecutor(bundle: bundle).execute(stageOneResult: analysis, preserveOriginals: true, updateCaptureMetadata: false) {
            rename.append($0, $1)
        }
        validate(rename, total: 3)
        let conversion = try HEICConverter(bundle: bundle).convert(stageOneResult: analysis, format: .heic, quality: 85) {
            convert.append($0, $1)
        }
        validate(convert, total: 2)
        check(conversion.convertedCount == 2, "Only JPG shots converted")
        check(rename.snapshots.map(\.0) == [0,1,2,3] && convert.snapshots.map(\.0) == [0,1,2], "Stage 2/3 counters")
        let empty = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let emptyAnalysis = try StageOneAnalyzer(bundle: bundle).analyze(folderURL: empty, renameTemplate: "[original]")
        let emptyCopy = Trace(), emptyConvert = Trace()
        _ = try StageTwoExecutor(bundle: bundle).execute(stageOneResult: emptyAnalysis, preserveOriginals: true, updateCaptureMetadata: false) { emptyCopy.append($0, $1) }
        _ = try HEICConverter(bundle: bundle).convert(stageOneResult: emptyAnalysis, format: .heic, quality: 85) { emptyConvert.append($0, $1) }
        validate(emptyCopy, total: 0); validate(emptyConvert, total: 0)
        print("PASS: Stage 2 uses 3 files; Stage 3 uses 2 JPG shots; empty targets report 0/0")
    }
    static func streamingResources(root: URL) throws {
        func count() -> Int { (0..<8192).filter { fcntl(Int32($0), F_GETFD) != -1 }.count }
        let baseline = count()
        for _ in 0..<200 {
            var lines: [String] = []
            let result = try ExifToolProcessRunner.run(arguments: ["-e", "print STDERR qq(progress\\n); print STDOUT 'ok';"],
                libraryURL: root, stage: "streaming resource test", filenames: ["fixture"], stderrLineHandler: { lines.append($0) })
            check(result.status == 0 && lines == ["progress"] && count() == baseline, "Streaming pipe/resource handling")
        }
        let big = try ExifToolProcessRunner.run(arguments: ["-e", "print STDERR 'e' x 1048576; print STDOUT 'o' x 1048576;"],
            libraryURL: root, stage: "streaming drain test", filenames: ["fixture"], stderrLineHandler: { _ in })
        check(big.status == 0 && big.output.count == 1048576 && big.error.count == 1048576, "Streaming stdout/stderr drain")
        print("PASS: 200 streaming invocations, descriptor count \(baseline) unchanged; 1 MiB dual-stream drain")
    }
}

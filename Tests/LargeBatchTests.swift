import Foundation
import ImageIO
import CoreGraphics
import Darwin

@main
struct LargeBatchTest {
    static func main() throws {
        let bundle = Bundle(path: CommandLine.arguments[1])!
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Photomuri-LargeBatch-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let context = CGContext(data: nil, width: 32, height: 48, bitsPerComponent: 8, bytesPerRow: 128,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, context.makeImage()!, [kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: "2026:10:07 11:47:28", kCGImagePropertyExifOffsetTimeOriginal: "+11:00"
        ]] as CFDictionary)
        precondition(CGImageDestinationFinalize(dest))
        let bytes = data as Data
        for n in 0..<4000 { try bytes.write(to: root.appendingPathComponent(String(format: "photo_%04d.JPG", n))) }
        let analysis = try StageOneAnalyzer(bundle: bundle).analyze(folderURL: root,
            renameTemplate: "YYMMDD_hhmmss [original]_[s5]", timeZoneOverride: TimeZone(identifier: "Australia/Sydney"), preserveOriginals: true)
        precondition(analysis.mediaItems.count == 4000 && analysis.collisions.isEmpty)
        var last = -1
        func descriptorCount() -> Int { (0..<8192).filter { fcntl(Int32($0), F_GETFD) != -1 }.count }
        let baseline = descriptorCount()
        var peak = baseline
        let start = ProcessInfo.processInfo.systemUptime
        let result = try StageTwoExecutor(bundle: bundle).execute(stageOneResult: analysis, preserveOriginals: true, updateCaptureMetadata: true) { n, total in
            precondition(n == last + 1 && total == 4000); last = n
            if n % 1000 == 0 {
                peak = max(peak, descriptorCount())
                precondition(peak <= baseline + WorkerConcurrency.limit(WorkerConcurrency.defaultCount) * 5, "Batch descriptor growth")
                print("Large generated batch \(n)/\(total), descriptors \(descriptorCount())"); fflush(stdout)
            }
        }
        let duration = ProcessInfo.processInfo.systemUptime - start
        precondition(result.renamedCount == 4000 && result.metadataUpdatedCount == 4000 && last == 4000)
        precondition(descriptorCount() == baseline, "Batch descriptor leak")
        for item in analysis.mediaItems {
            let actual = try Data(contentsOf: item.sourceURL)
            precondition(actual == bytes, "Preserved input changed")
        }
        let reread = try StageOneAnalyzer(bundle: bundle).analyze(folderURL: root.appendingPathComponent("JPG"), renameTemplate: "[original]")
        precondition(reread.mediaItems.count == 4000 && reread.metadataWarnings.isEmpty)
        let expectedDate = analysis.mediaItems[0].captureDate
        let expectedInstant = analysis.mediaItems[0].captureInstant
        precondition(reread.mediaItems.allSatisfy { $0.captureDate == expectedDate && $0.captureInstant == expectedInstant })
        print(String(format: "PASS: 4000 GENERATED small JPEGs analyzed, copied, renamed, metadata-written and reanalyzed; Stage2 %.3fs; source bytes preserved; all capture times correct; descriptors baseline/peak/final %d/%d/%d. Not a 4000-camera-media throughput test.", duration, baseline, peak, descriptorCount()))
    }
}

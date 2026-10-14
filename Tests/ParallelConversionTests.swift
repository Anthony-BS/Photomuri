import Foundation
import ImageIO
import CoreGraphics
import Darwin

@main
struct ParallelConversionTests {
    static let fm = FileManager.default
    static func check(_ ok: @autoclosure () -> Bool, _ message: String) { if !ok() { fatalError(message) } }
    static func fixture(_ root: URL, count: Int = 12) throws -> StageOneResult {
        let jpg = root.appendingPathComponent("JPG")
        try fm.createDirectory(at: jpg, withIntermediateDirectories: true)
        let context = CGContext(data: nil, width: 1280, height: 800, bitsPerComponent: 8, bytesPerRow: 5120,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.7, green: 0.3, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1280, height: 800))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, context.makeImage()!, [kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:07 11:47:28",
                                           kCGImagePropertyExifOffsetTimeOriginal: "+11:00"]] as CFDictionary)
        check(CGImageDestinationFinalize(dest), "Fixture JPEG")
        var items: [MediaItem] = [], plans: [RenamePlanItem] = [], shots: [MediaShot] = []
        for n in 0..<count {
            let url = jpg.appendingPathComponent("사진 [\(n)].JPG")
            try (data as Data).write(to: url)
            let item = MediaItem(sourceURL: url, originalStem: url.deletingPathExtension().lastPathComponent,
                fileExtension: "JPG", kind: .jpeg, captureDate: Date())
            items.append(item)
            shots.append(MediaShot(id: item.originalStem, originalStem: item.originalStem, captureDate: item.captureDate, sequenceIndex: n+1, items: [item]))
            plans.append(RenamePlanItem(mediaItem: item, shotID: item.originalStem, sequenceIndex: n+1, destinationURL: url, shouldRename: false))
        }
        return StageOneResult(mediaItems: items, shots: shots, renamePlan: plans, collisions: [], timeZoneSummaries: [], timeZoneOverrideIdentifier: nil)
    }
    static func noOutputs(_ folder: URL, except preserved: URL? = nil) throws {
        let entries = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        check(entries.allSatisfy { $0.resolvingSymlinksInPath().path == preserved?.resolvingSymlinksInPath().path }, "Partial/published output left after failure: \(entries)")
    }
    static func main() throws {
        let bundle = Bundle(path: CommandLine.arguments[1])!
        let root = fm.temporaryDirectory.appendingPathComponent("Photomuri-ConversionTests-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func descriptors() -> Int { (0..<8192).filter { fcntl(Int32($0), F_GETFD) != -1 }.count }
        let baseline = descriptors()
        for format in EfficientImageFormat.allCases {
            for count in Set([1, 2, 4, WorkerConcurrency.limit(Int.max)]).sorted() {
                let folder = root.appendingPathComponent("\(format.rawValue)-\(count)")
                let analysis = try fixture(folder)
                let before = try analysis.mediaItems.map { try Data(contentsOf: $0.sourceURL) }
                var progress: [Int] = []
                let result = try HEICConverter(bundle: bundle, workerCount: count).convert(stageOneResult: analysis, format: format, quality: 85) { n, total in
                    progress.append(n); check(total == 12, "Progress total")
                }
                check(result.convertedCount == 12 && progress == Array(0...12), "Monotonic conversion count")
                check(result.peakConcurrentTasks >= (count == 1 ? 1 : 2) && result.peakConcurrentTasks <= count, "Encoding was not parallel/bounded")
                let outputs = try fm.contentsOfDirectory(at: folder.appendingPathComponent(format.folderName), includingPropertiesForKeys: nil)
                check(outputs.count == 12 && outputs.allSatisfy { $0.pathExtension == format.fileExtension }, "Output/temp count")
                for url in outputs {
                    let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
                    let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 512
                    ] as CFDictionary)!
                    check(thumb.width < thumb.height, "Portrait orientation lost")
                    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
                    let exif = properties[kCGImagePropertyExifDictionary] as! NSDictionary
                    check(exif[kCGImagePropertyExifDateTimeOriginal] as? String == "2026:10:07 11:47:28", "Capture date metadata lost")
                    check(exif[kCGImagePropertyExifOffsetTimeOriginal] as? String == "+11:00", "Capture time-zone offset lost")
                }
                let after = try analysis.mediaItems.map { try Data(contentsOf: $0.sourceURL) }
                check(before == after && descriptors() == baseline, "Sources changed / descriptor leak")
                if format == .avif {
                    let tool = bundle.url(forResource: "exiftool", withExtension: nil, subdirectory: "ExifTool")!
                    let json = try ExifToolProcessRunner.run(arguments: [tool.path, "-j", "-n", "-QuickTime:Rotation"] + outputs.map(\.path),
                        libraryURL: tool.deletingLastPathComponent().appendingPathComponent("lib"), stage: "rotation check", filenames: [])
                    let records = try JSONSerialization.jsonObject(with: Data(json.output.utf8)) as! [[String: Any]]
                    check(json.status == 0 && records.count == 12 && records.allSatisfy { ($0["Rotation"] as? NSNumber)?.intValue == 3 }, "AVIF rotation mismatch")
                }
                print("PASS: \(format.displayName), limit \(count), peak \(result.peakConcurrentTasks), 12 outputs, portrait/date/source preservation, monotonic progress")
                fflush(stdout)
            }
        }
        for format in EfficientImageFormat.allCases {
            for action in ["cancel", "bad-source", "destination-race"] {
                let folder = root.appendingPathComponent("\(format.rawValue)-\(action)")
                let analysis = try fixture(folder)
                let original = try analysis.mediaItems.map { try Data(contentsOf: $0.sourceURL) }
                let foreign = folder.appendingPathComponent(format.folderName).appendingPathComponent(
                    analysis.mediaItems[11].sourceURL.deletingPathExtension().lastPathComponent + "." + format.fileExtension)
                let token = WorkCancellationToken()
                if action == "bad-source" { try Data("broken source".utf8).write(to: analysis.mediaItems[5].sourceURL) }
                var injected = false
                do {
                    _ = try HEICConverter(bundle: bundle, workerCount: 2).convert(stageOneResult: analysis, format: format, quality: 85, cancellationToken: token) { n, _ in
                        if n == 1 && !injected {
                            injected = true
                            if action == "cancel" { token.cancel() }
                            if action == "destination-race" { try! Data("foreign file".utf8).write(to: foreign) }
                        }
                    }
                    fatalError("Expected conversion failure")
                } catch {
                    if action == "cancel" { guard case HEICConverterError.cancelled = error else { fatalError("Wrong cancellation: \(error)") } }
                }
                try noOutputs(folder.appendingPathComponent(format.folderName), except: action == "destination-race" ? foreign : nil)
                if action == "destination-race" {
                    let value = try Data(contentsOf: foreign); check(value == Data("foreign file".utf8), "Foreign output overwritten/removed")
                }
                for (n, item) in analysis.mediaItems.enumerated() where action != "bad-source" || n != 5 {
                    let value = try Data(contentsOf: item.sourceURL); check(value == original[n], "Conversion failure changed JPG")
                }
                check(descriptors() == baseline, "Failure descriptor leak")
                print("PASS: \(format.displayName) \(action) waits/cleans all workers and owned temps; inputs and foreign outputs protected")
                fflush(stdout)
            }
        }
    }
}

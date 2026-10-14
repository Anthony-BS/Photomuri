import Foundation
import ImageIO
import CoreGraphics

@main
struct TimeZonePipelineTests {
    static func runExifTool(_ args: [String], bundle: Bundle) throws -> String {
        let executable = bundle.url(forResource: "exiftool", withExtension: nil, subdirectory: "ExifTool")!
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-I", executable.deletingLastPathComponent().appendingPathComponent("lib").path,
                             executable.path] + args
        let out = Pipe(), error = Pipe()
        process.standardOutput = out
        process.standardError = error
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errors = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0, String(data: errors, encoding: .utf8) ?? "ExifTool failed")
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func makeFixture(at url: URL, date: String, bundle: Bundle) throws {
        let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
                                bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.4, green: 0.6, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        _ = try runExifTool(["-overwrite_original", "-EXIF:DateTimeOriginal=\(date)",
                             "-EXIF:CreateDate=\(date)", "-EXIF:OffsetTimeOriginal=+00:00", url.path], bundle: bundle)
    }

    static func main() throws {
        let bundle = Bundle(path: CommandLine.arguments[1])!
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("Photomuri-DST-Pipeline-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        for useDST in [true, false] {
            let folder = root.appendingPathComponent(useDST ? "on" : "off")
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try makeFixture(at: folder.appendingPathComponent("summer.JPG"), date: "2026:07:01 12:34:56", bundle: bundle)
            try makeFixture(at: folder.appendingPathComponent("winter.JPG"), date: "2026:01:01 12:34:56", bundle: bundle)
            try makeFixture(at: folder.appendingPathComponent("foldFirst.JPG"), date: "2026:10:25 00:30:00", bundle: bundle)
            try makeFixture(at: folder.appendingPathComponent("foldSecond.JPG"), date: "2026:10:25 01:30:00", bundle: bundle)
            let analysis = try StageOneAnalyzer(bundle: bundle, applyDaylightSavingTime: useDST).analyze(
                folderURL: folder, renameTemplate: "YYMMDD_hhmmss [original]",
                timeZoneOverride: TimeZone(identifier: "Europe/London")!)
            precondition(analysis.collisions.isEmpty && analysis.mediaItems.count == 4)
            let summerName = useDST ? "260701_133456 summer.JPG" : "260701_123456 summer.JPG"
            precondition(analysis.renamePlan.contains { $0.destinationURL.lastPathComponent == summerName })
            precondition(analysis.renamePlan.contains { $0.destinationURL.lastPathComponent == "260101_123456 winter.JPG" })
            let result = try StageTwoExecutor(bundle: bundle).execute(
                stageOneResult: analysis, preserveOriginals: true, updateCaptureMetadata: true)
            precondition(result.metadataUpdatedCount == 4 && result.copiedCount == 4)
            let summer = analysis.renamePlan.first { $0.mediaItem.originalStem == "summer" }!
            let output = try runExifTool(["-j", "-DateTimeOriginal", "-OffsetTimeOriginal", summer.destinationURL.path], bundle: bundle)
            let metadata = (try JSONSerialization.jsonObject(with: Data(output.utf8)) as! [[String: Any]])[0]
            precondition(metadata["OffsetTimeOriginal"] as? String == (useDST ? "+01:00" : "+00:00"))
            precondition(metadata["DateTimeOriginal"] as? String == (useDST ? "2026:07:01 13:34:56" : "2026:07:01 12:34:56"))
            precondition(manager.fileExists(atPath: folder.appendingPathComponent("summer.JPG").path))
            for (stem, expectedOffset) in [("foldFirst", useDST ? "+01:00" : "+00:00"), ("foldSecond", "+00:00")] {
                let plan = analysis.renamePlan.first { $0.mediaItem.originalStem == stem }!
                let json = try runExifTool(["-j", "-OffsetTimeOriginal", plan.destinationURL.path], bundle: bundle)
                let record = (try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [[String: Any]])[0]
                precondition(record["OffsetTimeOriginal"] as? String == expectedOffset)
            }
            print("PASS: DST \(useDST ? "ON" : "OFF"), mixed summer/winter batch, filename + metadata offsets agree, originals preserved")
        }
        if CommandLine.arguments.count > 2 {
            let uiFolder = URL(fileURLWithPath: CommandLine.arguments[2])
            try manager.createDirectory(at: uiFolder, withIntermediateDirectories: true)
            try makeFixture(at: uiFolder.appendingPathComponent("summer.JPG"), date: "2026:07:01 12:34:56", bundle: bundle)
            print("UI fixture ready: \(uiFolder.path)")
        }
    }
}

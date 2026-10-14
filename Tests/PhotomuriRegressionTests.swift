import Foundation
import Darwin
import ImageIO
import CoreGraphics

@main
struct PhotomuriRegressionTests {
    static let manager = FileManager.default
    static func descriptorCount() -> Int {
        (0..<8192).reduce(0) { $0 + (fcntl(Int32($1), F_GETFD) == -1 ? 0 : 1) }
    }
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }
    static func main() throws {
        if CommandLine.arguments.contains("--handles") {
            let library = URL(fileURLWithPath: "/private/tmp")
            _ = try ExifToolProcessRunner.run(arguments: ["-e", "print 'ok'"], libraryURL: library,
                stage: "resource test", filenames: ["fixture"])
            let baseline = descriptorCount()
            var peak = baseline
            for i in 1...4000 {
                let result = try ExifToolProcessRunner.run(
                    arguments: ["-e", "print STDOUT 'ok'; print STDERR 'warning';"], libraryURL: library,
                    stage: "resource test", filenames: ["fixture"])
                check(result.status == 0 && result.output == "ok" && result.error == "warning", "Process output")
                peak = max(peak, descriptorCount())
                if i % 1000 == 0 { print("Progress: \(i)/4000, descriptors \(descriptorCount())"); fflush(stdout) }
            }
            check(peak == baseline, "Descriptor growth: \(baseline) -> \(peak)")
            for _ in 0..<100 {
                do {
                    _ = try ExifToolProcessRunner.run(arguments: [], libraryURL: library,
                        stage: "2/3 metadata update", filenames: ["broken.NEF"],
                        executableURL: URL(fileURLWithPath: "/does-not-exist/photomuri"))
                    preconditionFailure("Expected launch failure")
                } catch {
                    let error = error as NSError
                    let original = error.userInfo[NSUnderlyingErrorKey] as! NSError
                    check(error.domain == original.domain && error.code == original.code, "NSError identity")
                    check(error.localizedDescription.contains("broken.NEF") && error.localizedDescription.contains("2/3"), "Error context")
                }
            }
            check(descriptorCount() == baseline, "Launch failure descriptor leak")
            let large = try ExifToolProcessRunner.run(arguments: ["-e", "print STDERR 'e' x 1048576; print STDOUT 'o' x 1048576;"],
                libraryURL: library, stage: "dual pipe test", filenames: ["fixture"])
            check(large.status == 0 && large.output.count == 1048576 && large.error.count == 1048576, "Dual-pipe drain")
            print("PASS: 4000 invocations, descriptors baseline/max/final \(baseline)/\(peak)/\(descriptorCount()); 100 failed launches; 1 MiB stdout + stderr; original NSError preserved")
            return
        }
        let bundle = Bundle(path: CommandLine.arguments[1])!
        let root = manager.temporaryDirectory.appendingPathComponent("Photomuri-Nikon-Regression-\(UUID())")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        try testRecordedNikonMetadata(at: root)
        try testNikonWrites(at: root, bundle: bundle)
    }

    static func testRecordedNikonMetadata(at root: URL) throws {
        let resources = root.appendingPathComponent("Fake.bundle/Contents/Resources/ExifTool")
        try manager.createDirectory(at: resources.appendingPathComponent("lib"), withIntermediateDirectories: true)
        try Data("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>Photomuri.Regression</string></dict></plist>".utf8)
            .write(to: root.appendingPathComponent("Fake.bundle/Contents/Info.plist"))
        let script = """
        use JSON::PP;
        if (grep { $_ eq '-ver' } @ARGV) { print '13.00'; exit 0; }
        die 'Missing source groups' unless grep { $_ eq '-G1:4:5' } @ARGV;
        my @records;
        for my $path (@ARGV) {
            next unless $path =~ /\\.(JPG|NEF|MOV)$/;
            open my $f, '<', "$path.json" or die $!;
            local $/; my $record = decode_json(<$f>);
            $record->{SourceFile} = $path;
            push @records, $record;
        }
        print encode_json(\\@records);
        """
        try Data(script.utf8).write(to: resources.appendingPathComponent("exiftool"))
        let bundle = Bundle(path: root.appendingPathComponent("Fake.bundle").path)!
        let folder = root.appendingPathComponent("recorded")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let photo: [String: Any] = [
            "IFD0:Make": "NIKON CORPORATION",
            "ExifIFD:DateTimeOriginal": "2026-10-07T11:47:28",
            "ExifIFD:OffsetTimeOriginal": "+11:00",
            "Nikon:WorldTime:TimeZone": "+10:00",
            "Nikon:WorldTime:DaylightSavings": "Yes"
        ]
        var video: [String: Any] = [
            "Nikon:NikonTags:DateTimeOriginal": "2026-10-07T11:47:58",
            "QuickTime:CreateDate": "2026-10-07T00:47:58",
            "Nikon:NikonTags:TimeZone": "+11:00",
            "Nikon:Copy1:NikonTags-WorldTime:TimeZone": "+10:00",
            "Nikon:NikonTags-WorldTime:DaylightSavings": "Yes"
        ]
        for (filename, metadata) in [("BSN_6545.JPG", photo), ("BSN_6545.NEF", photo), ("BSN_6546.MOV", video)] {
            try Data().write(to: folder.appendingPathComponent(filename))
            try JSONSerialization.data(withJSONObject: metadata).write(to: folder.appendingPathComponent(filename + ".json"))
        }
        for useDST in [true, false] {
            let analyzer = StageOneAnalyzer(bundle: bundle, applyDaylightSavingTime: useDST)
            let result = try analyzer.analyze(folderURL: folder, renameTemplate: "YYMMDD_hhmmss [original]",
                                             timeZoneOverride: TimeZone(identifier: "Australia/Sydney")!)
            check(result.metadataWarnings.isEmpty, "Synthetic metadata warnings")
            check(result.timeZoneSummaries.count == 1 && result.timeZoneSummaries[0].offsetSeconds == 39600, "Effective offset summary")
            for item in result.mediaItems {
                let expected = item.kind == .video ? "2026-10-07T00:47:58Z" : "2026-10-07T00:47:28Z"
                check(item.captureInstant == ISO8601DateFormatter().date(from: expected), "Capture instant")
            }
            let hour = useDST ? "11" : "10"
            check(result.renamePlan.contains { $0.destinationURL.lastPathComponent == "261007_\(hour)4758 BSN_6546.MOV" }, "Nikon MOV plan")
            check(result.renamePlan.contains { $0.destinationURL.lastPathComponent == "261007_\(hour)4728 BSN_6545.JPG" }, "Nikon JPG plan")
            print("PASS: Nikon source-aware +10 + DST => +11; EXIF +11 unchanged; Sydney DST \(useDST ? "ON" : "OFF") plans/summary/instants")
        }
        video.removeValue(forKey: "Nikon:NikonTags:DateTimeOriginal")
        try JSONSerialization.data(withJSONObject: video).write(to: folder.appendingPathComponent("BSN_6546.MOV.json"))
        let utcOnly = try StageOneAnalyzer(bundle: bundle).analyze(folderURL: folder, renameTemplate: "YYMMDD_hhmmss [original]")
        check(utcOnly.renamePlan.contains { $0.destinationURL.lastPathComponent == "261007_114758 BSN_6546.MOV" }, "UTC plus recorded effective offset")
        print("PASS: UTC-only QuickTime + recorded Nikon effective offset, no photo-anchor dependency")
    }

    static func exif(_ args: [String], bundle: Bundle) throws -> String {
        let tool = bundle.url(forResource: "exiftool", withExtension: nil, subdirectory: "ExifTool")!
        let result = try ExifToolProcessRunner.run(arguments: [tool.path] + args,
            libraryURL: tool.deletingLastPathComponent().appendingPathComponent("lib"),
            stage: "fixture metadata", filenames: ["synthetic JPEG"])
        check(result.status == 0, result.error)
        return result.output
    }
    static func testNikonWrites(at root: URL, bundle: Bundle) throws {
        // A minimal Nikon type-3 MakerNote with a real writable WorldTime IFD.
        let maker = Data([78,105,107,111,110,0,2,16,0,0, 73,73,42,0,8,0,0,0,
                          1,0, 36,0,7,0,4,0,0,0, 88,2,1,0, 0,0,0,0])
        let makerURL = root.appendingPathComponent("maker.bin")
        try maker.write(to: makerURL)
        for (region, useDST, expectedBase, expectedFlag, expectedEffective) in [
            ("Australia/Sydney", true, "+10:00", "Yes", "+11:00"),
            ("Australia/Sydney", false, "+10:00", "No", "+10:00"),
            ("Australia/Lord_Howe", true, "+11:00", "No", "+11:00")
        ] {
            let folder = root.appendingPathComponent("write-\(region.split(separator: "/").last!)-\(useDST)")
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            let jpeg = folder.appendingPathComponent("fixture.JPG")
            let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let destination = CGImageDestinationCreateWithURL(jpeg as CFURL, "public.jpeg" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            check(CGImageDestinationFinalize(destination), "JPEG fixture")
            _ = try exif(["-overwrite_original", "-Make=NIKON CORPORATION", "-Model=NIKON Z 6_3",
                          "-MakerNotes<=\(makerURL.path)", "-DateTimeOriginal=2026:10:07 11:47:28",
                          "-OffsetTimeOriginal=+11:00", "-Orientation#=6", jpeg.path], bundle: bundle)
            let source = try Data(contentsOf: jpeg)
            let before = try exif(["-j", "-a", "-G1:4:5", "-TimeZone", "-DaylightSavings", jpeg.path], bundle: bundle)
            check(before.contains("WorldTime"), "Nikon MakerNote fixture missing: \(before)")
            let analysis = try StageOneAnalyzer(bundle: bundle, applyDaylightSavingTime: useDST).analyze(
                folderURL: folder, renameTemplate: "YYMMDD_hhmmss [original]", timeZoneOverride: TimeZone(identifier: region)!)
            _ = try StageTwoExecutor(bundle: bundle).execute(stageOneResult: analysis, preserveOriginals: true, updateCaptureMetadata: true)
            let output = analysis.renamePlan[0].destinationURL
            let json = try exif(["-j", "-TimeZone", "-DaylightSavings", "-OffsetTimeOriginal", output.path], bundle: bundle)
            let record = (try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [[String: Any]])[0]
            check(record["TimeZone"] as? String == expectedBase && record["DaylightSavings"] as? String == expectedFlag && record["OffsetTimeOriginal"] as? String == expectedEffective, "Nikon write values: \(json)")
            let preservedSource = try Data(contentsOf: jpeg)
            check(preservedSource == source, "Source preservation")
            let reanalysis = try StageOneAnalyzer(bundle: bundle).analyze(folderURL: output.deletingLastPathComponent(), renameTemplate: "YYMMDD_hhmmss [original]")
            check(reanalysis.mediaItems[0].captureInstant == analysis.mediaItems[0].captureInstant, "Round-trip instant")
            if region == "Australia/Sydney" && useDST {
                let converted = try HEICConverter(bundle: bundle).convert(stageOneResult: analysis, format: .avif, quality: 85)
                check(converted.convertedCount == 1, "AVIF conversion")
                let avif = folder.appendingPathComponent("AVIF").appendingPathComponent(output.deletingPathExtension().lastPathComponent + ".avif")
                let rotationJSON = try exif(["-j", "-n", "-QuickTime:Rotation", avif.path], bundle: bundle)
                let rotation = (try JSONSerialization.jsonObject(with: Data(rotationJSON.utf8)) as! [[String: Any]])[0]
                // AVIF irot raw value 3 is three CCW quarter-turns = 90° CW.
                check((rotation["Rotation"] as? NSNumber)?.intValue == 3, "AVIF container rotation: \(rotationJSON)")
                print("PASS: AVIF encode + actual ExifTool container rotation 90 degrees")
            }
            _ = try exif(["-overwrite_original", "-EXIF:OffsetTimeOriginal=", output.path], bundle: bundle)
            let nikonOnly = try StageOneAnalyzer(bundle: bundle).analyze(folderURL: output.deletingLastPathComponent(), renameTemplate: "YYMMDD_hhmmss [original]")
            check(nikonOnly.mediaItems[0].captureInstant == analysis.mediaItems[0].captureInstant,
                  "Nikon WorldTime fallback round-trip: expected \(String(describing: analysis.mediaItems[0].captureInstant)), actual \(String(describing: nikonOnly.mediaItems[0].captureInstant)); \(nikonOnly.mediaItems[0].captureDateDetails)")
            print("PASS: Real ExifTool Nikon JPEG write/read \(region), DST \(useDST), base \(expectedBase), flag \(expectedFlag), effective \(expectedEffective); source preserved")
        }
    }
}

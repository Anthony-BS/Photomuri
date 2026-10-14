import Foundation
import Darwin
import ImageIO
import CoreGraphics

@main
struct ParallelStageTwoTests {
    static let fm = FileManager.default
    static func check(_ ok: @autoclosure () -> Bool, _ message: String) {
        if !ok() { fatalError(message) }
    }
    static func descriptors() -> Int { (0..<8192).filter { fcntl(Int32($0), F_GETFD) != -1 }.count }
    static func fixture(_ root: URL, names: [String], metadata: Bool = true) throws -> StageOneResult {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let date = Date(timeIntervalSince1970: 1791334048)
        let items = try names.map { name -> MediaItem in
            let url = root.appendingPathComponent(name)
            try Data("original-\(name)".utf8).write(to: url)
            return MediaItem(sourceURL: url, originalStem: url.deletingPathExtension().lastPathComponent,
                             fileExtension: url.pathExtension, kind: .jpeg, captureDate: date, captureInstant: date)
        }
        let plan = items.map { RenamePlanItem(mediaItem: $0, shotID: $0.originalStem, sequenceIndex: 1,
            destinationURL: root.appendingPathComponent("JPG/renamed " + $0.sourceURL.lastPathComponent), shouldRename: true) }
        return StageOneResult(mediaItems: items, shots: [], renamePlan: plan, collisions: [], timeZoneSummaries: [],
                              timeZoneOverrideIdentifier: metadata ? "Australia/Sydney" : nil)
    }
    static func fakeBundle(_ root: URL) throws -> Bundle {
        let bundleURL = root.appendingPathComponent("Fake.bundle")
        let resource = bundleURL.appendingPathComponent("Contents/Resources/ExifTool")
        try fm.createDirectory(at: resource.appendingPathComponent("lib"), withIntermediateDirectories: true)
        try Data("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>Photomuri.ParallelTests</string></dict></plist>".utf8)
            .write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))
        let script = #"""
        use strict;
        use warnings;
        use Time::HiRes qw(usleep);
        $| = 1;
        select STDERR; $|=1; select STDOUT;
        my @args;
        sub execute_job {
            my ($number) = @_;
            my $status = 0;
            my @files = grep { /\.JPG$/ } @args;
            my $file = $files[-1];
            my $output = $file;
            for my $i (0..$#args-1) { $output = $args[$i+1] if $args[$i] eq '-o'; }
            if (grep { $_ eq '-hang' } @args) { sleep 30; }
            if (grep { $_ eq '-crash' } @args) { print STDERR 'intentional crash'; exit 23; }
            if (grep { $_ eq '-big' } @args) {
                print STDERR ('e' x 1048576), "\n";
                print STDOUT ('o' x 1048576), "\n";
            }
            if (grep { $_ eq '-ver' } @args) { print "13.test\n"; }
            if (defined $file) {
                open my $log, '>>', "$0.pids" or die $!;
                print $log "$$\n"; close $log;
                usleep(20000);
                open my $input, '<', $file or die $!;
                local $/; my $data = <$input>; close $input;
                if ($file =~ /fail/ || $data =~ /fail/) {
                    usleep(80000);
                    open my $tmp, '>', "${output}_exiftool_tmp" or die $!;
                    print $tmp 'partial'; close $tmp;
                    print STDERR "injected file failure\n"; $status = 1;
                } else {
                    open my $out, '>', $output or die $!;
                    print $out $data, 'changed'; close $out;
                    print "1 image files updated\n";
                }
            }
            for my $index (0..$#args-1) {
                next unless $args[$index] eq '-echo3' || $args[$index] eq '-echo4';
                my $text = $args[$index+1]; $text =~ s/\$\{status\}/$status/g;
                if ($args[$index] eq '-echo3') { print "$text\n"; }
                else { print STDERR "$text\n"; }
            }
            print "{ready$number}\n";
            @args = ();
        }
        while (my $line = <STDIN>) {
            chomp $line;
            last if $line eq 'False' && @args && $args[-1] eq '-stay_open';
            if ($line =~ /^-execute(\d+)$/) { execute_job($1); }
            else { push @args, $line; }
        }
        """#
        try Data(script.utf8).write(to: resource.appendingPathComponent("exiftool"))
        return Bundle(path: bundleURL.path)!
    }
    static func main() throws {
        let realBundle = Bundle(path: CommandLine.arguments[1])!
        let root = fm.temporaryDirectory.appendingPathComponent("Photomuri-ParallelTests-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let fake = try fakeBundle(root)
        let fakeTool = fake.url(forResource: "exiftool", withExtension: nil, subdirectory: "ExifTool")!
        let warm = ExifToolSession(toolURL: fakeTool)
        _ = try warm.run(arguments: ["-ver"], stage: "warm", filenames: [])
        warm.close()
        let baseline = descriptors()

        for workers in Set([1, 2, 4, WorkerConcurrency.limit(Int.max)]).sorted() {
        for keep in [true, false] {
            let analysis = try fixture(root.appendingPathComponent("success-\(workers)-\(keep)"), names: (0..<24).map { "사진 [\($0)].JPG" })
            var counts: [Int] = []
            let result = try StageTwoExecutor(bundle: fake, workerCount: workers).execute(stageOneResult: analysis, preserveOriginals: keep, updateCaptureMetadata: true) {
                counts.append($0); check($1 == 24, "Progress total")
            }
            check(result.metadataUpdatedCount == 24 && counts == Array(0...24), "Monotonic progress")
            for item in analysis.renamePlan {
                let data = try Data(contentsOf: item.destinationURL)
                check(data == Data("original-\(item.mediaItem.sourceURL.lastPathComponent.precomposedStringWithCanonicalMapping)changed".utf8), "Worker result: \(item.destinationURL.path): \(String(decoding: data, as: UTF8.self))")
                check(fm.fileExists(atPath: item.mediaItem.sourceURL.path) == keep, "Original handling")
            }
            let pids = Set(try String(contentsOf: URL(fileURLWithPath: fakeTool.path + ".pids"), encoding: .utf8).split(separator: "\n"))
            check(pids.count == workers, "Expected configured reused worker processes")
            try fm.removeItem(at: URL(fileURLWithPath: fakeTool.path + ".pids"))
            check(descriptors() == baseline, "Success descriptor leak")
            print("PASS: rename configured workers \(workers), observed reused processes \(pids.count), Preserve \(keep)")
        }
        }
        print("PASS: 24 files at 1/2/4/CPU-max workers; Preserve ON/OFF; UTF-8 names; ordered progress; descriptors restored")
        for keep in [true, false] {
            let analysis = try fixture(root.appendingPathComponent("destination-race-\(keep)"), names: (0..<20).map { "photo\($0).JPG" })
            let foreign = analysis.renamePlan.last!.destinationURL
            var injected = false
            do {
                _ = try StageTwoExecutor(bundle: fake, workerCount: 4).execute(stageOneResult: analysis,
                    preserveOriginals: keep, updateCaptureMetadata: true) { n, _ in
                        if n == 1 && !injected { injected = true; try! Data("foreign".utf8).write(to: foreign) }
                    }
                fatalError("Expected publication conflict")
            } catch {
                check(injected, "Foreign-file injection")
            }
            let foreignBytes = try Data(contentsOf: foreign)
            check(foreignBytes == Data("foreign".utf8), "Foreign destination overwritten/removed")
            for item in analysis.renamePlan {
                let data = try Data(contentsOf: item.mediaItem.sourceURL)
                check(data == Data("original-\(item.mediaItem.sourceURL.lastPathComponent.precomposedStringWithCanonicalMapping)".utf8), "Race rollback source changed")
                if item.destinationURL != foreign { check(!fm.fileExists(atPath: item.destinationURL.path), "Race partial output left") }
            }
            let entries = fm.enumerator(at: analysis.mediaItems[0].sourceURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)!.allObjects as! [URL]
            check(!entries.contains { $0.lastPathComponent.hasPrefix(".media-organizer-") || $0.path.hasSuffix("_exiftool_tmp") }, "Race staging directory left")
            check(descriptors() == baseline, "Race descriptor leak")
        }
        print("PASS: destination publication races, Preserve ON/OFF; foreign files untouched; originals restored; owned staging dirs removed")
        for keep in [true, false] {
            for cancel in [true, false] {
                let names = (0..<20).map { $0 == 5 && !cancel ? "fail.JPG" : "photo\($0).JPG" }
                let analysis = try fixture(root.appendingPathComponent("rollback-\(keep)-\(cancel)"), names: names)
                let token = WorkCancellationToken()
                do {
                    _ = try StageTwoExecutor(bundle: fake).execute(stageOneResult: analysis, preserveOriginals: keep,
                        updateCaptureMetadata: true, cancellationToken: token) { completed, _ in
                            if cancel && completed == 3 { token.cancel() }
                        }
                    fatalError("Expected rollback")
                } catch {
                    if cancel {
                        guard case StageTwoExecutorError.cancelled = error else { fatalError("Wrong cancellation: \(error)") }
                    } else { check(error.localizedDescription.contains("fail.JPG"), "Failure file context") }
                }
                for item in analysis.renamePlan {
                    let data = try Data(contentsOf: item.mediaItem.sourceURL)
                    check(data == Data("original-\(item.mediaItem.sourceURL.lastPathComponent.precomposedStringWithCanonicalMapping)".utf8), "Rollback changed source")
                    check(!fm.fileExists(atPath: item.destinationURL.path), "Rollback output remained")
                }
                let remaining = fm.enumerator(at: analysis.mediaItems[0].sourceURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)!.allObjects as! [URL]
                check(!remaining.contains { $0.lastPathComponent.hasPrefix(".media-organizer-") || $0.path.hasSuffix("_exiftool_tmp") }, "Temporary artifact remained")
                check(descriptors() == baseline, "Rollback descriptor leak")
            }
        }
        print("PASS: cancellation and mid-batch write failure, Preserve ON/OFF, complete source rollback, no partial/temp output, no live writers")

        for keep in [true, false] {
            let analysis = try fixture(root.appendingPathComponent("copy-only-cancel-\(keep)"), names: (0..<20).map { "photo\($0).JPG" }, metadata: false)
            let token = WorkCancellationToken()
            do {
                _ = try StageTwoExecutor(bundle: fake).execute(stageOneResult: analysis, preserveOriginals: keep,
                    updateCaptureMetadata: false, cancellationToken: token) { count, _ in if count == 2 { token.cancel() } }
                fatalError("Expected no-metadata cancellation")
            } catch { guard case StageTwoExecutorError.cancelled = error else { fatalError("Wrong cancellation") } }
            for item in analysis.renamePlan {
                let actual = try Data(contentsOf: item.mediaItem.sourceURL)
                check(actual == Data("original-\(item.mediaItem.sourceURL.lastPathComponent)".utf8), "No-metadata source rollback")
                check(!fm.fileExists(atPath: item.destinationURL.path), "No-metadata output rollback")
            }
        }
        let swapFixture = try fixture(root.appendingPathComponent("swap"), names: ["A.JPG", "B.JPG"], metadata: false)
        let swapPlans = swapFixture.mediaItems.enumerated().map { n, item in
            RenamePlanItem(mediaItem: item, shotID: item.originalStem, sequenceIndex: n+1,
                           destinationURL: swapFixture.mediaItems[1-n].sourceURL, shouldRename: true)
        }
        let swap = StageOneResult(mediaItems: swapFixture.mediaItems, shots: [], renamePlan: swapPlans,
                                  collisions: [], timeZoneSummaries: [], timeZoneOverrideIdentifier: nil)
        let swapToken = WorkCancellationToken()
        do {
            _ = try StageTwoExecutor(bundle: fake).execute(stageOneResult: swap, preserveOriginals: false,
                updateCaptureMetadata: false, cancellationToken: swapToken) { count, _ in if count == 1 { swapToken.cancel() } }
            fatalError("Expected swap cancellation")
        } catch { guard case StageTwoExecutorError.cancelled = error else { fatalError("Swap rollback error: \(error)") } }
        for item in swap.mediaItems {
            let actual = try Data(contentsOf: item.sourceURL)
            check(actual == Data("original-\(item.sourceURL.lastPathComponent)".utf8), "Swap original restored")
        }
        print("PASS: cancellation without metadata writes, Preserve ON/OFF; cyclic/swap names restore safely")

        let session = ExifToolSession(toolURL: fakeTool, timeout: 0.2)
        let big = try session.run(arguments: ["-big"], stage: "dual pipe", filenames: ["fixture"])
        check(big.output.count == 1048577 && big.error.count == 1048577, "Dual-pipe drain")
        session.close()
        for mode in ["-hang", "-crash"] {
            let failing = ExifToolSession(toolURL: fakeTool, timeout: 0.2)
            do { _ = try failing.run(arguments: [mode], stage: "2/3 metadata update", filenames: ["broken.NEF"]); fatalError("Expected transport failure") }
            catch {
                let error = error as NSError
                let original = error.userInfo[NSUnderlyingErrorKey] as! NSError
                check(error.domain == original.domain && error.code == original.code, "NSError identity")
                check(error.localizedDescription.contains("broken.NEF") && error.localizedDescription.contains("2/3"), "Transport context")
                if mode == "-hang" { check(error.domain == NSPOSIXErrorDomain && error.code == Int(ETIMEDOUT), "Timeout identity") }
            }
            failing.close()
            check(descriptors() == baseline, "Transport descriptor leak")
        }
        let realTool = realBundle.url(forResource: "exiftool", withExtension: nil, subdirectory: "ExifTool")!
        let live = ExifToolSession(toolURL: realTool)
        var peak = 0
        for n in 1...4000 {
            let value = try live.run(arguments: ["-ver"], stage: "persistent stress", filenames: ["version"])
            check(value.status == 0 && value.output.contains("13.59"), "Persistent version")
            if n % 100 == 0 { peak = max(peak, descriptors()); check(descriptors() <= baseline + 3, "Persistent fd growth") }
        }
        live.close()
        check(descriptors() == baseline, "Persistent close leak")
        print("PASS: timeout/crash NSError identity, 1 MiB on each pipe, 4000 real persistent commands, descriptor baseline/peak/final \(baseline)/\(peak)/\(descriptors())")
        try sidecars(root: root, bundle: realBundle)
        for _ in 0..<10 {
            let missing = ExifToolSession(toolURL: fakeTool, executableURL: URL(fileURLWithPath: "/does-not-exist/photomuri"))
            do { _ = try missing.run(arguments: ["-ver"], stage: "launch", filenames: ["broken.NEF"]); fatalError("Expected failed launch") }
            catch { check((error as NSError).userInfo[NSUnderlyingErrorKey] != nil, "Launch NSError") }
            missing.close(); check(descriptors() == baseline, "Launch descriptor leak")
        }
        // A newline path cannot be passed to line-oriented -@ commands.
        let newline = root.appendingPathComponent("line\nbreak.JPG")
        try Data("not an image".utf8).write(to: newline)
        let fallback = ExifToolSession(toolURL: realTool)
        let value = try fallback.run(arguments: ["-FileName", newline.path], stage: "argv fallback", filenames: [newline.lastPathComponent])
        check(value.status == 0 && value.output.contains("break.JPG"), "Newline filename argv fallback")
        fallback.close(); check(descriptors() == baseline, "Fallback descriptor leak")
        print("PASS: ten failed launches and newline filename argv fallback, no descriptor leaks")
    }

    static func sidecars(root: URL, bundle: Bundle) throws {
        let folder = root.appendingPathComponent("sidecars")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let bytes = NSMutableData()
        let dest = CGImageDestinationCreateWithData(bytes, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, context.makeImage()!, nil)
        check(CGImageDestinationFinalize(dest), "Sidecar fixture")
        var items: [MediaItem] = []
        for (name, kind) in [("raw.SRF", MediaKind.raw), ("video.MKV", .video)] {
            let source = folder.appendingPathComponent(name)
            try (bytes as Data).write(to: source)
            items.append(MediaItem(sourceURL: source, originalStem: source.deletingPathExtension().lastPathComponent,
                fileExtension: source.pathExtension, kind: kind, captureDate: Date(), captureInstant: Date()))
        }
        let plans = items.map { RenamePlanItem(mediaItem: $0, shotID: $0.originalStem, sequenceIndex: 1,
            destinationURL: folder.appendingPathComponent("processed/renamed " + $0.sourceURL.lastPathComponent), shouldRename: true) }
        let analysis = StageOneResult(mediaItems: items, shots: [], renamePlan: plans, collisions: [],
            timeZoneSummaries: [], timeZoneOverrideIdentifier: "Australia/Sydney")
        let result = try StageTwoExecutor(bundle: bundle).execute(stageOneResult: analysis, preserveOriginals: true, updateCaptureMetadata: true)
        check(result.metadataUpdatedCount == 2, "Sidecar writes")
        let rawSidecar = plans[0].destinationURL.deletingPathExtension().appendingPathExtension("xmp")
        let videoSidecar = plans[1].destinationURL.appendingPathExtension("xmp")
        for url in [rawSidecar, videoSidecar] {
            let text = try String(contentsOf: url, encoding: .utf8)
            check(text.contains("DateTimeOriginal"), "Sidecar payload")
        }
        for plan in plans {
            let source = try Data(contentsOf: plan.mediaItem.sourceURL), output = try Data(contentsOf: plan.destinationURL)
            check(source == bytes as Data && output == source, "Sidecar mode media preservation")
        }
        // Existing sidecars must be rejected before any source is staged.
        for plan in plans { try fm.removeItem(at: plan.destinationURL) }
        let protected = try Data(contentsOf: rawSidecar)
        do {
            _ = try StageTwoExecutor(bundle: bundle).execute(stageOneResult: analysis, preserveOriginals: false, updateCaptureMetadata: true)
            fatalError("Expected existing-sidecar collision")
        } catch { guard case StageTwoExecutorError.destinationBecameOccupied = error else { fatalError("Wrong sidecar conflict") } }
        let stillProtected = try Data(contentsOf: rawSidecar)
        check(stillProtected == protected && items.allSatisfy { fm.fileExists(atPath: $0.sourceURL.path) }, "Existing XMP/source preservation")
        let leftovers = fm.enumerator(at: folder, includingPropertiesForKeys: nil)!.allObjects as! [URL]
        check(!leftovers.contains { $0.lastPathComponent.hasPrefix(".media-organizer-") }, "Sidecar temporary leftover")
        print("PASS: RAW/video sidecar routing with synthetic JPEG-backed entries (not RAW/MKV decoding), atomic XMP publish, existing XMP protection, original bytes unchanged")
    }
}

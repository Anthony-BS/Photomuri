import SwiftUI
import AppKit

@main
struct PhotomuriApp: App {
    @NSApplicationDelegateAdaptor(PhotomuriApplicationDelegate.self)
    private var applicationDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
        .handlesExternalEvents(matching: ["*"])
        .commands {
            PhotomuriHelpCommands()
        }

        Window("Photomuri Help", id: "photomuri-help") {
            PhotomuriManualView()
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        Window("About Photomuri", id: "photomuri-information") {
            PhotomuriInformationView()
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        Window("About ExifTool", id: "exiftool-information") {
            ExifToolInformationView()
        }
        .defaultSize(width: 620, height: 560)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

@MainActor
private final class PhotomuriApplicationDelegate: NSObject, NSApplicationDelegate {
    private let folderService = PhotomuriFolderService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.servicesProvider = folderService
        NSUpdateDynamicServices()

        // Load the bundled icon directly so a stale Launch Services icon does
        // not determine the running application's Dock appearance.
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL) else {
            return
        }
        NSApplication.shared.applicationIconImage = dockIcon(from: icon)
    }

    private func dockIcon(from artwork: NSImage) -> NSImage {
        // macOS does not mask an image assigned to applicationIconImage.
        // Render only the Dock presentation; keep the supplied artwork intact.
        let canvasSize = NSSize(width: 1024, height: 1024)
        let image = NSImage(size: canvasSize)
        image.lockFocus()
        defer { image.unlockFocus() }

        let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
        let shape = NSBezierPath(roundedRect: tile, xRadius: 184, yRadius: 184)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowBlurRadius = 24
        shadow.shadowOffset = NSSize(width: 0, height: -12)
        shadow.set()
        NSColor.black.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSGraphicsContext.current?.imageInterpolation = .high
        artwork.draw(in: tile, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return image
    }
}

private struct PhotomuriHelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Photomuri…") {
                openWindow(id: "photomuri-information")
            }
        }
        CommandGroup(replacing: .help) {
            Button("Photomuri Help") {
                openWindow(id: "photomuri-help")
            }
            .keyboardShortcut("?", modifiers: .command)
            Button("BYAstra Website") {
                if let url = URL(string: "https://byastra.netlify.app") {
                    openURL(url)
                }
            }
            Divider()
            Button("About Photomuri…") {
                openWindow(id: "photomuri-information")
            }
        }
    }
}

private enum ManualTopic: String, CaseIterable, Identifiable {
    case gettingStarted = "Getting Started"
    case rename = "Rename Files"
    case conversion = "HEIC & AVIF"
    case timeZones = "Time Zones"
    case presets = "Presets"
    case safety = "Preserve Originals"
    case results = "Results & Logs"
    case finder = "Finder Service"
    case troubleshooting = "Troubleshooting"

    var id: String { rawValue }
}

private struct PhotomuriManualView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTopic: ManualTopic? = .gettingStarted

    private var topic: ManualTopic { selectedTopic ?? .gettingStarted }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Photomuri")
                        .font(.title3).fontWeight(.semibold)
                        .padding(.horizontal, 16).padding(.top, 20)
                    Text("User Guide")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                    List(ManualTopic.allCases, selection: $selectedTopic) { entry in
                        Text(entry.rawValue).tag(entry)
                            .padding(.vertical, 3)
                    }
                    .listStyle(.sidebar)
                    .accessibilityLabel("Help Topics")
                }
                .frame(width: 190)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(topic.rawValue).font(.title2).fontWeight(.semibold)
                        topicContent
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                    .textSelection(.enabled)
                }
                .id(topic)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Text("This guide is available offline.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 780, height: 580)
    }

    @ViewBuilder
    private var topicContent: some View {
        switch topic {
        case .gettingStarted:
            paragraph("Before your first run", "Try a small test folder first. Turn on Preserve Originals to work on copies while keeping the source media unchanged.")
            paragraph("1. Choose a Location", "Click Choose… or drop one folder onto the app. Photomuri processes supported media directly inside that folder, not media in its subfolders. Hidden files and unsupported file types are ignored.")
            paragraph("2. Set your options", "Choose a Preset or adjust Rename Files, HEIC/AVIF creation, time zone review and safety options. File-format sorting runs even when Rename Files is off.")
            paragraph("3. Click Start", "With Preserve Originals on, processing starts without an original-file confirmation. With it off, confirm that original files will be modified.")
            paragraph("4. Review and finish", "When enabled, review capture time zones and choose Continue. The Location field shows progress; the completion window displays the outcome and warnings.")
            paragraph("Output folders", "Photomuri creates JPG, RAW and VIDEO folders within the Location. Generated image copies go into HEIC or AVIF. Original file extensions are retained when renaming.")
            callout("Already sorted subfolders are not scanned on later runs. If you preserved originals, running the same folder again can encounter output-name conflicts; existing results are never silently overwritten.")
        case .rename:
            paragraph("Template and preview", "Enable Rename Files and enter a template. Preview shows an example filename, not an actual selected photo. The (i) button next to Rename Files opens the token guide. Turning the option off keeps filenames unchanged while still sorting the files.")
            codeExample("Default template", "YYMMDD_hhmmss [original]", result: "260910_102245 DSC_1234.JPG")
            VStack(alignment: .leading, spacing: 8) {
                Text("Available tokens").font(.headline)
                token("YY / YYYY", "2-digit / 4-digit year")
                token("MM / DD", "2-digit month / day")
                token("hh / mm / ss", "24-hour time / minute / second")
                token("[original]", "Original filename without its extension")
                token("[s1]", "1–9, then repeat from 1")
                token("[s2]", "01–99, then repeat from 01")
                token("[s3]", "001–999, then repeat from 001")
                token("[s4]", "0001–9999, then repeat from 0001")
                token("[s5]", "00001–99999, then repeat from 00001")
                token("\"text\"", "Literal text; double quotes are not included")
            }
            codeExample("Custom text and sequence", "YYMMDD_hhmmss [original]_[s5]_\"abc\"", result: "260910_102245 DSC_1234_00001_abc.JPG")
            paragraph("Spaces, quotes and shot numbering", "Spaces and underscores stay where you enter them. Token-like text inside double quotes is literal text. Sequence numbers advance per shot, not per file: JPG/RAW files with the same original stem share one sequence number. Shot ordering follows capture time, with the original name used to break ties.")
            paragraph("Automatic rename skip", "A filename beginning with a valid YYMMDD or YYYYMMDD date keeps its existing name. Time zone changes do not force such files to be renamed. Sorting and requested metadata updates can still run.")
            callout("Photomuri calculates destination filenames before changing media and checks for conflicts. A repeating sequence can produce duplicates; [original] or a wider sequence can help avoid them.")
        case .conversion:
            paragraph("What is converted?", "Enable Convert JPGs, choose a Format and enter a Quality from 1 to 100. One image copy is created per shot that contains a JPG/JPEG. RAW-only shots and videos are skipped; they are not rendered or transcoded.")
            paragraph("Quality 85", "85 is the default encoder quality setting, not 85% of the original file size or a measured percentage of visual fidelity. HEIC and AVIF use different codecs, so equal quality numbers do not guarantee equal appearance or output sizes.")
            compressionGuide
            paragraph("Choosing quality", "Lower quality usually reduces file size and can introduce more visible artifacts. Higher quality generally uses more space. Conversion at 85 is lossy. Quality 100 does not recover detail lost in the original JPG and is not a byte-for-byte archive of it. Inspect fine detail, text, shadows and gradients at full size before choosing your preferred setting.")
            paragraph("Resolution and orientation", "Photomuri does not resize the photo during conversion. It preserves pixel dimensions and carries orientation through the output; AVIF rotation is also recorded in its container. Display behavior can vary between viewers.")
            callout("Smaller output files do not automatically free disk space. Photomuri keeps the processed JPG as well as its HEIC/AVIF copy; preserved originals also take space.")
        case .timeZones:
            paragraph("Review before changes", "Enable Review & Change Time Zone to see time zones detected in the files before processing. Use Recorded Time Zone keeps the capture time and time zone recorded by the camera. Photomuri cannot determine whether a camera's time zone setting was correct in real life.")
            paragraph("Change Time Zone", "Select Change Time Zone, then search a city, country or country code in English or Korean. Results are grouped by UTC offset. Use the arrow at the end of a row to choose a specific city: cities with the same offset can have different daylight saving rules.")
            paragraph("Apply DST", "Enabled by default, Apply DST uses the selected city's daylight saving rules on each file's capture date. Turn it off to use that city's standard time. A city name with * means DST applies on the preview capture date, not necessarily on every date in the batch.")
            paragraph("Update Metadata to Match Time Zone", "This option is available only when time zone review is enabled, and writes changes only when you choose a different time zone. With it off, selected time zone handling affects calculated filenames without writing matching metadata. With it on, supported photo, RAW and video metadata are updated; formats without embedded-write support use XMP sidecars.")
            paragraph("Missing or previously edited metadata", "Files without reliable time zone information need extra care. Some fall back to file dates. If another app changed only file creation dates or names while leaving capture metadata untouched, values can disagree. Test copies and inspect the detailed log instead of assuming a conversion will repair conflicting metadata.")
            callout("Region rules and bilingual search work offline using macOS time zone data and the bundled city list. Each file uses its own capture date. A selected region is applied to the whole batch; split trips into separate folders if they require different regions.")
        case .presets:
            paragraph("Select and save", "Choose a Preset to apply saved options. Click Save… to name the current settings. Update Current Preset overwrites the selected custom preset; Save as New Preset creates another. Location is not included in presets.")
            paragraph("Default", "Default cannot be overwritten, renamed or deleted. Its starting options are: Rename Files on, template YYMMDD_hhmmss [original], HEIC creation on at quality 85, time zone review on, metadata updates on, Apply DST on and Preserve Originals off. The initial region follows the Mac's time zone.")
            paragraph("Manage…", "Use Manage… to select a saved preset, rename it or delete it. Rename and Delete are disabled for Default.")
            paragraph("After restarting", "The app restores your last-used settings and Location, rather than automatically resetting to Default. The Preset field is blank when those settings do not match a saved preset. Selecting a preset does not replace the Location.")
        case .safety:
            paragraph("Preserve Originals", "On: source media stay in the original Location with their existing names and metadata. Photomuri copies them into format folders and processes those copies. Off: source media are moved into format folders and may be renamed or have metadata changed. The original-file confirmation appears only when this option is off.")
        case .results:
            paragraph("Progress", "The three processing stages are 1/3 Analyzing Files, 2/3 Renaming & Sorting Files and 3/3 Converting to HEIC/AVIF. Each stage shows completed items / total items, and the blue fill follows that ratio. Analysis updates while metadata are being read. Conversion counts JPG-containing shots and is skipped when creation is off.")
            paragraph("Read the completion window", "File Analysis shows the total files and RAW/JPG pairs, RAW-only shots, JPG-only shots and videos. File Processing reports renamed and skipped filenames. Conversion reports converted and skipped shots. A skipped rename can still mean the file was sorted or its metadata was updated.")
            paragraph("Environment & Safety Checks", "This separate section lists the bundled ExifTool version and preflight disk-space/write-access checks. Review warnings and errors before assuming every file was successfully processed.")
            paragraph("Open Output Folder", "Opens the working Location in Finder, where its JPG, RAW, VIDEO, HEIC or AVIF subfolders contain the results.")
            paragraph("Save Detailed Log…", "Saves a text report with settings, timestamps, analysis, source and destination paths, metadata details, conflicts and warnings. Review it before sharing: it can contain personal folder paths, filenames and capture metadata.")
            paragraph("Cancellation is not a full undo", "Click Cancel Task while working. Before file changes, cancellation stops processing. During file processing, Photomuri attempts to roll back that stage. During conversion, it removes outputs created in that conversion stage but keeps completed renaming and sorting results. Check the completion report for rollback errors.")
        case .finder:
            paragraph("Send a folder from Finder", "Right-click one folder in Finder and choose Services → Organize with Photomuri. The service brings the folder into Photomuri as its Location. It does not start processing; review options and click Start yourself.")
            paragraph("If the service is not listed", "Launch Photomuri once, then check macOS System Settings → Keyboard → Keyboard Shortcuts → Services. The exact settings layout can vary with macOS. Enable Organize with Photomuri if needed. Finder may need a moment or a restart to refresh its service list.")
            paragraph("Folder input only", "Select one local folder, not individual photos, an app package or several folders. You can also use Choose… or drag a folder onto the main window.")
            callout("The built-in service does not require a separate Automator workflow. Old Automator workflows can still appear as separate entries if you installed them previously.")
            Link("Apple: Using services on Mac (internet required)",
                 destination: URL(string: "https://support.apple.com/guide/mac-help/mchlp1012/mac")!)
                .font(.caption)
        case .troubleshooting:
            paragraph("Supported input files", "Photomuri scans JPG/JPEG, common RAW extensions including NEF, ARW, CR2, CR3, DNG, RAF and RW2, and video containers including MOV, MP4, M4V, AVI, MKV, MTS, M2TS and WEBM. Recognizing a file extension does not guarantee metadata support. PNG, TIFF and existing HEIC/AVIF files are not currently processed as input media.")
            paragraph("Filename conflicts", "Photomuri will not silently overwrite an existing destination. Check the report, change the template or use a fresh working folder with a few test copies. Date-prefixed filenames keep their names, and wrapping sequence counters may create duplicates.")
            paragraph("Folder access or disk space", "Select the folder again using Choose… to refresh access. Confirm that it is writable and that sufficient space exists for copies and conversion outputs. Cloud files must be available locally; online-only placeholders may fail to read.")
            paragraph("RAW metadata warnings", "Metadata support comes from the bundled ExifTool, not Apple's ability to develop that RAW image. A new camera may need a newer ExifTool in a future app update. Check About Photomuri → About ExifTool for the bundled version and official website. Do not assume a file-date fallback is the true capture time.")
            paragraph("Conversion unavailable or rotated display", "Check that the shot contains a readable JPG and that the selected encoder is available on your Mac. Try HEIC if AVIF cannot be encoded, and verify orientation in another viewer. RAW-only files and videos do not produce HEIC/AVIF copies.")
            paragraph("Unexpected capture time", "Compare recorded offsets and the detailed log. File creation time, embedded capture time and an already-renamed filename can disagree after previous edits. Choose the intended region on test copies first; do not assume every mixed-region file needs the same correction.")
        }
    }

    private var compressionGuide: some View {
        VStack(alignment: .leading, spacing: 12) {
            paragraph("How much smaller at 85?", "For large camera JPGs similar to our small test batch, a rough estimate is about 50–80% smaller per converted file: a 10 MB JPG might become roughly 2–5 MB. This is an estimate, not a guaranteed range or a claim of equal visual quality.")
            paragraph("Measured examples at quality 85", "Three high-resolution camera JPGs were converted with Photomuri's own Apple ImageIO pipeline on a Mac. HEIC files were about 60–83% smaller; AVIF files were about 52–81% smaller. Pixel dimensions were unchanged. These three samples are not a general benchmark.")
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("Original JPG").fontWeight(.medium)
                    Text("HEIC").fontWeight(.medium)
                    Text("AVIF").fontWeight(.medium)
                }
                Divider().gridCellColumns(3)
                GridRow { Text("13.6 MB"); Text("2.6 MB (−81%)"); Text("2.6 MB (−81%)") }
                GridRow { Text("14.3 MB"); Text("5.7 MB (−60%)"); Text("6.9 MB (−52%)") }
                GridRow { Text("19.5 MB"); Text("3.4 MB (−83%)"); Text("4.1 MB (−79%)") }
            }
            .font(.caption)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            callout("Reduction varies with original JPG quality, noise, detail, resolution, metadata and the macOS encoder. An already-small JPG may shrink much less or even produce a larger output. AVIF is not always smaller than HEIC at the same numeric quality. Test your own photos before planning capacity or deleting originals.")
            VStack(alignment: .leading, spacing: 6) {
                Text("Format references (internet required)")
                    .font(.caption).foregroundStyle(.secondary)
                Link("Apple: HEIF and HEVC media", destination: URL(string: "https://support.apple.com/116944")!)
                Link("AOMedia: What is AVIF?", destination: URL(string: "https://aomedia.org/specifications/avif/")!)
            }
            .font(.caption)
        }
    }

    private func paragraph(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(body).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func callout(_ body: String) -> some View {
        Text(body).font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func token(_ name: String, _ description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(name).font(.system(.callout, design: .monospaced))
                .frame(width: 120, alignment: .leading)
            Text(description).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func codeExample(_ title: String, _ template: String, result: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(template).font(.system(.caption, design: .monospaced))
            Text("→ \(result)").font(.system(.caption, design: .monospaced))
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct PhotomuriInformationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Photomuri")
                        .font(.largeTitle)
                        .fontWeight(.semibold)
                    Text("Version \(version)")
                        .foregroundStyle(.secondary)
                    Text("Developed by BYAstra")
                        .foregroundStyle(.secondary)
                }
            }

            Text("Organize photos and videos on your Mac.")
                .font(.headline)

            VStack(alignment: .leading, spacing: 14) {
                feature("Rename & Sort", systemImage: "folder",
                        detail: "Rename files using capture times and custom templates, and sort them into folders by file format.")
                feature("HEIC & AVIF Copies", systemImage: "photo",
                        detail: "Create high-efficiency image copies from JPG files with adjustable quality.")
                feature("Capture Time Zones", systemImage: "globe",
                        detail: "Review recorded time zones, choose a different region, and optionally update metadata to match.")
                feature("Preserve Originals", systemImage: "externaldrive.badge.checkmark",
                        detail: "Keep source media unchanged while processing copies.")
            }

            Divider()

            Text("File processing works offline. Photomuri includes ExifTool for metadata and uses Apple ImageIO for image conversion.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("About ExifTool…") {
                    openWindow(id: "exiftool-information")
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(28)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func feature(_ title: String, systemImage: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.medium)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ExifToolInformationView: View {
    @State private var version = "Checking…"

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "info.circle.fill")
                    .font(.title)
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 3) {
                    Text("ExifTool")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Metadata tool bundled with Photomuri")
                        .foregroundStyle(.secondary)
                }
            }

            Label {
                Text(
                    "Thank you to the developers and contributors of ExifTool and Perl for making them free software and permitting " +
                    "modification and redistribution under their licenses."
                )
            } icon: {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.pink)
            }
            .font(.callout)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                GridRow {
                    Text("Bundled Version")
                        .fontWeight(.medium)
                    Text(version)
                        .textSelection(.enabled)
                }
                GridRow {
                    Text("Developer")
                        .fontWeight(.medium)
                    Text("Phil Harvey")
                }
                GridRow {
                    Text("Copyright")
                        .fontWeight(.medium)
                    Text("Copyright 2003–2026, Phil Harvey")
                }
                GridRow {
                    Text("License")
                        .fontWeight(.medium)
                    Text("Same terms as Perl itself")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("License Details")
                    .font(.headline)

                Text(
                    "ExifTool is distributed under the same terms as Perl itself. Perl 5 retains the copyright of Larry Wall and " +
                    "its contributors and is free software that may be redistributed or modified under either of " +
                    "the following licenses:"
                )
                .fixedSize(horizontal: false, vertical: true)

                Text("• GNU General Public License, version 1 or later\n• Perl Artistic License")
                    .fixedSize(horizontal: false, vertical: true)

                Text(
                    "Copyright notices and the terms of the chosen license must still be followed. " +
                    "See the official license texts linked below for the exact rights and obligations."
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)

            HStack(spacing: 16) {
                Link(
                    "ExifTool Website",
                    destination: URL(string: "https://exiftool.org/")!
                )
                Link(
                    "Perl Licenses",
                    destination: URL(string: "https://dev.perl.org/licenses/")!
                )
            }

            Text(
                "ExifTool reads and updates photo, RAW and video metadata. " +
                "Photomuri bundles a tested version that works without an internet connection."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

        }
        .padding(24)
        }
        .frame(width: 620, height: 560)
        .onAppear {
            version = bundledExifToolVersion() ?? "Unavailable"
        }
    }

    private func bundledExifToolVersion() -> String? {
        guard let executableURL = Bundle.main.url(
            forResource: "exiftool",
            withExtension: nil,
            subdirectory: "ExifTool"
        ) else {
            return nil
        }
        let libraryURL = executableURL.deletingLastPathComponent()
            .appendingPathComponent("lib", isDirectory: true)
        guard FileManager.default.fileExists(atPath: libraryURL.path) else {
            return nil
        }

        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [executableURL.path, "-ver"]
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["PERL5LIB": libraryURL.path]
        ) { _, bundledValue in bundledValue }
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        } catch {
            return nil
        }
    }
}

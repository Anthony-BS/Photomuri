# Photomuri

[Support BYAstra on Buy Me a Coffee](https://buymeacoffee.com/byastra) · [BYAstra website](https://byastra.netlify.app)

Photomuri is a free, native macOS app by **BYAstra** for organizing photos and videos. Rename media by capture time, review time zones, sort files by format, and create smaller HEIC or AVIF versions of your JPGs—all on your Mac.

The app is free to use. If it makes your day easier, voluntary donations help support its development. There is no payment required to use Photomuri.

![Photomuri main window with the Default preset and a sample temporary folder](docs/images/photomuri-screenshot.jpg)

*Actual app window with the Default preset. The Location shown is an example temporary folder, not a personal path.*

## Requirements

- Apple Silicon Mac, M1 or later. Intel Macs are not supported.
- macOS 15.0 or later.
- Xcode 27 for the current source project. Older Xcode versions have not been verified.

Current app version: **1.0, build 5**.

## Features

- **Rename Files:** customizable capture-time templates, original names, literal text and per-shot sequences. JPG/RAW pairs share the same shot sequence.
- **Format folders:** organize media into subfolders by file format.
- **Time zones:** review recorded offsets, choose another region, and control daylight saving time. City and country search uses a bundled catalog; time-zone rules come from macOS.
- **Metadata updates:** optionally update supported photo, RAW and video metadata to match a selected time zone. Formats without direct writing support use sidecars where supported.
- **Convert JPGs:** create separate HEIC or AVIF files from JPG/JPEG shots. RAW-only shots and videos are skipped. Conversion does not replace the JPGs.
- **Preserve Originals:** leave source media in place and process copies instead.
- **Performance:** independently set Rename/Metadata and Convert workers using text fields or up/down arrows. Each defaults to 4 and is limited to 1 through the active CPU count.
- **Presets:** save reusable settings while keeping your last-used configuration between launches.
- **Conveniences:** folder drag and drop, file-count progress, a completion summary, result-folder opening and detailed log export.
- **Finder service:** the bundled “Organize with Photomuri” service sets the selected folder as Location. You still click Start in the app.

Media processing works offline. Photomuri uses bundled ExifTool for metadata and Apple ImageIO for image conversion. It does not upload your media; website and donation links open external sites only when you choose them.

## Get the app

Visit the [BYAstra website](https://byastra.netlify.app) for download information. This repository contains source code, not a committed app ZIP or Xcode archive.

The current downloadable build is **ad-hoc signed, not Developer ID signed or notarized**. macOS may block an internet download. Only open a download you trust; do not disable Gatekeeper globally.

## Using Photomuri

1. Choose a folder with **Choose...**, or drop a folder onto the app.
2. Select your renaming, conversion and metadata options.
3. Enable **Preserve Originals** when you want the original media left unchanged.
4. Set worker counts if needed, then click **Start**.
5. If time-zone review is enabled, inspect the recorded times and confirm your choice before processing.
6. Review the completion summary, open the output folder or save the detailed log.

**Test with copies first.** With Preserve Originals off, processing can move/rename source files and update their metadata when time-zone metadata changes are enabled. Keep an independent backup of important media. Collision checks and cancellation cleanup reduce risk but are not a replacement for backups.

### Defaults

The Default preset enables renaming, JPG conversion, time-zone review and time-zone metadata updates. It uses HEIC, quality 85, the template below and 4/4 workers. Preserve Originals is off. Metadata updates apply when a different time zone is chosen. A new installation has no selected work folder; returning users keep their own settings and presets.

### Filename templates

Default:

```text
YYMMDD_hhmmss [original]
```

Example:

```text
YYMMDD_hhmmss [original]_[s5]_"abc"
→ 260910_102245 DSC_1234_00001_abc.JPG
```

`YY` and `YYYY` are 2- and 4-digit years. `MM`, `DD`, `hh`, `mm` and `ss` are month, day, 24-hour time, minute and second. `[original]` inserts the original filename without its extension. Quoted text is literal; the quotes are omitted from the result.

`[s1]` through `[s5]` produce 1–9, 01–99, 001–999, 0001–9999 and 00001–99999 respectively, wrapping back to 1. Sequences advance per shot, not per JPG/RAW file. Existing date-prefixed filenames may be left unchanged; other enabled processing can still apply.

### Conversion quality and performance

Quality is an encoder setting, not a percentage of original file size or a measured percentage of visual fidelity. HEIC and AVIF may produce different results at the same number. High quality can still reveal differences when viewed closely, and a smaller output is not guaranteed for every image.

Worker counts limit concurrent files; they do not reserve or pin CPU cores. Increasing them can use more memory and may not improve speed, especially during metadata writing. Compare Rename/Metadata and Convert separately using the same files and options. The detailed log records the worker counts used for each run.

## Build from source

Personal modification and local builds are permitted under [LICENSE](LICENSE).
Sharing or distributing your build requires separate written permission.

Open **Media Organizer.xcodeproj**, select the shared **Photomuri** scheme and run on your Mac. The folder retains its historical project filename; the app is Photomuri.

For an unsigned local development build:

```sh
xcodebuild -project "Media Organizer.xcodeproj" -scheme Photomuri \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/PhotomuriBuild CODE_SIGNING_ALLOWED=NO build
```

This is a development build, not a signed/notarized distribution package. Bundled ExifTool resources are already included; you do not need to install ExifTool separately. The app invokes macOS's `/usr/bin/perl` with the bundled library.

`Tests/` contains standalone Swift test programs, not an XCTest target. See [TESTING.md](TESTING.md) for commands and safety notes.

## Source layout

- `App/`: SwiftUI screens, Finder service and Stage 2 execution.
- `Core/`: analysis, filename parsing/validation, presets and time-zone policy/catalog.
- `Models/`: media, plan, progress and worker-limit models.
- `HEICConverter.swift`: bounded HEIC/AVIF conversion and AVIF orientation handling.
- `Resources/`: ExifTool, city search data and attribution.
- `Assets.xcassets/`: app icons and artwork.
- `Tests/`: manual regression and diagnostic programs.

## Credits and licensing

Photomuri's official application releases are free to install and use
for personal or business purposes. Donations through Buy Me a Coffee
are voluntary and do not purchase additional rights.

**Photomuri's own source code is available for inspection and personal
modification, but is not offered under an open-source license.**
You may make local copies and modify, build, and run Photomuri for your
own personal use, evaluation, and experimentation while retaining its
copyright and license notices.

Reuse of Photomuri code in another project or product, provision of a
source-derived application or service to others, and redistribution of
the source, modified versions, or applications require separate written
permission, whether free of charge or for payment.
Rights provided by applicable law and GitHub's terms for public
repositories, including viewing and forking, remain unaffected.
See [LICENSE](LICENSE) for the complete terms.

Thank you to Phil Harvey and the ExifTool and Perl contributors for
making their work available under free-software licenses, and to
GeoNames for its city data.

ExifTool **13.59** is bundled with its original copyright notices and
README. Its license is the same as Perl's: either the Perl Artistic
License or GPL. GeoNames-derived data remains licensed under CC BY 4.0.
These components retain their respective licenses; Photomuri's terms
do not restrict rights granted by those licenses.
See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

BYAstra and Photomuri names, logos, icons, and brand artwork may not be
used to imply official origin, sponsorship, or endorsement.
Accurate references identifying the project and ordinary display of
branding within official releases or permitted personal builds are
allowed. Standalone reuse of brand artwork requires written permission.

For additional permissions, use the contact information on the
[BYAstra website](https://byastra.netlify.app).

Copyright © 2026 Bosung Kim (BYAstra).

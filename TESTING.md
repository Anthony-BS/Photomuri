# Photomuri tests

Run these tests on an Apple Silicon Mac with Xcode selected as the developer toolchain. First build the app using the command in README.md. The app bundle supplies the ExifTool resources to the test programs.

Use a disposable directory for compiled test executables. The examples below assume `/tmp/PhotomuriTests`:

```sh
mkdir -p /tmp/PhotomuriTests
```

## Presets and input validation

```sh
swiftc -Onone Models/MediaModels.swift Core/PresetStore.swift \
  Tests/PresetStoreTests.swift -o /tmp/PhotomuriTests/presets
/tmp/PhotomuriTests/presets
```

Keep `-Onone` for this suite so its `assert` checks remain active. It uses a unique temporary UserDefaults suite, not your saved settings.

## Parallel file processing

```sh
swiftc -Onone Models/MediaModels.swift Core/CaptureTimeZonePolicy.swift \
  App/StageTwoExecutor.swift Tests/ParallelStageTwoTests.swift \
  -o /tmp/PhotomuriTests/stage2
/tmp/PhotomuriTests/stage2 /tmp/PhotomuriBuild/Build/Products/Debug/Photomuri.app
```

This suite checks configured workers, Preserve Originals on/off, progress, collision races, rollback, cancellation, pipe draining and process-resource cleanup. Its RAW/video sidecar fixtures are synthetic, not a proprietary RAW decoder compatibility corpus.

## HEIC and AVIF conversion

```sh
swiftc -Onone Models/MediaModels.swift Core/CaptureTimeZonePolicy.swift \
  Core/RenameTemplateParser.swift Core/StageOneAnalyzer.swift \
  App/StageTwoExecutor.swift HEICConverter.swift \
  Tests/ParallelConversionTests.swift -o /tmp/PhotomuriTests/conversion
/tmp/PhotomuriTests/conversion /tmp/PhotomuriBuild/Build/Products/Debug/Photomuri.app
```

Generated JPEG fixtures check bounded concurrency, portrait orientation, capture metadata, progress, cancellation and partial-output cleanup for both formats.

## Additional diagnostics

`PhotomuriRegressionTests.swift`, `TimeZonePipelineTests.swift` and `AnalysisCacheTests.swift` can be compiled with the same source list as the conversion suite, substituting the test file. They check Nikon/DST interpretation, time-zone write/read behavior and safe analysis-cache reuse.

`LargeBatchTests.swift` processes 4,000 generated small JPEGs. This is a resource and correctness test, not a full-size camera-file throughput benchmark.

`FusedWriteBenchmark.swift` and `FusedMovieWriteTests.swift` accept additional paths and can remove their test directories. Read them before running; give them only disposable directories and copies, never your original media directory or an existing valuable folder.

The standalone test programs are not included in the app's build target. Automated engine tests do not replace checking the native UI, Gatekeeper behavior or real samples from the camera formats you intend to support.

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var presetStore = PresetStore()
    @AppStorage("settings.preferredPresetID") private var preferredPresetID = SettingsPreset.defaultID
    @State private var showSavePreset = false
    @State private var showManagePresets = false
    @State private var selectedFolder: URL?
    @State private var securityScopedFolderURL: URL?
    @State private var hasSecurityScopedFolderAccess = false
    @State private var isFolderDropTargeted = false
    @State private var folderDropError: String?
    @State private var showTokenGuide = false
    @State private var showEfficientVersionGuide = false
    @State private var showPreserveOriginalsGuide = false
    @State private var showPerformanceGuide = false
    @AppStorage("settings.renameWorkers") private var renameWorkersText = "4"
    @AppStorage("settings.conversionWorkers") private var conversionWorkersText = "4"
    @State private var workRenameConcurrency = WorkerConcurrency.limit(4)
    @State private var workConversionConcurrency = WorkerConcurrency.limit(4)
    private enum WorkerField: Hashable { case rename, conversion }
    @FocusState private var focusedWorkerField: WorkerField?

    @AppStorage("settings.renameFiles")
    private var renameFiles = true
    @AppStorage("settings.renameTemplate")
    private var renameTemplate = "YYMMDD_hhmmss [original]"
    @AppStorage("settings.createEfficientVersion")
    private var createEfficientVersion = true
    @AppStorage("settings.efficientImageFormat")
    private var efficientImageFormatRawValue = EfficientImageFormat.heic.rawValue
    @AppStorage("settings.efficientImageQuality")
    private var heicQuality = "85"
    @AppStorage("settings.reviewTimeZone")
    private var reviewTimeZone = true
    @AppStorage("settings.preserveOriginals")
    private var preserveOriginals = false
    @AppStorage("settings.updateCaptureMetadata")
    private var updateCaptureMetadata = true

    @State private var stageOneResult: StageOneResult?
    @State private var stageTwoResult: StageTwoResult?
    @State private var stageThreeResult: StageThreeResult?
    @State private var workError: String?
    @State private var safetyCheckMessage: String?
    @State private var workWasCancelled = false
    @State private var isCancellationRequested = false
    @State private var cancellationToken: WorkCancellationToken?
    @State private var analysisProgress = FileWorkProgress()
    @State private var renameProgress = FileWorkProgress()
    @State private var heicProgress = FileWorkProgress()
    @State private var isAnalyzing = false
    @State private var analysisPhase = StageOneAnalysisPhase.checkingFiles
    @State private var isRenaming = false
    @State private var isConvertingHEIC = false
    @State private var showStartConfirmation = false
    @State private var showTimeZoneReview = false
    @State private var showWorkLog = false
    @State private var workStartedAt: Date?
    @State private var workFinishedAt: Date?
    @AppStorage("settings.selectedTimeZoneIdentifier")
    private var selectedTimeZoneIdentifier = TimeZone.current.identifier
    @AppStorage("settings.applyDaylightSavingTime")
    private var applyDaylightSavingTime = true

    private let folderBookmarkKey = "settings.workFolderBookmark"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text("Photomuri")
                        .font(.largeTitle)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)

                    Text("BYAstra")
                        .font(.caption)
                        .foregroundStyle(Color(white: 0.82))
                }

                Spacer()

            }
            .padding(.vertical, 16)
            .background {
                BYAstraHeaderBackground()
                    .padding(.horizontal, -24)
            }

            presetSection
            Divider()

            renameSection

            Divider()

            HStack(spacing: 18) {
                HStack(spacing: 8) {
                    Toggle("Convert JPGs", isOn: $createEfficientVersion)
                        .font(.headline)
                        .fixedSize()
                        .disabled(isWorking)
                    Button { showEfficientVersionGuide.toggle() } label: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("About JPG Conversion")
                    .help("About JPG Conversion")
                    .popover(isPresented: $showEfficientVersionGuide, arrowEdge: .leading) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Convert JPGs").font(.headline)
                            Text("Creates separate, storage-efficient HEIC or AVIF versions from JPG files only. These are usually smaller; conversion does not replace your JPGs.")
                            Text("At a Quality setting of 85% or higher, differences from the source JPG can be hard to notice in everyday viewing. Results vary by image and format; zooming in or further editing may reveal differences.")
                                .foregroundStyle(.secondary)
                        }
                        .padding(20)
                        .frame(width: 380, alignment: .leading)
                    }
                }
                .fixedSize()

                HStack(spacing: 6) {
                    Text("Format")
                    Picker("Format", selection: efficientImageFormatBinding) {
                        ForEach(EfficientImageFormat.allCases) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 85)
                }
                .disabled(!createEfficientVersion || isWorking)

                Divider()
                    .frame(height: 20)

                HStack(spacing: 6) {
                    Text("Quality")
                    TextField("85", text: $heicQuality)
                        .frame(width: 55)
                        .textFieldStyle(.roundedBorder)
                    Text("%")
                }
                .disabled(!createEfficientVersion || isWorking)
                Spacer(minLength: 0)
            }

            if createEfficientVersion && !qualityIsValid {
                Text("Enter a quality value from 1 to 100.")
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Review & Change Time Zone", isOn: $reviewTimeZone)

                Toggle(
                    "Update Metadata to Match Time Zone",
                    isOn: $updateCaptureMetadata
                )
                .help("Updates photo, RAW and video metadata to match the selected capture time zone.")
                .padding(.leading, 22)
                .disabled(!reviewTimeZone)

                HStack(spacing: 8) {
                    Toggle("Preserve Originals", isOn: $preserveOriginals).fixedSize()
                    Button { showPreserveOriginalsGuide.toggle() } label: {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("About Preserve Originals")
                    .popover(isPresented: $showPreserveOriginalsGuide, arrowEdge: .leading) {
                        Text("Originals remain unchanged. Only copies are processed.")
                            .padding(20).frame(width: 330, alignment: .leading)
                    }
                    Spacer()
                }

            }
            .disabled(isWorking)

            Divider()

            performanceSection

            Divider()

            folderAndStartSection
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 720)
        .overlay {
            if isFolderDropTargeted && canAcceptFolderDrop {
                folderDropFeedback
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isFolderDropTargeted)
        .onDrop(of: [UTType.fileURL], isTargeted: $isFolderDropTargeted) { providers in
            acceptDroppedFolder(providers)
        }
        .alert("Unable to Add Folder", isPresented: Binding(
            get: { folderDropError != nil },
            set: { if !$0 { folderDropError = nil } }
        )) {
            Button("OK", role: .cancel) { folderDropError = nil }
        } message: {
            Text(folderDropError ?? "")
        }
        .onAppear {
            finishWorkerEdit(.rename)
            finishWorkerEdit(.conversion)
            restoreSelectedFolderIfNeeded()
        }
        .onChange(of: focusedWorkerField) { previous, _ in
            if let previous { finishWorkerEdit(previous) }
        }
        .onOpenURL { url in
            NSApp.activate(ignoringOtherApps: true)
            guard canAcceptFolderDrop else {
                folderDropError = "Finish the current task or close its results before adding another folder."
                return
            }
            selectIncomingFolder(url)
        }
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        .onDisappear {
            releaseSecurityScopedFolderAccess()
        }
        .alert("Original files will be modified. Continue?", isPresented: $showStartConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Start") {
                runWorkflow()
            }
        }
        .sheet(isPresented: $showTimeZoneReview) {
            if let analysis = stageOneResult {
                TimeZoneReviewView(
                    summaries: analysis.timeZoneSummaries,
                    referenceDate: analysis.mediaItems.map { $0.captureInstant ?? $0.captureDate }.min() ?? Date(),
                    selectedTimeZoneIdentifier: $selectedTimeZoneIdentifier,
                    applyDaylightSavingTime: $applyDaylightSavingTime,
                    onCancel: {
                        showTimeZoneReview = false
                        finishWorkflow()
                    },
                    onUseRecordedTimeZone: {
                        showTimeZoneReview = false
                        replanAndRun(timeZoneIdentifier: nil)
                    },
                    onUseSelectedTimeZone: {
                        showTimeZoneReview = false
                        replanAndRun(
                            timeZoneIdentifier: selectedTimeZoneIdentifier
                        )
                    }
                )
            }
        }
        .sheet(isPresented: $showWorkLog) {
            WorkLogView(
                analysis: stageOneResult,
                stageTwo: stageTwoResult,
                stageThree: stageThreeResult,
                efficientFormat: efficientImageFormat,
                efficientVersionEnabled: createEfficientVersion,
                errorMessage: workError,
                safetyCheckMessage: safetyCheckMessage,
                wasCancelled: workWasCancelled,
                workFolder: selectedFolder,
                startedAt: workStartedAt,
                finishedAt: workFinishedAt,
                renameTemplate: renameTemplate,
                renameEnabled: renameFiles,
                preserveOriginals: preserveOriginals,
                metadataEnabled: reviewTimeZone && updateCaptureMetadata,
                quality: heicQuality,
                renameTasks: workRenameConcurrency,
                conversionTasks: workConversionConcurrency
            ) {
                showWorkLog = false
            }
        }
        .sheet(isPresented: $showSavePreset) {
            SavePresetView(store: presetStore, currentPreset: presetSaveTarget, settings: currentSettings,
                           onSaved: { id in
                               preferredPresetID = id
                               showSavePreset = false
                           }, onCancel: { showSavePreset = false })
        }
        .sheet(isPresented: $showManagePresets) {
            ManagePresetsView(store: presetStore, selectedID: matchingPresetID) {
                showManagePresets = false
            }
        }
    }

    // Presets deliberately exclude the work folder and never replace last-used
    // settings on launch. The menu is derived from the current settings.
    private var currentSettings: PresetSettings {
        PresetSettings(renameFiles: renameFiles, renameTemplate: renameTemplate,
                       createEfficientVersion: createEfficientVersion,
                       efficientImageFormat: efficientImageFormatRawValue, quality: heicQuality,
                       reviewTimeZone: reviewTimeZone, updateCaptureMetadata: updateCaptureMetadata,
                       preserveOriginals: preserveOriginals,
                       timeZoneIdentifier: selectedTimeZoneIdentifier,
                       applyDaylightSavingTime: applyDaylightSavingTime,
                       renameWorkers: WorkerConcurrency.validatedCount(renameWorkersText),
                       conversionWorkers: WorkerConcurrency.validatedCount(conversionWorkersText))
    }

    private var matchingPresetID: String {
        guard workersAreValid else { return "" }
        return presetStore.matchingID(for: currentSettings, preferredID: preferredPresetID)
    }

    private var currentPreset: SettingsPreset? {
        presetStore.all.first { $0.id == matchingPresetID }
    }

    private var presetSaveTarget: SettingsPreset? {
        // Keep overwrite available after editing an applied custom preset even
        // when the settings no longer match it and the menu correctly goes blank.
        currentPreset ?? presetStore.saved.first { $0.id == preferredPresetID }
    }

    private var presetSection: some View {
        HStack(spacing: 10) {
            Text("Preset").font(.headline)
            Menu {
                ForEach(presetStore.all) { preset in
                    Button {
                        applyPreset(preset)
                    } label: {
                        if preset.id == matchingPresetID {
                            Label(preset.name, systemImage: "checkmark")
                        } else {
                            Text(preset.name)
                        }
                    }
                }
            } label: {
                Text(currentPreset?.name ?? " ")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 340, alignment: .leading)
            }
            .menuStyle(.borderedButton)
            .accessibilityLabel("Preset")
            .accessibilityValue(currentPreset?.name ?? "")
            .help(currentPreset?.name ?? "The current settings do not match a saved preset.")
            Spacer(minLength: 0)
            Button("Save…") { showSavePreset = true }
                .disabled(!workersAreValid)
            Button("Manage…") { showManagePresets = true }
        }
        .disabled(isWorking)
        .padding(.vertical, 2)
    }

    private func applyPreset(_ preset: SettingsPreset) {
        let settings = preset.settings
        preferredPresetID = preset.id
        renameFiles = settings.renameFiles
        renameTemplate = settings.renameTemplate
        createEfficientVersion = settings.createEfficientVersion
        efficientImageFormatRawValue = settings.efficientImageFormat
        heicQuality = settings.quality
        reviewTimeZone = settings.reviewTimeZone
        updateCaptureMetadata = settings.updateCaptureMetadata
        preserveOriginals = settings.preserveOriginals
        selectedTimeZoneIdentifier = settings.timeZoneIdentifier
        applyDaylightSavingTime = settings.usesDaylightSavingTime
        renameWorkersText = String(WorkerConcurrency.limit(settings.requestedRenameWorkers))
        conversionWorkersText = String(WorkerConcurrency.limit(settings.requestedConversionWorkers))
    }

    // MARK: - Folder Drop Feedback

    private var folderDropFeedback: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.035))
                .padding(6)
            VStack(spacing: 12) {
                Image(systemName: "folder.badge.plus")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 56, height: 56)
                    .background(Color.accentColor.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 13))

                VStack(spacing: 6) {
                    Text("Add Folder")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("Drop here to set the working folder.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.vertical, 24)
            .padding(.horizontal, 28)
            .frame(width: 340)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.12), radius: 16, x: 0, y: 6)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Bottom Work Area

    private var activeCPUCount: Int { max(ProcessInfo.processInfo.activeProcessorCount, 1) }

    private var workersAreValid: Bool {
        WorkerConcurrency.validatedCount(renameWorkersText) != nil &&
        WorkerConcurrency.validatedCount(conversionWorkersText) != nil
    }

    private func workerBinding(_ field: WorkerField) -> Binding<String> {
        Binding(get: {
            field == .rename ? renameWorkersText : conversionWorkersText
        }, set: { value in
            let normalized = WorkerConcurrency.normalizedInput(value)
            if field == .rename { renameWorkersText = normalized }
            else { conversionWorkersText = normalized }
        })
    }

    private func finishWorkerEdit(_ field: WorkerField) {
        let text = field == .rename ? renameWorkersText : conversionWorkersText
        let normalized = WorkerConcurrency.normalizedInput(text)
        let value = WorkerConcurrency.validatedCount(normalized) ?? WorkerConcurrency.limit(4)
        if field == .rename { renameWorkersText = String(value) }
        else { conversionWorkersText = String(value) }
    }

    private func workerStepperBinding(_ field: WorkerField) -> Binding<Int> {
        Binding(get: {
            let text = field == .rename ? renameWorkersText : conversionWorkersText
            let normalized = WorkerConcurrency.normalizedInput(text)
            return WorkerConcurrency.validatedCount(normalized) ?? WorkerConcurrency.limit(4)
        }, set: { value in
            workerBinding(field).wrappedValue = String(WorkerConcurrency.limit(value))
        })
    }

    private var performanceSection: some View {
        HStack(spacing: 10) {
            Text("Performance").font(.headline).fixedSize()
            Button { showPerformanceGuide.toggle() } label: {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("About Worker Counts")
            .help("About Worker Counts")
            .popover(isPresented: $showPerformanceGuide, arrowEdge: .leading) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Worker Counts").font(.headline)
                    Text("Rename/Metadata controls concurrent renaming, sorting, copying and metadata updates. Convert controls concurrent HEIC/AVIF conversions. File analysis is unchanged.")
                    Text("Default: 4 workers for each stage. Enter a whole number from 1 to \(activeCPUCount), the active CPU count on this Mac. Out-of-range numbers are adjusted automatically.")
                    Text("These are concurrent file tasks, not dedicated CPU cores. macOS schedules the work, and an encoder may use additional threads.")
                    Text("Higher counts use more memory and may slow other apps. More workers are not always faster; compare the stages separately. Settings are saved and included in presets.")
                        .foregroundStyle(.secondary)
                }
                .padding(20).frame(width: 390, alignment: .leading)
            }
            HStack(spacing: 6) {
                Text("Rename/Metadata").fixedSize()
                TextField("4", text: workerBinding(.rename))
                    .textFieldStyle(.roundedBorder).frame(width: 44)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedWorkerField, equals: .rename)
                    .onSubmit { finishWorkerEdit(.rename) }
                    .accessibilityLabel("Rename/Metadata workers")
                    .help("Concurrent file processing tasks: 1–\(activeCPUCount). Default: 4.")
                Stepper("Rename/Metadata workers", value: workerStepperBinding(.rename), in: 1...activeCPUCount)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .help("Adjust Rename/Metadata workers: 1–\(activeCPUCount).")
            }
            .disabled(isWorking)
            HStack(spacing: 6) {
                Text("Convert").fixedSize()
                TextField("4", text: workerBinding(.conversion))
                    .textFieldStyle(.roundedBorder).frame(width: 44)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedWorkerField, equals: .conversion)
                    .onSubmit { finishWorkerEdit(.conversion) }
                    .accessibilityLabel("Convert workers")
                    .help("Concurrent HEIC/AVIF tasks: 1–\(activeCPUCount). Default: 4.")
                Stepper("Convert workers", value: workerStepperBinding(.conversion), in: 1...activeCPUCount)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .help("Adjust Convert workers: 1–\(activeCPUCount).")
            }
            .disabled(isWorking)
            Text("1–\(activeCPUCount)")
                .font(.caption).foregroundStyle(workersAreValid ? Color.secondary : .red)
                .help(workersAreValid ? "Allowed workers per stage." : "Enter a whole number from 1 to \(activeCPUCount).")
            Spacer(minLength: 0)
        }
    }

    private var folderAndStartSection: some View {
        HStack(spacing: 10) {
            Text("Location")
                .font(.headline)
                .fixedSize()
            Text(isWorking ? workProgressTitle : selectedFolder?.path ?? "No folder selected.")
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 10)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .frame(height: 30)
                .background {
                    ZStack(alignment: .leading) {
                        Color.secondary.opacity(0.08)
                        GeometryReader { geometry in
                            Rectangle()
                                .fill(Color.blue.opacity(0.22))
                                .frame(width: geometry.size.width * min(max(workProgressValue, 0), 1))
                                .opacity(isWorking ? 1 : 0)
                        }
                    }
                    .allowsHitTesting(false)
                }
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .help(isWorking ? workProgressTitle : selectedFolder?.path ?? "No folder selected.")
                .accessibilityLabel(isWorking ? "Task progress" : "Location path")
                .accessibilityValue(isWorking ? workProgressTitle : selectedFolder?.path ?? "Idle")

            Button("Choose...") {
                selectFolder()
            }
            .fixedSize()
            .disabled(isWorking)

            Button(headerActionTitle) {
                if isWorking {
                    requestCancellation()
                } else if preserveOriginals {
                    runWorkflow()
                } else {
                    showStartConfirmation = true
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(isWorking ? .red : .accentColor)
            .fixedSize()
            .disabled(headerActionIsDisabled)
        }
    }

    private var workProgressTitle: String {
        if isAnalyzing {
            switch analysisPhase {
            case .checkingFiles: return "1/3 Checking Files…"
            case .readingMetadata: return "1/3 Analyzing Files \(analysisProgress.countText)"
            case .planning: return "1/3 Updating File Plan \(analysisProgress.countText)"
            }
        }
        if isRenaming {
            return "2/3 Renaming & Sorting Files \(renameProgress.countText)"
        }
        return "3/3 Converting to \(efficientImageFormat.displayName) \(heicProgress.countText)"
    }

    private var workProgressValue: Double {
        if isAnalyzing { return analysisProgress.fraction }
        if isRenaming { return renameProgress.fraction }
        if isConvertingHEIC { return heicProgress.fraction }
        return 0
    }

    private var efficientImageFormat: EfficientImageFormat {
        EfficientImageFormat(rawValue: efficientImageFormatRawValue) ?? .heic
    }

    private var efficientImageFormatBinding: Binding<EfficientImageFormat> {
        Binding(
            get: { efficientImageFormat },
            set: { efficientImageFormatRawValue = $0.rawValue }
        )
    }

    private var headerActionTitle: String {
        if !isWorking { return "Start" }
        return isCancellationRequested ? "Cancelling…" : "Cancel Task"
    }

    private var headerActionIsDisabled: Bool {
        if isWorking { return isCancellationRequested }
        return selectedFolder == nil ||
        (renameFiles && !templateValidation.isValid) ||
        !qualityIsValid || !workersAreValid
    }

    private var isWorking: Bool {
        isAnalyzing || isRenaming || isConvertingHEIC
    }

    private var renameSection: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow {
                HStack(spacing: 8) {
                    Toggle("Rename Files", isOn: $renameFiles)
                        .font(.headline)
                        .fixedSize()
                        .disabled(isWorking)
                    Button { showTokenGuide.toggle() } label: {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Filename Tokens")
                    .help("Filename Tokens")
                    .popover(isPresented: $showTokenGuide, arrowEdge: .leading) {
                        tokenGuide.padding(20).frame(width: 620)
                    }
                }
                .fixedSize()
                TextField("Filename Template", text: $renameTemplate)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .disabled(!renameFiles || isWorking)
            }

            GridRow {
                Text("Preview")
                    .font(.body)
                    .padding(.leading, 22)
                Text(previewFilename)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .gridCellUnsizedAxes(.horizontal)
            }
            .foregroundStyle(renameFiles && !isWorking ? Color.primary : Color.secondary)
            .disabled(!renameFiles || isWorking)
            if let error = templateValidation.errorMessage {
                GridRow {
                    Text(error).foregroundStyle(.red).font(.caption)
                        .gridCellColumns(2)
                        .opacity(renameFiles ? 1 : 0)
                        .accessibilityHidden(!renameFiles)
                }
            }
            if let warning = templateValidation.warningMessage {
                GridRow {
                    Text(warning).foregroundStyle(.orange).font(.caption)
                        .gridCellColumns(2)
                        .opacity(renameFiles ? 1 : 0)
                        .accessibilityHidden(!renameFiles)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tokenGuide: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Filename Tokens")
                .font(.headline)

            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 4) {
                    tokenRow("YY", "2-digit year (2026 → 26)")
                    tokenRow("YYYY", "4-digit year (2026 → 2026)")
                    tokenRow("MM", "2-digit month (March → 03)")
                    tokenRow("DD", "2-digit day (3 → 03)")
                    tokenRow("hh", "24-hour time (11 PM → 23)")
                    tokenRow("mm", "2-digit minute")
                    tokenRow("ss", "2-digit second")
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 4) {
                    tokenRow("[original]", "Original filename (no extension)")
                    tokenRow("[s1]", "Sequence 1–9, repeating")
                    tokenRow("[s2]", "Sequence 01–99, repeating")
                    tokenRow("[s3]", "Sequence 001–999, repeating")
                    tokenRow("[s4]", "Sequence 0001–9999, repeating")
                    tokenRow("[s5]", "Sequence 00001–99999, repeating")
                    tokenRow("\"\"", "Literal text (e.g. \"abc\" → abc)")
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            Text("Spaces and underscores are kept exactly where you enter them.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Text inside double quotes is treated as literal text, not tokens. The quotes themselves are omitted from the filename.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Token Description

    private func tokenRow(
        _ token: String,
        _ description: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(token)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 72, alignment: .leading)

            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
    }

    // MARK: - Preview

    private var previewFilename: String {
        let components = DateComponents(
            calendar: Calendar.current,
            year: 2026,
            month: 9,
            day: 10,
            hour: 10,
            minute: 12,
            second: 56
        )

        guard let date = components.date else {
            return ""
        }

        return RenameTemplateParser.render(
            template: renameTemplate,
            date: date,
            originalStem: "DSC_1234",
            sequenceIndex: 1,
            fileExtension: "JPG"
        )
    }

    // MARK: - Validation

    private var templateValidation: RenameTemplateValidationResult {
        RenameTemplateValidator.validate(renameTemplate)
    }

    private var qualityIsValid: Bool {
        if !createEfficientVersion {
            return true
        }

        guard let value = Int(heicQuality) else {
            return false
        }

        return (1...100).contains(value)
    }

    // MARK: - Workflow

    private func runWorkflow() {
        guard let selectedFolder,
              let renameCount = WorkerConcurrency.validatedCount(renameWorkersText),
              let convertCount = WorkerConcurrency.validatedCount(conversionWorkersText) else {
            return
        }

        workStartedAt = Date()
        let activeCPUs = ProcessInfo.processInfo.activeProcessorCount
        workRenameConcurrency = WorkerConcurrency.limit(renameCount, activeProcessorCount: activeCPUs)
        workConversionConcurrency = WorkerConcurrency.limit(convertCount, activeProcessorCount: activeCPUs)
        workFinishedAt = nil
        stageOneResult = nil
        stageTwoResult = nil
        stageThreeResult = nil
        workError = nil
        safetyCheckMessage = nil
        workWasCancelled = false
        isCancellationRequested = false
        showWorkLog = false
        analysisProgress = FileWorkProgress()
        analysisPhase = .checkingFiles
        renameProgress = FileWorkProgress()
        heicProgress = FileWorkProgress()
        isAnalyzing = true

        let token = WorkCancellationToken()
        cancellationToken = token

        let template = renameTemplate
        let renameEnabled = renameFiles
        let keepOriginals = preserveOriginals
        let shouldReviewTimeZone = reviewTimeZone

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try token.check()
                let analysis = try StageOneAnalyzer().analyze(
                    folderURL: selectedFolder,
                    renameTemplate: template,
                    renameEnabled: renameEnabled,
                    preserveOriginals: keepOriginals,
                    cancellationToken: token,
                    observer: StageOneAnalysisObserver { phase in
                        DispatchQueue.main.async { analysisPhase = phase }
                    }
                ) { completed, total in
                    DispatchQueue.main.async {
                        analysisProgress = FileWorkProgress(completed: completed, total: total)
                    }
                }

                DispatchQueue.main.async {
                    stageOneResult = analysis
                    isAnalyzing = false

                    guard analysis.canContinue else {
                        finishWorkflow()
                        showWorkLog = true
                        return
                    }

                    if shouldReviewTimeZone {
                        selectedTimeZoneIdentifier = suggestedTimeZoneIdentifier(
                            from: analysis.timeZoneSummaries
                        )
                        showTimeZoneReview = true
                    } else {
                        runStageTwo(with: analysis)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    finishWithError(error)
                }
            }
        }
    }

    private func replanAndRun(
        timeZoneIdentifier: String?
    ) {
        let timeZone = timeZoneIdentifier.flatMap(TimeZone.init(identifier:))
        guard let selectedFolder, timeZoneIdentifier == nil || timeZone != nil else {
            workError = "The selected time zone is unavailable."
            finishWorkflow()
            showWorkLog = true
            return
        }

        workError = nil
        analysisProgress = FileWorkProgress()
        analysisPhase = .checkingFiles
        renameProgress = FileWorkProgress()
        heicProgress = FileWorkProgress()
        isAnalyzing = true

        let token = cancellationToken ?? WorkCancellationToken()
        cancellationToken = token

        let template = renameTemplate
        let renameEnabled = renameFiles
        let keepOriginals = preserveOriginals
        let useDST = applyDaylightSavingTime
        let snapshot = stageOneResult?.metadataSnapshot

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let analysis = try StageOneAnalyzer(applyDaylightSavingTime: useDST).analyze(
                    folderURL: selectedFolder,
                    renameTemplate: template,
                    timeZoneOverride: timeZone,
                    renameEnabled: renameEnabled,
                    preserveOriginals: keepOriginals,
                    metadataSnapshot: snapshot,
                    cancellationToken: token,
                    observer: StageOneAnalysisObserver { phase in
                        DispatchQueue.main.async { analysisPhase = phase }
                    }
                ) { completed, total in
                    DispatchQueue.main.async {
                        analysisProgress = FileWorkProgress(completed: completed, total: total)
                    }
                }

                DispatchQueue.main.async {
                    stageOneResult = analysis
                    isAnalyzing = false

                    guard analysis.canContinue else {
                        finishWorkflow()
                        showWorkLog = true
                        return
                    }
                    runStageTwo(with: analysis)
                }
            } catch {
                DispatchQueue.main.async {
                    finishWithError(error)
                }
            }
        }
    }

    private func suggestedTimeZoneIdentifier(
        from summaries: [CaptureTimeZoneSummary]
    ) -> String {
        let knownOffsets = Set(summaries.compactMap(\.offsetSeconds))
        guard knownOffsets.count == 1,
              let offset = knownOffsets.first else {
            return TimeZone.current.identifier
        }

        switch offset {
        case 0:
            return "Europe/Lisbon"
        case 28_800:
            return "Asia/Shanghai"
        case 32_400:
            return "Asia/Seoul"
        default:
            return TimeZone.current.identifier
        }
    }

    private func runStageTwo(with analysis: StageOneResult) {
        renameProgress = FileWorkProgress(total: analysis.renamePlan.count)
        isRenaming = true
        let keepOriginals = preserveOriginals
        let shouldUpdateMetadata = reviewTimeZone && updateCaptureMetadata
        let shouldCreateEfficientVersion = createEfficientVersion
        let token = cancellationToken ?? WorkCancellationToken()
        cancellationToken = token
        let workFolder = selectedFolder
        let workers = workRenameConcurrency

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard let workFolder else {
                    throw WorkSafetyPreflightError.cannotWrite(
                        "The working folder could not be found."
                    )
                }
                let safetyResult = try WorkSafetyPreflight().validate(
                    workFolderURL: workFolder,
                    stageOneResult: analysis,
                    preserveOriginals: keepOriginals,
                    updateCaptureMetadata: shouldUpdateMetadata,
                    createEfficientVersion: shouldCreateEfficientVersion,
                    cancellationToken: token
                )
                DispatchQueue.main.async {
                    safetyCheckMessage = safetyCheckSummary(safetyResult)
                }

                let renameResult = try StageTwoExecutor(workerCount: workers).execute(
                    stageOneResult: analysis,
                    preserveOriginals: keepOriginals,
                    updateCaptureMetadata: shouldUpdateMetadata,
                    cancellationToken: token
                ) { completed, total in
                    DispatchQueue.main.async {
                        renameProgress = FileWorkProgress(completed: completed, total: total)
                    }
                }

                DispatchQueue.main.async {
                    stageTwoResult = renameResult
                    isRenaming = false

                    if token.isCancelled {
                        finishWithError(
                            WorkCancellationError.afterFileProcessing
                        )
                        return
                    }

                    if shouldCreateEfficientVersion {
                        runStageThree(with: analysis)
                    } else {
                        finishWorkflow()
                        showWorkLog = true
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    finishWithError(error)
                }
            }
        }
    }

    private func stageTwoSummary(_ result: StageTwoResult) -> String {
        var parts = ["Sorted: \(result.classifiedCount)"]
        parts.append("Renamed: \(result.renamedCount)")
        if result.copiedCount > 0 {
            parts.append("Originals preserved: \(result.copiedCount)")
        }
        if result.metadataUpdatedCount > 0 {
            parts.append("Metadata updated: \(result.metadataUpdatedCount)")
        }
        if result.skippedCount > 0 {
            parts.append("Renaming skipped: \(result.skippedCount)")
        }
        return "2/3 Completed: " + parts.joined(separator: " · ")
    }

    private func runStageThree(with analysis: StageOneResult) {
        guard let quality = Int(heicQuality) else {
            return
        }

        heicProgress = FileWorkProgress(total: analysis.shots.filter { shot in
            shot.items.contains { $0.kind == .jpeg }
        }.count)
        isConvertingHEIC = true
        let format = efficientImageFormat
        let workers = workConversionConcurrency
        let token = cancellationToken ?? WorkCancellationToken()
        cancellationToken = token

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let conversionResult = try HEICConverter(workerCount: workers).convert(
                    stageOneResult: analysis,
                    format: format,
                    quality: quality,
                    cancellationToken: token
                ) { completed, total in
                    DispatchQueue.main.async {
                        heicProgress = FileWorkProgress(completed: completed, total: total)
                    }
                }

                DispatchQueue.main.async {
                    stageThreeResult = conversionResult
                    isConvertingHEIC = false
                    finishWorkflow()
                    showWorkLog = true
                }
            } catch {
                DispatchQueue.main.async {
                    finishWithError(error)
                }
            }
        }
    }

    private func requestCancellation() {
        guard isWorking, !isCancellationRequested else { return }
        isCancellationRequested = true
        cancellationToken?.cancel()
    }

    private func finishWorkflow() {
        workFinishedAt = Date()
        isAnalyzing = false
        isRenaming = false
        isConvertingHEIC = false
        isCancellationRequested = false
        cancellationToken = nil
        stageOneResult?.metadataSnapshot = nil
    }

    private func finishWithError(_ error: Error) {
        workWasCancelled = isCancellationError(error)
        workError = error.localizedDescription
        finishWorkflow()
        showWorkLog = true
    }

    private func isCancellationError(_ error: Error) -> Bool {
        if error is WorkCancellationError { return true }
        if let stageTwoError = error as? StageTwoExecutorError,
           case .cancelled = stageTwoError {
            return true
        }
        if let conversionError = error as? HEICConverterError,
           case .cancelled = conversionError {
            return true
        }
        return false
    }

    private func safetyCheckSummary(
        _ result: WorkSafetyPreflightResult
    ) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "Write access verified · Required space: approximately " +
        formatter.string(fromByteCount: result.requiredBytes) +
        " · Available: " +
        formatter.string(fromByteCount: result.availableBytes)
    }

    // MARK: - Folder Picker

    private var canAcceptFolderDrop: Bool {
        !isWorking && !showStartConfirmation && !showTimeZoneReview && !showWorkLog
        && !showSavePreset && !showManagePresets
    }

    private func acceptDroppedFolder(_ providers: [NSItemProvider]) -> Bool {
        guard canAcceptFolderDrop else { return false }
        guard providers.count == 1, let provider = providers.first else {
            folderDropError = "Drag one working folder at a time."
            return false
        }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            let url: URL?
            if let value = item as? URL {
                url = value
            } else if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else if let text = item as? String {
                url = URL(string: text)
            } else {
                url = nil
            }
            DispatchQueue.main.async {
                isFolderDropTargeted = false
                guard canAcceptFolderDrop else { return }
                guard error == nil, let url, url.isFileURL else {
                    folderDropError = "Unable to read the folder path. Select it again using Choose…"
                    return
                }
                selectIncomingFolder(url)
            }
        }
        return true
    }

    private func selectIncomingFolder(_ url: URL) {
        guard url.isFileURL else {
            folderDropError = "Choose a local working folder."
            return
        }
        let scopedAccess = url.startAccessingSecurityScopedResource()
        defer { if scopedAccess { url.stopAccessingSecurityScopedResource() } }
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
              values.isDirectory == true, values.isPackage != true else {
            folderDropError = "Choose a folder containing photos or videos. Files and apps cannot be added as the working folder."
            return
        }
        setWorkFolder(url)
    }

    private func setWorkFolder(_ folderURL: URL) {
        rememberSelectedFolder(folderURL)
        stageOneResult = nil
        stageTwoResult = nil
        stageThreeResult = nil
        workError = nil
        safetyCheckMessage = nil
        workWasCancelled = false
        workStartedAt = nil
        workFinishedAt = nil
        isCancellationRequested = false
        cancellationToken = nil
        showTimeZoneReview = false
        showWorkLog = false
    }

    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Folder to Organize"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let folderURL = panel.url {
            setWorkFolder(folderURL)
        }
    }

    private func rememberSelectedFolder(_ folderURL: URL) {
        releaseSecurityScopedFolderAccess()

        selectedFolder = folderURL
        securityScopedFolderURL = folderURL
        hasSecurityScopedFolderAccess =
        folderURL.startAccessingSecurityScopedResource()

        do {
            let bookmark = try folderURL.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: folderBookmarkKey)
        } catch {
            UserDefaults.standard.removeObject(forKey: folderBookmarkKey)
        }
    }

    private func restoreSelectedFolderIfNeeded() {
        if let selectedFolder {
            securityScopedFolderURL = selectedFolder
            hasSecurityScopedFolderAccess =
            selectedFolder.startAccessingSecurityScopedResource()
            return
        }

        guard let bookmark = UserDefaults.standard.data(
            forKey: folderBookmarkKey
        ) else {
            return
        }

        do {
            var isStale = false
            let folderURL = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: folderURL.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue else {
                UserDefaults.standard.removeObject(forKey: folderBookmarkKey)
                return
            }

            selectedFolder = folderURL
            securityScopedFolderURL = folderURL
            hasSecurityScopedFolderAccess =
            folderURL.startAccessingSecurityScopedResource()

            if isStale {
                let refreshedBookmark = try folderURL.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                UserDefaults.standard.set(
                    refreshedBookmark,
                    forKey: folderBookmarkKey
                )
            }
        } catch {
            UserDefaults.standard.removeObject(forKey: folderBookmarkKey)
            selectedFolder = nil
            securityScopedFolderURL = nil
            hasSecurityScopedFolderAccess = false
        }
    }

    private func releaseSecurityScopedFolderAccess() {
        if hasSecurityScopedFolderAccess {
            securityScopedFolderURL?.stopAccessingSecurityScopedResource()
        }
        hasSecurityScopedFolderAccess = false
        securityScopedFolderURL = nil
    }
}

private struct WorkLogView: View {
    let analysis: StageOneResult?
    let stageTwo: StageTwoResult?
    let stageThree: StageThreeResult?
    let efficientFormat: EfficientImageFormat
    let efficientVersionEnabled: Bool
    let errorMessage: String?
    let safetyCheckMessage: String?
    let wasCancelled: Bool
    let workFolder: URL?
    let startedAt: Date?
    let finishedAt: Date?
    let renameTemplate: String
    let renameEnabled: Bool
    let preserveOriginals: Bool
    let metadataEnabled: Bool
    let quality: String
    let renameTasks: Int
    let conversionTasks: Int
    let onClose: () -> Void
    @State private var logActionMessage: String?

    private var completedSuccessfully: Bool {
        errorMessage == nil &&
        analysis?.collisions.isEmpty == true &&
        stageTwo != nil &&
        (!efficientVersionEnabled || stageThree != nil)
    }

    private var completedWithWarnings: Bool {
        completedSuccessfully && !(analysis?.metadataWarnings.isEmpty ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: statusIconName)
                    .foregroundStyle(statusColor)
                    .font(.title2)

                Text(statusTitle)
                    .font(.title2)
                    .fontWeight(.semibold)
            }

            VStack(alignment: .leading, spacing: 10) {
                if let analysis {
                    logRow(
                        title: "1/3 File Analysis",
                        detail: analysisDetail(analysis)
                    )

                    if !analysis.collisions.isEmpty {
                        logRow(
                            title: "Filename Conflicts",
                            detail: "\(analysis.collisions.count) conflicts found. File processing did not begin."
                        )
                    }

                    if !analysis.metadataWarnings.isEmpty {
                        metadataWarnings(analysis.metadataWarnings)
                    }
                }

                if let stageTwo {
                    logRow(
                        title: "2/3 File Processing",
                        detail: stageTwoDetail(stageTwo)
                    )
                }

                if let stageThree {
                    logRow(
                        title: "3/3 \(efficientFormat.displayName) Conversion",
                        detail: "Converted: \(stageThree.convertedCount), Skipped: \(stageThree.skippedCount)"
                    )
                } else if stageTwo != nil && !efficientVersionEnabled {
                    logRow(title: "3/3 HEIC/AVIF Copies", detail: "Creation disabled")
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(wasCancelled ? .orange : .red)
                        .textSelection(.enabled)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            if analysis?.exifToolVersion != nil || safetyCheckMessage != nil {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Environment & Safety Checks")
                        .font(.headline)

                    if let version = analysis?.exifToolVersion {
                        logRow(title: "ExifTool", detail: "Version \(version)")
                    }

                    if let safetyCheckMessage {
                        logRow(title: "Preflight Safety Check", detail: safetyCheckMessage)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            HStack {
                Button("Open Output Folder") {
                    guard let workFolder else { return }
                    if !NSWorkspace.shared.open(workFolder) {
                        logActionMessage = "Unable to open the output folder. Check that the folder still exists."
                    }
                }
                .disabled(workFolder == nil)

                Button("Save Detailed Log…", action: saveDetailedLog)

                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
            if let logActionMessage {
                Text(logActionMessage)
                    .font(.caption)
                    .textSelection(.enabled)
            }
        }
        .padding(24)
        .frame(width: 680)
    }

    private var statusTitle: String {
        if completedWithWarnings { return "Task Completed with Warnings" }
        if completedSuccessfully { return "Task Completed" }
        if wasCancelled { return "Task Cancelled" }
        return "Task Not Completed"
    }

    private func saveDetailedLog() {
        let panel = NSSavePanel()
        panel.title = "Save Detailed Log"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        panel.nameFieldStringValue = "Photomuri_\(formatter.string(from: startedAt ?? Date())).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try detailedLog.write(to: url, atomically: true, encoding: .utf8)
            logActionMessage = "Log saved: \(url.lastPathComponent)"
        } catch {
            logActionMessage = "Unable to save the log: \(error.localizedDescription)"
        }
    }

    private var detailedLog: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        let wallClock = DateFormatter()
        wallClock.locale = Locale(identifier: "en_US_POSIX")
        // Match RenameTemplateParser's Calendar.current so the diagnostic
        // wall-clock value agrees with the generated filename.
        wallClock.timeZone = Calendar.current.timeZone
        wallClock.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines = [
            "Photomuri Detailed Task Log",
            "Status: \(statusTitle)",
            "Started: \(startedAt.map { formatter.string(from: $0) } ?? "Not recorded")",
            "Finished: \(finishedAt.map { formatter.string(from: $0) } ?? "Not recorded")",
            "Location: \(workFolder?.path ?? "None")",
            "Performance: Concurrent Rename/Metadata workers: \(renameTasks) / Concurrent Convert workers: \(conversionTasks)",
            "Rename files: \(renameEnabled ? "On" : "Off") / Template: \(renameTemplate)",
            "Preserve originals: \(preserveOriginals ? "On" : "Off")",
            "Update metadata: \(metadataEnabled ? "On" : "Off")",
            "Time zone: \(analysis?.timeZoneOverrideIdentifier ?? "Use recorded time zone")",
            "Apply DST: \(analysis?.applyDaylightSavingTime == false ? "Off" : "On")",
            "HEIC/AVIF copies: \(efficientVersionEnabled ? efficientFormat.displayName : "Off") / Quality: \(quality)%",
            "ExifTool: \(analysis?.exifToolVersion ?? "Not verified")",
            "Safety check: \(safetyCheckMessage ?? "Completion not recorded")", "",
            "[Task Results]"
        ]
        if let analysis { lines.append(analysisDetail(analysis)) }
        if let stageTwo {
            lines.append(stageTwoDetail(stageTwo))
            lines.append("Sorted: \(stageTwo.classifiedCount) / Copied: \(stageTwo.copiedCount) / Metadata updated: \(stageTwo.metadataUpdatedCount)")
        } else {
            lines.append("File processing: Completion not recorded (paths below show the planned destinations)")
        }
        if let stageThree {
            lines.append("\(efficientFormat.displayName): Converted: \(stageThree.convertedCount) / Skipped: \(stageThree.skippedCount)")
            lines.append("Peak concurrent conversion tasks: \(stageThree.peakConcurrentTasks)")
        } else {
            lines.append("HEIC/AVIF conversion: \(efficientVersionEnabled ? "Completion not recorded" : "Disabled")")
        }
        if let errorMessage { lines.append("Error/Cancellation: \(errorMessage)") }
        if let analysis {
            lines.append("\n[File Analysis & Destinations]")
            lines.append("Capture times are the local times used in filenames. ExifTool fields show the values read during analysis.")
            for plan in analysis.renamePlan {
                lines.append("\nSource: \(plan.mediaItem.sourceURL.path)")
                lines.append("Destination: \(plan.destinationURL.path)")
                lines.append("Format: \(plan.mediaItem.kind.rawValue) / Shot: \(plan.shotID) / Sequence: \(plan.sequenceIndex)")
                lines.append("Capture time: \(wallClock.string(from: plan.mediaItem.captureDate))")
                lines.append(plan.mediaItem.captureDateDetails)
                lines.append("File processing: \(stageTwo != nil ? "Completed" : "Completion not verified") / Rename plan: \(plan.shouldRename ? "Rename" : "Skip (keep filename)")")
            }
            lines.append("\n[HEIC/AVIF Conversion Plan & Results]")
            for shot in analysis.shots {
                guard efficientVersionEnabled else { break }
                let candidates = shot.items.filter { $0.kind == .jpeg }.sorted {
                    $0.sourceURL.lastPathComponent.localizedStandardCompare($1.sourceURL.lastPathComponent) == .orderedAscending
                }
                if let jpeg = candidates.first,
                   let plan = analysis.renamePlan.first(where: { $0.mediaItem.id == jpeg.id }) {
                    let output = plan.destinationURL.deletingLastPathComponent().deletingLastPathComponent()
                        .appendingPathComponent(efficientFormat.folderName)
                        .appendingPathComponent(plan.destinationURL.lastPathComponent)
                        .deletingPathExtension().appendingPathExtension(efficientFormat.fileExtension)
                    lines.append("\(jpeg.sourceURL.lastPathComponent) → \(output.path): \(stageThree != nil ? "Converted" : "Completion not verified")")
                } else {
                    lines.append("\(shot.originalStem): Skipped (no JPG; RAW only or video)")
                }
            }
            lines.append("\n[Conflicts & Warnings]")
            for collision in analysis.collisions {
                lines.append("Conflict: \(collision.destinationURL.path) / \(collision.reason)")
                lines.append(contentsOf: collision.sourceURLs.map { "  Source: \($0.path)" })
            }
            lines.append(contentsOf: analysis.metadataWarnings.map(warningDetail))
            if analysis.collisions.isEmpty && analysis.metadataWarnings.isEmpty { lines.append("None") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private var statusIconName: String {
        if completedWithWarnings { return "exclamationmark.triangle.fill" }
        if completedSuccessfully { return "checkmark.circle.fill" }
        if wasCancelled { return "stop.circle.fill" }
        return "exclamationmark.triangle.fill"
    }

    private var statusColor: Color {
        if completedWithWarnings { return .orange }
        if completedSuccessfully { return .green }
        return .orange
    }

    private func logRow(title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .fontWeight(.medium)
                .frame(width: 170, alignment: .leading)
            Text(detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func metadataWarnings(
        _ warnings: [MetadataReadWarning]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Metadata Warnings: \(warnings.count)")
                .fontWeight(.medium)
                .foregroundStyle(.orange)

            ForEach(Array(warnings.prefix(6))) { warning in
                Text(warningDetail(warning))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if warnings.count > 6 {
                Text("\(warnings.count - 6) additional files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 2)
    }

    private func warningDetail(_ warning: MetadataReadWarning) -> String {
        let camera = warning.cameraName.map { " · \($0)" } ?? ""
        return "• \(warning.sourceURL.lastPathComponent)\(camera): \(warning.message)"
    }

    private func stageTwoDetail(_ result: StageTwoResult) -> String {
        "Renamed: \(result.renamedCount), Skipped: \(result.skippedCount)"
    }

    private func analysisDetail(_ result: StageOneResult) -> String {
        let pairCount = result.shots.filter { shot in
            let kinds = Set(shot.items.map(\.kind))
            return kinds.contains(.raw) && kinds.contains(.jpeg)
        }.count

        let rawOnlyCount = result.shots.filter { shot in
            let imageKinds = Set(
                shot.items
                    .map(\.kind)
                    .filter { $0 != .video }
            )
            return imageKinds == [.raw]
        }.count

        let jpegOnlyCount = result.shots.filter { shot in
            let imageKinds = Set(
                shot.items
                    .map(\.kind)
                    .filter { $0 != .video }
            )
            return imageKinds == [.jpeg]
        }.count

        let videoCount = result.mediaItems.filter { $0.kind == .video }.count

        return "Total: \(result.mediaItems.count) files " +
        "(RAW/JPG pairs: \(pairCount), RAW only: \(rawOnlyCount), " +
        "JPG only: \(jpegOnlyCount), Videos: \(videoCount))"
    }
}

private struct TimeZoneReviewView: View {
    private enum Choice: String, CaseIterable, Identifiable {
        case recorded
        case override

        var id: String { rawValue }

        var title: String {
            switch self {
            case .recorded:
                return "Use Recorded Time Zone"
            case .override:
                return "Change Time Zone"
            }
        }
    }

    let summaries: [CaptureTimeZoneSummary]
    let referenceDate: Date
    @Binding var selectedTimeZoneIdentifier: String
    @Binding var applyDaylightSavingTime: Bool
    let onCancel: () -> Void
    let onUseRecordedTimeZone: () -> Void
    let onUseSelectedTimeZone: () -> Void

    @State private var choice: Choice = .recorded
    @State private var searchText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Review Capture Time Zone")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Review the time zones recorded in your files before continuing.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(summaries) { summary in
                        HStack {
                            Text(timeZoneSummaryTitle(summary))
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .help(timeZoneSummaryTitle(summary))
                            Spacer()
                            Text(fileCountDescription(summary))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                    }
                }
            }
            .frame(height: min(CGFloat(max(summaries.count, 1)) * 24, 96))
            .padding(12)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 12) {
                Picker("Time Zone Handling", selection: $choice) {
                    ForEach(Choice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Toggle("Apply DST", isOn: $applyDaylightSavingTime)
                    .fixedSize()
                    .disabled(choice == .recorded)
                    .help("Applies daylight saving time on the capture date. Turn off to use the selected city's standard time.")
            }

            if choice == .override {
                TextField("Search Cities or Countries (e.g. Seoul, Korea, USA)", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if filteredTimeZones.isEmpty {
                            Text("No matching cities.")
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 8)
                        }
                        ForEach(filteredTimeZones) { entry in
                            HStack(spacing: 8) {
                                Button {
                                    selectedTimeZoneIdentifier = entry.preferredIdentifier(keeping: selectedTimeZoneIdentifier)
                                } label: {
                                    HStack {
                                        Image(systemName: entry.contains(identifier: selectedTimeZoneIdentifier)
                                              ? "checkmark.circle.fill" : "circle")
                                        Text(entry.displayName(on: referenceDate, applyDST: applyDaylightSavingTime))
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                        Spacer(minLength: 0)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Menu {
                                    ForEach(entry.locations) { city in
                                        Button {
                                            selectedTimeZoneIdentifier = city.identifier
                                        } label: {
                                            if city.identifier == selectedTimeZoneIdentifier {
                                                Label(entry.cityName(city, on: referenceDate, applyDST: applyDaylightSavingTime), systemImage: "checkmark")
                                            } else {
                                                Text(entry.cityName(city, on: referenceDate, applyDST: applyDaylightSavingTime))
                                            }
                                        }
                                    }
                                } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .fixedSize()
                                .accessibilityLabel("Choose City")
                                .help("Cities with the same UTC offset may have different DST rules. Choose the capture city.")
                            }
                            .padding(.vertical, 5)
                        }
                    }
                }
                .frame(height: 180)
                .padding(.horizontal, 8)
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Text("Selected: \(selectedTimeZoneDisplayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("*: Daylight saving time is applied on the preview capture date.\nSearch works offline. Each file uses its own capture date.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link("City data: GeoNames (CC BY 4.0)", destination: URL(string: "https://www.geonames.org/")!)
                    .font(.caption2)
            } else {
                Text("Uses the capture time and time zone recorded by the camera.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button("Continue") {
                    if choice == .recorded {
                        onUseRecordedTimeZone()
                    } else {
                        onUseSelectedTimeZone()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 660)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var filteredTimeZones: [TimeZoneOffsetGroup] {
        TimeZoneCatalog.offsetGroups(matching: searchText, on: referenceDate, applyDST: applyDaylightSavingTime)
    }

    private var selectedTimeZoneDisplayName: String {
        if let entry = TimeZoneCatalog.allEntries.first(where: {
            $0.identifier == selectedTimeZoneIdentifier
        }) {
            return entry.displayName(on: referenceDate, applyDST: applyDaylightSavingTime)
        }
        return selectedTimeZoneIdentifier
    }

    private func timeZoneSummaryTitle(
        _ summary: CaptureTimeZoneSummary
    ) -> String {
        guard let seconds = summary.offsetSeconds else {
            return "No Time Zone Recorded"
        }

        let sign = seconds < 0 ? "−" : "+"
        let absolute = abs(seconds)
        let hours = absolute / 3600
        let minutes = (absolute % 3600) / 60
        let cities = TimeZoneCatalog.cityExamples(
            forOffset: seconds,
            on: referenceDate
        )
        return String(
            format: "UTC %@%02d:%02d%@",
            sign,
            hours,
            minutes,
            cities.isEmpty ? "" : " (\(cities))"
        )
    }

    private func fileCountDescription(
        _ summary: CaptureTimeZoneSummary
    ) -> String {
        var parts: [String] = []
        if summary.imageCount > 0 {
            parts.append("Photos/RAW: \(summary.imageCount)")
        }
        if summary.videoCount > 0 {
            parts.append("Videos: \(summary.videoCount)")
        }
        return parts.joined(separator: " · ")
    }

}


// Vector paths from BYAstra_Background_Vector.svg; show only the second fifth.
private struct BYAstraHeaderBackground: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 3.0 / 255, green: 24.0 / 255, blue: 50.0 / 255)))
            let transform = CGAffineTransform(a: size.width / 2048, b: 0, c: 0, d: size.height / 409.6, tx: 0, ty: -size.height)
            var wave0 = Path()
            wave0.move(to: CGPoint(x: 0, y: 1489.47))
            wave0.addCurve(to: CGPoint(x: 64.00, y: 1454.82), control1: CGPoint(x: 21.33, y: 1480.71), control2: CGPoint(x: 42.67, y: 1468.97))
            wave0.addCurve(to: CGPoint(x: 128.00, y: 1405.67), control1: CGPoint(x: 85.33, y: 1440.66), control2: CGPoint(x: 106.67, y: 1424.10))
            wave0.addCurve(to: CGPoint(x: 192.00, y: 1344.99), control1: CGPoint(x: 149.33, y: 1387.24), control2: CGPoint(x: 170.67, y: 1366.95))
            wave0.addCurve(to: CGPoint(x: 256.00, y: 1275.96), control1: CGPoint(x: 213.33, y: 1323.03), control2: CGPoint(x: 234.67, y: 1299.39))
            wave0.addCurve(to: CGPoint(x: 320.00, y: 1206.98), control1: CGPoint(x: 277.33, y: 1252.53), control2: CGPoint(x: 298.67, y: 1229.31))
            wave0.addCurve(to: CGPoint(x: 384.00, y: 1143.14), control1: CGPoint(x: 341.33, y: 1184.66), control2: CGPoint(x: 362.67, y: 1163.22))
            wave0.addCurve(to: CGPoint(x: 448.00, y: 1086.72), control1: CGPoint(x: 405.33, y: 1123.05), control2: CGPoint(x: 426.67, y: 1104.30))
            wave0.addCurve(to: CGPoint(x: 512.00, y: 1037.46), control1: CGPoint(x: 469.33, y: 1069.14), control2: CGPoint(x: 490.67, y: 1052.73))
            wave0.addCurve(to: CGPoint(x: 576.00, y: 994.53), control1: CGPoint(x: 533.33, y: 1022.20), control2: CGPoint(x: 554.67, y: 1008.08))
            wave0.addCurve(to: CGPoint(x: 640.00, y: 955.64), control1: CGPoint(x: 597.33, y: 980.98), control2: CGPoint(x: 618.67, y: 968.00))
            wave0.addCurve(to: CGPoint(x: 704.00, y: 920.39), control1: CGPoint(x: 661.33, y: 943.27), control2: CGPoint(x: 682.67, y: 931.52))
            wave0.addCurve(to: CGPoint(x: 768.00, y: 888.23), control1: CGPoint(x: 725.33, y: 909.26), control2: CGPoint(x: 746.67, y: 898.75))
            wave0.addCurve(to: CGPoint(x: 832.00, y: 856.25), control1: CGPoint(x: 789.33, y: 877.70), control2: CGPoint(x: 810.67, y: 867.15))
            wave0.addCurve(to: CGPoint(x: 896.00, y: 822.46), control1: CGPoint(x: 853.33, y: 845.35), control2: CGPoint(x: 874.67, y: 834.09))
            wave0.addCurve(to: CGPoint(x: 960.00, y: 785.54), control1: CGPoint(x: 917.33, y: 810.83), control2: CGPoint(x: 938.67, y: 798.84))
            wave0.addCurve(to: CGPoint(x: 1024.00, y: 741.86), control1: CGPoint(x: 981.33, y: 772.23), control2: CGPoint(x: 1002.67, y: 757.61))
            wave0.addCurve(to: CGPoint(x: 1088.00, y: 690.69), control1: CGPoint(x: 1045.33, y: 726.11), control2: CGPoint(x: 1066.67, y: 709.22))
            wave0.addCurve(to: CGPoint(x: 1152.00, y: 629.96), control1: CGPoint(x: 1109.33, y: 672.15), control2: CGPoint(x: 1130.67, y: 651.96))
            wave0.addCurve(to: CGPoint(x: 1216.00, y: 558.54), control1: CGPoint(x: 1173.33, y: 607.95), control2: CGPoint(x: 1194.67, y: 584.14))
            wave0.addCurve(to: CGPoint(x: 1280.00, y: 477.75), control1: CGPoint(x: 1237.33, y: 532.93), control2: CGPoint(x: 1258.67, y: 505.54))
            wave0.addCurve(to: CGPoint(x: 1344.00, y: 394.65), control1: CGPoint(x: 1301.33, y: 449.96), control2: CGPoint(x: 1322.67, y: 421.77))
            wave0.addCurve(to: CGPoint(x: 1408.00, y: 316.93), control1: CGPoint(x: 1365.33, y: 367.52), control2: CGPoint(x: 1386.67, y: 341.45))
            wave0.addCurve(to: CGPoint(x: 1472.00, y: 248.00), control1: CGPoint(x: 1429.33, y: 292.41), control2: CGPoint(x: 1450.67, y: 269.44))
            wave0.addCurve(to: CGPoint(x: 1536.00, y: 187.94), control1: CGPoint(x: 1493.33, y: 226.56), control2: CGPoint(x: 1514.67, y: 206.66))
            wave0.addCurve(to: CGPoint(x: 1600.00, y: 135.08), control1: CGPoint(x: 1557.33, y: 169.22), control2: CGPoint(x: 1578.67, y: 151.69))
            wave0.addCurve(to: CGPoint(x: 1664.00, y: 88.25), control1: CGPoint(x: 1621.33, y: 118.46), control2: CGPoint(x: 1642.67, y: 102.76))
            wave0.addCurve(to: CGPoint(x: 1728.00, y: 46.32), control1: CGPoint(x: 1685.33, y: 73.75), control2: CGPoint(x: 1706.67, y: 60.43))
            wave0.addCurve(to: CGPoint(x: 1792.00, y: 9.35), control1: CGPoint(x: 1749.33, y: 32.21), control2: CGPoint(x: 1770.67, y: 17.31))
            wave0.addCurve(to: CGPoint(x: 1856.00, y: 0.00), control1: CGPoint(x: 1813.33, y: 1.39), control2: CGPoint(x: 1834.67, y: 0.37))
            wave0.addCurve(to: CGPoint(x: 1920.00, y: 0.00), control1: CGPoint(x: 1877.33, y: -0.37), control2: CGPoint(x: 1898.67, y: -0.11))
            wave0.addCurve(to: CGPoint(x: 1984.00, y: 0.00), control1: CGPoint(x: 1941.33, y: 0.11), control2: CGPoint(x: 1962.67, y: 0.05))
            wave0.addCurve(to: CGPoint(x: 2047.00, y: -0.00), control1: CGPoint(x: 2005.00, y: -0.05), control2: CGPoint(x: 2026.00, y: -0.10))
            wave0.addLine(to: CGPoint(x: 2048, y: 905.15))
            wave0.addLine(to: CGPoint(x: 2047, y: 905.15))
            wave0.addCurve(to: CGPoint(x: 1984.00, y: 938.32), control1: CGPoint(x: 2026.00, y: 914.07), control2: CGPoint(x: 2005.00, y: 925.35))
            wave0.addCurve(to: CGPoint(x: 1920.00, y: 982.40), control1: CGPoint(x: 1962.67, y: 951.50), control2: CGPoint(x: 1941.33, y: 966.42))
            wave0.addCurve(to: CGPoint(x: 1856.00, y: 1033.38), control1: CGPoint(x: 1898.67, y: 998.38), control2: CGPoint(x: 1877.33, y: 1015.43))
            wave0.addCurve(to: CGPoint(x: 1792.00, y: 1089.52), control1: CGPoint(x: 1834.67, y: 1051.34), control2: CGPoint(x: 1813.33, y: 1070.22))
            wave0.addCurve(to: CGPoint(x: 1728.00, y: 1147.96), control1: CGPoint(x: 1770.67, y: 1108.81), control2: CGPoint(x: 1749.33, y: 1128.52))
            wave0.addCurve(to: CGPoint(x: 1664.00, y: 1204.61), control1: CGPoint(x: 1706.67, y: 1167.40), control2: CGPoint(x: 1685.33, y: 1186.57))
            wave0.addCurve(to: CGPoint(x: 1600.00, y: 1254.85), control1: CGPoint(x: 1642.67, y: 1222.64), control2: CGPoint(x: 1621.33, y: 1239.54))
            wave0.addCurve(to: CGPoint(x: 1536.00, y: 1296.28), control1: CGPoint(x: 1578.67, y: 1270.16), control2: CGPoint(x: 1557.33, y: 1283.89))
            wave0.addCurve(to: CGPoint(x: 1472.00, y: 1329.53), control1: CGPoint(x: 1514.67, y: 1308.67), control2: CGPoint(x: 1493.33, y: 1319.74))
            wave0.addCurve(to: CGPoint(x: 1408.00, y: 1355.32), control1: CGPoint(x: 1450.67, y: 1339.32), control2: CGPoint(x: 1429.33, y: 1347.84))
            wave0.addCurve(to: CGPoint(x: 1344.00, y: 1374.82), control1: CGPoint(x: 1386.67, y: 1362.81), control2: CGPoint(x: 1365.33, y: 1369.26))
            wave0.addCurve(to: CGPoint(x: 1280.00, y: 1389.19), control1: CGPoint(x: 1322.67, y: 1380.39), control2: CGPoint(x: 1301.33, y: 1385.08))
            wave0.addCurve(to: CGPoint(x: 1216.00, y: 1399.85), control1: CGPoint(x: 1258.67, y: 1393.31), control2: CGPoint(x: 1237.33, y: 1396.86))
            wave0.addCurve(to: CGPoint(x: 1152.00, y: 1407.46), control1: CGPoint(x: 1194.67, y: 1402.85), control2: CGPoint(x: 1173.33, y: 1405.29))
            wave0.addCurve(to: CGPoint(x: 1088.00, y: 1413.36), control1: CGPoint(x: 1130.67, y: 1409.63), control2: CGPoint(x: 1109.33, y: 1411.51))
            wave0.addCurve(to: CGPoint(x: 1024.00, y: 1418.91), control1: CGPoint(x: 1066.67, y: 1415.20), control2: CGPoint(x: 1045.33, y: 1417.00))
            wave0.addCurve(to: CGPoint(x: 960.00, y: 1425.22), control1: CGPoint(x: 1002.67, y: 1420.83), control2: CGPoint(x: 981.33, y: 1422.86))
            wave0.addCurve(to: CGPoint(x: 896.00, y: 1433.54), control1: CGPoint(x: 938.67, y: 1427.59), control2: CGPoint(x: 917.33, y: 1430.29))
            wave0.addCurve(to: CGPoint(x: 832.00, y: 1445.04), control1: CGPoint(x: 874.67, y: 1436.80), control2: CGPoint(x: 853.33, y: 1440.61))
            wave0.addCurve(to: CGPoint(x: 768.00, y: 1460.27), control1: CGPoint(x: 810.67, y: 1449.46), control2: CGPoint(x: 789.33, y: 1454.52))
            wave0.addCurve(to: CGPoint(x: 704.00, y: 1479.67), control1: CGPoint(x: 746.67, y: 1466.02), control2: CGPoint(x: 725.33, y: 1472.48))
            wave0.addCurve(to: CGPoint(x: 640.00, y: 1503.52), control1: CGPoint(x: 682.67, y: 1486.85), control2: CGPoint(x: 661.33, y: 1494.77))
            wave0.addCurve(to: CGPoint(x: 576.00, y: 1532.25), control1: CGPoint(x: 618.67, y: 1512.28), control2: CGPoint(x: 597.33, y: 1521.87))
            wave0.addCurve(to: CGPoint(x: 512.00, y: 1565.73), control1: CGPoint(x: 554.67, y: 1542.62), control2: CGPoint(x: 533.33, y: 1553.78))
            wave0.addCurve(to: CGPoint(x: 448.00, y: 1603.74), control1: CGPoint(x: 490.67, y: 1577.69), control2: CGPoint(x: 469.33, y: 1590.42))
            wave0.addCurve(to: CGPoint(x: 384.00, y: 1645.01), control1: CGPoint(x: 426.67, y: 1617.05), control2: CGPoint(x: 405.33, y: 1630.95))
            wave0.addCurve(to: CGPoint(x: 320.00, y: 1687.23), control1: CGPoint(x: 362.67, y: 1659.08), control2: CGPoint(x: 341.33, y: 1673.33))
            wave0.addCurve(to: CGPoint(x: 256.00, y: 1727.40), control1: CGPoint(x: 298.67, y: 1701.13), control2: CGPoint(x: 277.33, y: 1714.69))
            wave0.addCurve(to: CGPoint(x: 192.00, y: 1762.75), control1: CGPoint(x: 234.67, y: 1740.11), control2: CGPoint(x: 213.33, y: 1751.96))
            wave0.addCurve(to: CGPoint(x: 128.00, y: 1791.69), control1: CGPoint(x: 170.67, y: 1773.54), control2: CGPoint(x: 149.33, y: 1783.27))
            wave0.addCurve(to: CGPoint(x: 64.00, y: 1812.92), control1: CGPoint(x: 106.67, y: 1800.11), control2: CGPoint(x: 85.33, y: 1807.22))
            wave0.addCurve(to: CGPoint(x: 0.00, y: 1825.66), control1: CGPoint(x: 42.67, y: 1818.62), control2: CGPoint(x: 21.33, y: 1822.91))
            wave0.closeSubpath()
            context.fill(wave0.applying(transform), with: .color(Color(red: 0.00392156862745098, green: 0.16862745098039217, blue: 0.34509803921568627)))
            var wave1 = Path()
            wave1.move(to: CGPoint(x: 0, y: 1489.47))
            wave1.addCurve(to: CGPoint(x: 64.00, y: 1454.82), control1: CGPoint(x: 21.33, y: 1480.71), control2: CGPoint(x: 42.67, y: 1468.97))
            wave1.addCurve(to: CGPoint(x: 128.00, y: 1405.67), control1: CGPoint(x: 85.33, y: 1440.66), control2: CGPoint(x: 106.67, y: 1424.10))
            wave1.addCurve(to: CGPoint(x: 192.00, y: 1344.99), control1: CGPoint(x: 149.33, y: 1387.24), control2: CGPoint(x: 170.67, y: 1366.95))
            wave1.addCurve(to: CGPoint(x: 256.00, y: 1275.96), control1: CGPoint(x: 213.33, y: 1323.03), control2: CGPoint(x: 234.67, y: 1299.39))
            wave1.addCurve(to: CGPoint(x: 320.00, y: 1206.98), control1: CGPoint(x: 277.33, y: 1252.53), control2: CGPoint(x: 298.67, y: 1229.31))
            wave1.addCurve(to: CGPoint(x: 384.00, y: 1143.14), control1: CGPoint(x: 341.33, y: 1184.66), control2: CGPoint(x: 362.67, y: 1163.22))
            wave1.addCurve(to: CGPoint(x: 448.00, y: 1086.72), control1: CGPoint(x: 405.33, y: 1123.05), control2: CGPoint(x: 426.67, y: 1104.30))
            wave1.addCurve(to: CGPoint(x: 512.00, y: 1037.46), control1: CGPoint(x: 469.33, y: 1069.14), control2: CGPoint(x: 490.67, y: 1052.73))
            wave1.addCurve(to: CGPoint(x: 576.00, y: 994.53), control1: CGPoint(x: 533.33, y: 1022.20), control2: CGPoint(x: 554.67, y: 1008.08))
            wave1.addCurve(to: CGPoint(x: 640.00, y: 955.64), control1: CGPoint(x: 597.33, y: 980.98), control2: CGPoint(x: 618.67, y: 968.00))
            wave1.addCurve(to: CGPoint(x: 704.00, y: 920.39), control1: CGPoint(x: 661.33, y: 943.27), control2: CGPoint(x: 682.67, y: 931.52))
            wave1.addCurve(to: CGPoint(x: 768.00, y: 888.23), control1: CGPoint(x: 725.33, y: 909.26), control2: CGPoint(x: 746.67, y: 898.75))
            wave1.addCurve(to: CGPoint(x: 832.00, y: 856.25), control1: CGPoint(x: 789.33, y: 877.70), control2: CGPoint(x: 810.67, y: 867.15))
            wave1.addCurve(to: CGPoint(x: 896.00, y: 822.46), control1: CGPoint(x: 853.33, y: 845.35), control2: CGPoint(x: 874.67, y: 834.09))
            wave1.addCurve(to: CGPoint(x: 960.00, y: 785.54), control1: CGPoint(x: 917.33, y: 810.83), control2: CGPoint(x: 938.67, y: 798.84))
            wave1.addCurve(to: CGPoint(x: 1024.00, y: 741.86), control1: CGPoint(x: 981.33, y: 772.23), control2: CGPoint(x: 1002.67, y: 757.61))
            wave1.addCurve(to: CGPoint(x: 1088.00, y: 690.69), control1: CGPoint(x: 1045.33, y: 726.11), control2: CGPoint(x: 1066.67, y: 709.22))
            wave1.addCurve(to: CGPoint(x: 1152.00, y: 629.96), control1: CGPoint(x: 1109.33, y: 672.15), control2: CGPoint(x: 1130.67, y: 651.96))
            wave1.addCurve(to: CGPoint(x: 1216.00, y: 558.54), control1: CGPoint(x: 1173.33, y: 607.95), control2: CGPoint(x: 1194.67, y: 584.14))
            wave1.addCurve(to: CGPoint(x: 1280.00, y: 477.75), control1: CGPoint(x: 1237.33, y: 532.93), control2: CGPoint(x: 1258.67, y: 505.54))
            wave1.addCurve(to: CGPoint(x: 1344.00, y: 394.65), control1: CGPoint(x: 1301.33, y: 449.96), control2: CGPoint(x: 1322.67, y: 421.77))
            wave1.addCurve(to: CGPoint(x: 1408.00, y: 316.93), control1: CGPoint(x: 1365.33, y: 367.52), control2: CGPoint(x: 1386.67, y: 341.45))
            wave1.addCurve(to: CGPoint(x: 1472.00, y: 248.00), control1: CGPoint(x: 1429.33, y: 292.41), control2: CGPoint(x: 1450.67, y: 269.44))
            wave1.addCurve(to: CGPoint(x: 1536.00, y: 187.94), control1: CGPoint(x: 1493.33, y: 226.56), control2: CGPoint(x: 1514.67, y: 206.66))
            wave1.addCurve(to: CGPoint(x: 1600.00, y: 135.08), control1: CGPoint(x: 1557.33, y: 169.22), control2: CGPoint(x: 1578.67, y: 151.69))
            wave1.addCurve(to: CGPoint(x: 1664.00, y: 88.25), control1: CGPoint(x: 1621.33, y: 118.46), control2: CGPoint(x: 1642.67, y: 102.76))
            wave1.addCurve(to: CGPoint(x: 1728.00, y: 46.32), control1: CGPoint(x: 1685.33, y: 73.75), control2: CGPoint(x: 1706.67, y: 60.43))
            wave1.addCurve(to: CGPoint(x: 1792.00, y: 9.35), control1: CGPoint(x: 1749.33, y: 32.21), control2: CGPoint(x: 1770.67, y: 17.31))
            wave1.addCurve(to: CGPoint(x: 1856.00, y: 0.00), control1: CGPoint(x: 1813.33, y: 1.39), control2: CGPoint(x: 1834.67, y: 0.37))
            wave1.addCurve(to: CGPoint(x: 1920.00, y: 0.00), control1: CGPoint(x: 1877.33, y: -0.37), control2: CGPoint(x: 1898.67, y: -0.11))
            wave1.addCurve(to: CGPoint(x: 1984.00, y: 0.00), control1: CGPoint(x: 1941.33, y: 0.11), control2: CGPoint(x: 1962.67, y: 0.05))
            wave1.addCurve(to: CGPoint(x: 2047.00, y: -0.00), control1: CGPoint(x: 2005.00, y: -0.05), control2: CGPoint(x: 2026.00, y: -0.10))
            wave1.addLine(to: CGPoint(x: 2048, y: 712.53))
            wave1.addLine(to: CGPoint(x: 2047, y: 712.53))
            wave1.addCurve(to: CGPoint(x: 1984.00, y: 746.16), control1: CGPoint(x: 2026.00, y: 722.11), control2: CGPoint(x: 2005.00, y: 733.38))
            wave1.addCurve(to: CGPoint(x: 1920.00, y: 789.55), control1: CGPoint(x: 1962.67, y: 759.14), control2: CGPoint(x: 1941.33, y: 773.67))
            wave1.addCurve(to: CGPoint(x: 1856.00, y: 841.31), control1: CGPoint(x: 1898.67, y: 805.43), control2: CGPoint(x: 1877.33, y: 822.67))
            wave1.addCurve(to: CGPoint(x: 1792.00, y: 900.99), control1: CGPoint(x: 1834.67, y: 859.96), control2: CGPoint(x: 1813.33, y: 880.02))
            wave1.addCurve(to: CGPoint(x: 1728.00, y: 965.97), control1: CGPoint(x: 1770.67, y: 921.97), control2: CGPoint(x: 1749.33, y: 943.85))
            wave1.addCurve(to: CGPoint(x: 1664.00, y: 1032.01), control1: CGPoint(x: 1706.67, y: 988.10), control2: CGPoint(x: 1685.33, y: 1010.46))
            wave1.addCurve(to: CGPoint(x: 1600.00, y: 1093.33), control1: CGPoint(x: 1642.67, y: 1053.55), control2: CGPoint(x: 1621.33, y: 1074.28))
            wave1.addCurve(to: CGPoint(x: 1536.00, y: 1145.25), control1: CGPoint(x: 1578.67, y: 1112.39), control2: CGPoint(x: 1557.33, y: 1129.77))
            wave1.addCurve(to: CGPoint(x: 1472.00, y: 1186.42), control1: CGPoint(x: 1514.67, y: 1160.73), control2: CGPoint(x: 1493.33, y: 1174.31))
            wave1.addCurve(to: CGPoint(x: 1408.00, y: 1218.71), control1: CGPoint(x: 1450.67, y: 1198.54), control2: CGPoint(x: 1429.33, y: 1209.20))
            wave1.addCurve(to: CGPoint(x: 1344.00, y: 1243.90), control1: CGPoint(x: 1386.67, y: 1228.22), control2: CGPoint(x: 1365.33, y: 1236.58))
            wave1.addCurve(to: CGPoint(x: 1280.00, y: 1263.07), control1: CGPoint(x: 1322.67, y: 1251.22), control2: CGPoint(x: 1301.33, y: 1257.50))
            wave1.addCurve(to: CGPoint(x: 1216.00, y: 1277.80), control1: CGPoint(x: 1258.67, y: 1268.65), control2: CGPoint(x: 1237.33, y: 1273.51))
            wave1.addCurve(to: CGPoint(x: 1152.00, y: 1289.15), control1: CGPoint(x: 1194.67, y: 1282.09), control2: CGPoint(x: 1173.33, y: 1285.81))
            wave1.addCurve(to: CGPoint(x: 1088.00, y: 1298.27), control1: CGPoint(x: 1130.67, y: 1292.49), control2: CGPoint(x: 1109.33, y: 1295.44))
            wave1.addCurve(to: CGPoint(x: 1024.00, y: 1306.81), control1: CGPoint(x: 1066.67, y: 1301.11), control2: CGPoint(x: 1045.33, y: 1303.82))
            wave1.addCurve(to: CGPoint(x: 960.00, y: 1316.58), control1: CGPoint(x: 1002.67, y: 1309.80), control2: CGPoint(x: 981.33, y: 1313.06))
            wave1.addCurve(to: CGPoint(x: 896.00, y: 1328.34), control1: CGPoint(x: 938.67, y: 1320.11), control2: CGPoint(x: 917.33, y: 1323.90))
            wave1.addCurve(to: CGPoint(x: 832.00, y: 1343.46), control1: CGPoint(x: 874.67, y: 1332.78), control2: CGPoint(x: 853.33, y: 1337.88))
            wave1.addCurve(to: CGPoint(x: 768.00, y: 1362.01), control1: CGPoint(x: 810.67, y: 1349.04), control2: CGPoint(x: 789.33, y: 1355.10))
            wave1.addCurve(to: CGPoint(x: 704.00, y: 1385.17), control1: CGPoint(x: 746.67, y: 1368.93), control2: CGPoint(x: 725.33, y: 1376.69))
            wave1.addCurve(to: CGPoint(x: 640.00, y: 1412.88), control1: CGPoint(x: 682.67, y: 1393.64), control2: CGPoint(x: 661.33, y: 1402.83))
            wave1.addCurve(to: CGPoint(x: 576.00, y: 1445.73), control1: CGPoint(x: 618.67, y: 1422.93), control2: CGPoint(x: 597.33, y: 1433.84))
            wave1.addCurve(to: CGPoint(x: 512.00, y: 1484.19), control1: CGPoint(x: 554.67, y: 1457.61), control2: CGPoint(x: 533.33, y: 1470.46))
            wave1.addCurve(to: CGPoint(x: 448.00, y: 1527.87), control1: CGPoint(x: 490.67, y: 1497.91), control2: CGPoint(x: 469.33, y: 1512.50))
            wave1.addCurve(to: CGPoint(x: 384.00, y: 1575.77), control1: CGPoint(x: 426.67, y: 1543.23), control2: CGPoint(x: 405.33, y: 1559.37))
            wave1.addCurve(to: CGPoint(x: 320.00, y: 1625.39), control1: CGPoint(x: 362.67, y: 1592.17), control2: CGPoint(x: 341.33, y: 1608.85))
            wave1.addCurve(to: CGPoint(x: 256.00, y: 1673.81), control1: CGPoint(x: 298.67, y: 1641.94), control2: CGPoint(x: 277.33, y: 1658.37))
            wave1.addCurve(to: CGPoint(x: 192.00, y: 1716.89), control1: CGPoint(x: 234.67, y: 1689.24), control2: CGPoint(x: 213.33, y: 1703.70))
            wave1.addCurve(to: CGPoint(x: 128.00, y: 1752.75), control1: CGPoint(x: 170.67, y: 1730.08), control2: CGPoint(x: 149.33, y: 1742.01))
            wave1.addCurve(to: CGPoint(x: 64.00, y: 1780.90), control1: CGPoint(x: 106.67, y: 1763.49), control2: CGPoint(x: 85.33, y: 1773.04))
            wave1.addCurve(to: CGPoint(x: 0.00, y: 1798.87), control1: CGPoint(x: 42.67, y: 1788.75), control2: CGPoint(x: 21.33, y: 1794.91))
            wave1.closeSubpath()
            context.fill(wave1.applying(transform), with: .color(Color(red: 0.01568627450980392, green: 0.47058823529411764, blue: 0.5176470588235295)))
            var wave2 = Path()
            wave2.move(to: CGPoint(x: 0, y: 1489.47))
            wave2.addCurve(to: CGPoint(x: 64.00, y: 1454.82), control1: CGPoint(x: 21.33, y: 1480.71), control2: CGPoint(x: 42.67, y: 1468.97))
            wave2.addCurve(to: CGPoint(x: 128.00, y: 1405.67), control1: CGPoint(x: 85.33, y: 1440.66), control2: CGPoint(x: 106.67, y: 1424.10))
            wave2.addCurve(to: CGPoint(x: 192.00, y: 1344.99), control1: CGPoint(x: 149.33, y: 1387.24), control2: CGPoint(x: 170.67, y: 1366.95))
            wave2.addCurve(to: CGPoint(x: 256.00, y: 1275.96), control1: CGPoint(x: 213.33, y: 1323.03), control2: CGPoint(x: 234.67, y: 1299.39))
            wave2.addCurve(to: CGPoint(x: 320.00, y: 1206.98), control1: CGPoint(x: 277.33, y: 1252.53), control2: CGPoint(x: 298.67, y: 1229.31))
            wave2.addCurve(to: CGPoint(x: 384.00, y: 1143.14), control1: CGPoint(x: 341.33, y: 1184.66), control2: CGPoint(x: 362.67, y: 1163.22))
            wave2.addCurve(to: CGPoint(x: 448.00, y: 1086.72), control1: CGPoint(x: 405.33, y: 1123.05), control2: CGPoint(x: 426.67, y: 1104.30))
            wave2.addCurve(to: CGPoint(x: 512.00, y: 1037.46), control1: CGPoint(x: 469.33, y: 1069.14), control2: CGPoint(x: 490.67, y: 1052.73))
            wave2.addCurve(to: CGPoint(x: 576.00, y: 994.53), control1: CGPoint(x: 533.33, y: 1022.20), control2: CGPoint(x: 554.67, y: 1008.08))
            wave2.addCurve(to: CGPoint(x: 640.00, y: 955.64), control1: CGPoint(x: 597.33, y: 980.98), control2: CGPoint(x: 618.67, y: 968.00))
            wave2.addCurve(to: CGPoint(x: 704.00, y: 920.39), control1: CGPoint(x: 661.33, y: 943.27), control2: CGPoint(x: 682.67, y: 931.52))
            wave2.addCurve(to: CGPoint(x: 768.00, y: 888.23), control1: CGPoint(x: 725.33, y: 909.26), control2: CGPoint(x: 746.67, y: 898.75))
            wave2.addCurve(to: CGPoint(x: 832.00, y: 856.25), control1: CGPoint(x: 789.33, y: 877.70), control2: CGPoint(x: 810.67, y: 867.15))
            wave2.addCurve(to: CGPoint(x: 896.00, y: 822.46), control1: CGPoint(x: 853.33, y: 845.35), control2: CGPoint(x: 874.67, y: 834.09))
            wave2.addCurve(to: CGPoint(x: 960.00, y: 785.54), control1: CGPoint(x: 917.33, y: 810.83), control2: CGPoint(x: 938.67, y: 798.84))
            wave2.addCurve(to: CGPoint(x: 1024.00, y: 741.86), control1: CGPoint(x: 981.33, y: 772.23), control2: CGPoint(x: 1002.67, y: 757.61))
            wave2.addCurve(to: CGPoint(x: 1088.00, y: 690.69), control1: CGPoint(x: 1045.33, y: 726.11), control2: CGPoint(x: 1066.67, y: 709.22))
            wave2.addCurve(to: CGPoint(x: 1152.00, y: 629.96), control1: CGPoint(x: 1109.33, y: 672.15), control2: CGPoint(x: 1130.67, y: 651.96))
            wave2.addCurve(to: CGPoint(x: 1216.00, y: 558.54), control1: CGPoint(x: 1173.33, y: 607.95), control2: CGPoint(x: 1194.67, y: 584.14))
            wave2.addCurve(to: CGPoint(x: 1280.00, y: 477.75), control1: CGPoint(x: 1237.33, y: 532.93), control2: CGPoint(x: 1258.67, y: 505.54))
            wave2.addCurve(to: CGPoint(x: 1344.00, y: 394.65), control1: CGPoint(x: 1301.33, y: 449.96), control2: CGPoint(x: 1322.67, y: 421.77))
            wave2.addCurve(to: CGPoint(x: 1408.00, y: 316.93), control1: CGPoint(x: 1365.33, y: 367.52), control2: CGPoint(x: 1386.67, y: 341.45))
            wave2.addCurve(to: CGPoint(x: 1472.00, y: 248.00), control1: CGPoint(x: 1429.33, y: 292.41), control2: CGPoint(x: 1450.67, y: 269.44))
            wave2.addCurve(to: CGPoint(x: 1536.00, y: 187.94), control1: CGPoint(x: 1493.33, y: 226.56), control2: CGPoint(x: 1514.67, y: 206.66))
            wave2.addCurve(to: CGPoint(x: 1600.00, y: 135.08), control1: CGPoint(x: 1557.33, y: 169.22), control2: CGPoint(x: 1578.67, y: 151.69))
            wave2.addCurve(to: CGPoint(x: 1664.00, y: 88.25), control1: CGPoint(x: 1621.33, y: 118.46), control2: CGPoint(x: 1642.67, y: 102.76))
            wave2.addCurve(to: CGPoint(x: 1728.00, y: 46.32), control1: CGPoint(x: 1685.33, y: 73.75), control2: CGPoint(x: 1706.67, y: 60.43))
            wave2.addCurve(to: CGPoint(x: 1792.00, y: 9.35), control1: CGPoint(x: 1749.33, y: 32.21), control2: CGPoint(x: 1770.67, y: 17.31))
            wave2.addCurve(to: CGPoint(x: 1856.00, y: 0.00), control1: CGPoint(x: 1813.33, y: 1.39), control2: CGPoint(x: 1834.67, y: 0.37))
            wave2.addCurve(to: CGPoint(x: 1920.00, y: 0.00), control1: CGPoint(x: 1877.33, y: -0.37), control2: CGPoint(x: 1898.67, y: -0.11))
            wave2.addCurve(to: CGPoint(x: 1984.00, y: 0.00), control1: CGPoint(x: 1941.33, y: 0.11), control2: CGPoint(x: 1962.67, y: 0.05))
            wave2.addCurve(to: CGPoint(x: 2047.00, y: -0.00), control1: CGPoint(x: 2005.00, y: -0.05), control2: CGPoint(x: 2026.00, y: -0.10))
            wave2.addLine(to: CGPoint(x: 2048, y: 477.65))
            wave2.addLine(to: CGPoint(x: 2047, y: 477.65))
            wave2.addCurve(to: CGPoint(x: 1984.00, y: 507.47), control1: CGPoint(x: 2026.00, y: 486.05), control2: CGPoint(x: 2005.00, y: 496.06))
            wave2.addCurve(to: CGPoint(x: 1920.00, y: 546.38), control1: CGPoint(x: 1962.67, y: 519.06), control2: CGPoint(x: 1941.33, y: 532.11))
            wave2.addCurve(to: CGPoint(x: 1856.00, y: 592.64), control1: CGPoint(x: 1898.67, y: 560.66), control2: CGPoint(x: 1877.33, y: 576.17))
            wave2.addCurve(to: CGPoint(x: 1792.00, y: 645.07), control1: CGPoint(x: 1834.67, y: 609.11), control2: CGPoint(x: 1813.33, y: 626.54))
            wave2.addCurve(to: CGPoint(x: 1728.00, y: 704.04), control1: CGPoint(x: 1770.67, y: 663.59), control2: CGPoint(x: 1749.33, y: 683.20))
            wave2.addCurve(to: CGPoint(x: 1664.00, y: 770.23), control1: CGPoint(x: 1706.67, y: 724.89), control2: CGPoint(x: 1685.33, y: 746.98))
            wave2.addCurve(to: CGPoint(x: 1600.00, y: 842.22), control1: CGPoint(x: 1642.67, y: 793.47), control2: CGPoint(x: 1621.33, y: 817.87))
            wave2.addCurve(to: CGPoint(x: 1536.00, y: 913.28), control1: CGPoint(x: 1578.67, y: 866.56), control2: CGPoint(x: 1557.33, y: 890.84))
            wave2.addCurve(to: CGPoint(x: 1472.00, y: 974.53), control1: CGPoint(x: 1514.67, y: 935.71), control2: CGPoint(x: 1493.33, y: 956.29))
            wave2.addCurve(to: CGPoint(x: 1408.00, y: 1022.60), control1: CGPoint(x: 1450.67, y: 992.78), control2: CGPoint(x: 1429.33, y: 1008.69))
            wave2.addCurve(to: CGPoint(x: 1344.00, y: 1059.27), control1: CGPoint(x: 1386.67, y: 1036.52), control2: CGPoint(x: 1365.33, y: 1048.44))
            wave2.addCurve(to: CGPoint(x: 1280.00, y: 1088.34), control1: CGPoint(x: 1322.67, y: 1070.09), control2: CGPoint(x: 1301.33, y: 1079.82))
            wave2.addCurve(to: CGPoint(x: 1216.00, y: 1110.45), control1: CGPoint(x: 1258.67, y: 1096.86), control2: CGPoint(x: 1237.33, y: 1104.17))
            wave2.addCurve(to: CGPoint(x: 1152.00, y: 1126.66), control1: CGPoint(x: 1194.67, y: 1116.72), control2: CGPoint(x: 1173.33, y: 1121.96))
            wave2.addCurve(to: CGPoint(x: 1088.00, y: 1139.27), control1: CGPoint(x: 1130.67, y: 1131.36), control2: CGPoint(x: 1109.33, y: 1135.52))
            wave2.addCurve(to: CGPoint(x: 1024.00, y: 1150.02), control1: CGPoint(x: 1066.67, y: 1143.03), control2: CGPoint(x: 1045.33, y: 1146.38))
            wave2.addCurve(to: CGPoint(x: 960.00, y: 1161.83), control1: CGPoint(x: 1002.67, y: 1153.65), control2: CGPoint(x: 981.33, y: 1157.57))
            wave2.addCurve(to: CGPoint(x: 896.00, y: 1175.88), control1: CGPoint(x: 938.67, y: 1166.08), control2: CGPoint(x: 917.33, y: 1170.69))
            wave2.addCurve(to: CGPoint(x: 832.00, y: 1193.13), control1: CGPoint(x: 874.67, y: 1181.07), control2: CGPoint(x: 853.33, y: 1186.84))
            wave2.addCurve(to: CGPoint(x: 768.00, y: 1213.83), control1: CGPoint(x: 810.67, y: 1199.41), control2: CGPoint(x: 789.33, y: 1206.21))
            wave2.addCurve(to: CGPoint(x: 704.00, y: 1239.15), control1: CGPoint(x: 746.67, y: 1221.46), control2: CGPoint(x: 725.33, y: 1229.90))
            wave2.addCurve(to: CGPoint(x: 640.00, y: 1269.46), control1: CGPoint(x: 682.67, y: 1248.41), control2: CGPoint(x: 661.33, y: 1258.46))
            wave2.addCurve(to: CGPoint(x: 576.00, y: 1305.20), control1: CGPoint(x: 618.67, y: 1280.46), control2: CGPoint(x: 597.33, y: 1292.40))
            wave2.addCurve(to: CGPoint(x: 512.00, y: 1346.33), control1: CGPoint(x: 554.67, y: 1318.00), control2: CGPoint(x: 533.33, y: 1331.67))
            wave2.addCurve(to: CGPoint(x: 448.00, y: 1393.17), control1: CGPoint(x: 490.67, y: 1360.98), control2: CGPoint(x: 469.33, y: 1376.63))
            wave2.addCurve(to: CGPoint(x: 384.00, y: 1445.17), control1: CGPoint(x: 426.67, y: 1409.70), control2: CGPoint(x: 405.33, y: 1427.13))
            wave2.addCurve(to: CGPoint(x: 320.00, y: 1500.78), control1: CGPoint(x: 362.67, y: 1463.20), control2: CGPoint(x: 341.33, y: 1481.85))
            wave2.addCurve(to: CGPoint(x: 256.00, y: 1557.51), control1: CGPoint(x: 298.67, y: 1519.72), control2: CGPoint(x: 277.33, y: 1538.95))
            wave2.addCurve(to: CGPoint(x: 192.00, y: 1610.54), control1: CGPoint(x: 234.67, y: 1576.08), control2: CGPoint(x: 213.33, y: 1593.97))
            wave2.addCurve(to: CGPoint(x: 128.00, y: 1655.92), control1: CGPoint(x: 170.67, y: 1627.11), control2: CGPoint(x: 149.33, y: 1642.35))
            wave2.addCurve(to: CGPoint(x: 64.00, y: 1691.38), control1: CGPoint(x: 106.67, y: 1669.49), control2: CGPoint(x: 85.33, y: 1681.40))
            wave2.addCurve(to: CGPoint(x: 0.00, y: 1715.22), control1: CGPoint(x: 42.67, y: 1701.35), control2: CGPoint(x: 21.33, y: 1709.39))
            wave2.closeSubpath()
            context.fill(wave2.applying(transform), with: .color(Color(red: 0.3254901960784314, green: 0.9686274509803922, blue: 0.7803921568627451)))
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

#Preview {
    ContentView()
}

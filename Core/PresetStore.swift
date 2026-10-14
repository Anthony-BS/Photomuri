import Foundation
import Combine

struct PresetSettings: Codable, Equatable {
    var renameFiles: Bool
    var renameTemplate: String
    var createEfficientVersion: Bool
    var efficientImageFormat: String
    var quality: String
    var reviewTimeZone: Bool
    var updateCaptureMetadata: Bool
    var preserveOriginals: Bool
    var timeZoneIdentifier: String
    // Optional on disk so presets from earlier builds remain readable.
    var applyDaylightSavingTime: Bool? = true
    var usesDaylightSavingTime: Bool { applyDaylightSavingTime ?? true }
    // Optional for backward compatibility. Obsolete performanceMode JSON is
    // ignored; old presets keep their other settings and start at 4/4.
    var renameWorkers: Int? = nil
    var conversionWorkers: Int? = nil
    var requestedRenameWorkers: Int { renameWorkers ?? WorkerConcurrency.defaultCount }
    var requestedConversionWorkers: Int { conversionWorkers ?? WorkerConcurrency.defaultCount }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.renameFiles == rhs.renameFiles && lhs.renameTemplate == rhs.renameTemplate &&
        lhs.createEfficientVersion == rhs.createEfficientVersion &&
        lhs.efficientImageFormat == rhs.efficientImageFormat && lhs.quality == rhs.quality &&
        lhs.reviewTimeZone == rhs.reviewTimeZone &&
        lhs.updateCaptureMetadata == rhs.updateCaptureMetadata &&
        lhs.preserveOriginals == rhs.preserveOriginals &&
        lhs.timeZoneIdentifier == rhs.timeZoneIdentifier &&
        lhs.usesDaylightSavingTime == rhs.usesDaylightSavingTime &&
        lhs.requestedRenameWorkers == rhs.requestedRenameWorkers &&
        lhs.requestedConversionWorkers == rhs.requestedConversionWorkers
    }

    static func defaults(timeZone: TimeZone = .current) -> Self {
        Self(renameFiles: true, renameTemplate: "YYMMDD_hhmmss [original]",
             createEfficientVersion: true, efficientImageFormat: "heic", quality: "85",
             reviewTimeZone: true, updateCaptureMetadata: true, preserveOriginals: false,
             timeZoneIdentifier: timeZone.identifier)
    }
}

struct SettingsPreset: Codable, Identifiable, Equatable {
    static let defaultID = "default"
    let id: String
    var name: String
    var settings: PresetSettings
    var isDefault: Bool { id == Self.defaultID }
}

enum PresetError: LocalizedError {
    case emptyName, duplicateName, protectedDefault, missingPreset, unreadableStorage
    var errorDescription: String? {
        switch self {
        case .emptyName: return "Enter a preset name."
        case .duplicateName: return "This preset name is already in use. Enter a different name."
        case .protectedDefault: return "The Default preset cannot be modified or deleted."
        case .missingPreset: return "The preset could not be found."
        case .unreadableStorage: return "Saved presets could not be read. Saving and management are disabled to protect the existing data."
        }
    }
}

@MainActor
final class PresetStore: ObservableObject {
    @Published private(set) var saved: [SettingsPreset] = []
    @Published private(set) var storageError: String?
    private let defaults: UserDefaults
    private let defaultSettings: PresetSettings
    private static let storageKey = "settings.presets.v1"

    init(defaults: UserDefaults = .standard, timeZone: TimeZone = .current) {
        self.defaults = defaults
        self.defaultSettings = .defaults(timeZone: timeZone)
        if let data = defaults.data(forKey: Self.storageKey) {
            do {
                let decoded = try JSONDecoder().decode([SettingsPreset].self, from: data)
                var ids = Set<String>()
                var names = Set<String>(["default"])
                for preset in decoded {
                    guard !preset.isDefault, !preset.id.isEmpty,
                          ids.insert(preset.id).inserted,
                          !preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          names.insert(Self.nameKey(preset.name)).inserted else {
                        throw PresetError.unreadableStorage
                    }
                }
                saved = decoded
            } catch { storageError = PresetError.unreadableStorage.localizedDescription }
        }
    }

    var all: [SettingsPreset] {
        [SettingsPreset(id: SettingsPreset.defaultID, name: "Default", settings: defaultSettings)] + saved
    }

    func matchingID(for settings: PresetSettings, preferredID: String) -> String {
        if let preferred = all.first(where: { $0.id == preferredID && $0.settings == settings }) {
            return preferred.id
        }
        return all.first(where: { $0.settings == settings })?.id ?? ""
    }

    func nameError(_ name: String, excluding id: String? = nil) -> String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return PresetError.emptyName.localizedDescription
        }
        if all.contains(where: { $0.id != id && Self.nameKey($0.name) == Self.nameKey(name) }) {
            return PresetError.duplicateName.localizedDescription
        }
        return nil
    }

    @discardableResult
    func saveNew(name: String, settings: PresetSettings) throws -> String {
        try validate(name)
        let preset = SettingsPreset(id: UUID().uuidString,
                                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                    settings: settings)
        try persist(saved + [preset])
        return preset.id
    }

    func update(id: String, name: String, settings: PresetSettings) throws {
        guard id != SettingsPreset.defaultID else { throw PresetError.protectedDefault }
        guard let index = saved.firstIndex(where: { $0.id == id }) else { throw PresetError.missingPreset }
        try validate(name, excluding: id)
        var updated = saved
        updated[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated[index].settings = settings
        try persist(updated)
    }

    func rename(id: String, name: String) throws {
        guard id != SettingsPreset.defaultID else { throw PresetError.protectedDefault }
        guard let preset = saved.first(where: { $0.id == id }) else { throw PresetError.missingPreset }
        try update(id: id, name: name, settings: preset.settings)
    }

    func delete(id: String) throws {
        guard id != SettingsPreset.defaultID else { throw PresetError.protectedDefault }
        guard saved.contains(where: { $0.id == id }) else { throw PresetError.missingPreset }
        try persist(saved.filter { $0.id != id })
    }

    private func validate(_ name: String, excluding id: String? = nil) throws {
        guard storageError == nil else { throw PresetError.unreadableStorage }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PresetError.emptyName }
        guard nameError(name, excluding: id) == nil else { throw PresetError.duplicateName }
    }

    private func persist(_ presets: [SettingsPreset]) throws {
        guard storageError == nil else { throw PresetError.unreadableStorage }
        let data = try JSONEncoder().encode(presets)
        defaults.set(data, forKey: Self.storageKey)
        saved = presets
    }

    private static func nameKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

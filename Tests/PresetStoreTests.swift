import Foundation

@main
struct PresetStoreTests {
    @MainActor
    static func main() throws {
        let suite = "Photomuri.PresetTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let zone = TimeZone(identifier: "Asia/Seoul")!
        let store = PresetStore(defaults: defaults, timeZone: zone)
        let initial = PresetSettings.defaults(timeZone: zone)
        assert(!initial.preserveOriginals && initial.quality == "85")
        assert(initial.requestedRenameWorkers == 4 && initial.requestedConversionWorkers == 4)
        assert(initial.renameTemplate == "YYMMDD_hhmmss [original]" && initial.efficientImageFormat == "heic")
        assert(store.all.count == 1 && store.all[0].isDefault)
        assert(store.matchingID(for: initial, preferredID: "") == SettingsPreset.defaultID)
        print("PASS: fresh settings match immutable Default")

        let first = try store.saveNew(name: "  여행  ", settings: initial)
        assert(store.saved[0].name == "여행")
        assert(store.matchingID(for: initial, preferredID: first) == first)
        var edited = initial
        edited.quality = "91"
        edited.renameTemplate = #"YYMMDD_[s5]_"abc""#
        edited.efficientImageFormat = "avif"
        edited.preserveOriginals = true
        edited.reviewTimeZone = false
        edited.updateCaptureMetadata = false
        edited.timeZoneIdentifier = "Europe/Lisbon"
        edited.renameFiles = false
        edited.createEfficientVersion = false
        edited.renameWorkers = 2
        edited.conversionWorkers = 7
        assert(store.matchingID(for: edited, preferredID: first).isEmpty)
        try store.update(id: first, name: "여행", settings: edited)
        assert(store.matchingID(for: edited, preferredID: first) == first)
        let second = try store.saveNew(name: "여행 복사", settings: edited)
        assert(store.saved.count == 2)
        assert(store.matchingID(for: edited, preferredID: second) == second)
        print("PASS: create, same-settings copy, blank dirty menu, overwrite, all option fields")

        try store.rename(id: first, name: "유럽 여행")
        assert(store.saved[0].name == "유럽 여행" && store.saved[0].settings == edited)
        let reloaded = PresetStore(defaults: defaults, timeZone: zone)
        assert(reloaded.saved == store.saved)
        assert(reloaded.matchingID(for: edited, preferredID: second) == second)
        var unsaved = edited
        unsaved.quality = "42"
        assert(reloaded.matchingID(for: unsaved, preferredID: second).isEmpty)
        print("PASS: rename retains settings, reload retains presets, unsaved settings show blank")

        for action in [
            { try store.delete(id: SettingsPreset.defaultID) },
            { try store.rename(id: SettingsPreset.defaultID, name: "Changed") },
            { try store.update(id: SettingsPreset.defaultID, name: "Changed", settings: edited) }
        ] {
            do { try action(); fatalError("Default mutated") }
            catch PresetError.protectedDefault {}
        }
        do { _ = try store.saveNew(name: "DEFAULT", settings: initial); fatalError("reserved name accepted") }
        catch PresetError.duplicateName {}
        do { _ = try store.saveNew(name: "  ", settings: initial); fatalError("empty name accepted") }
        catch PresetError.emptyName {}
        do { try store.rename(id: first, name: "여행 복사"); fatalError("duplicate accepted") }
        catch PresetError.duplicateName {}
        try store.delete(id: second)
        try store.delete(id: first)
        assert(store.saved.isEmpty && store.all.count == 1)
        assert(store.matchingID(for: edited, preferredID: first).isEmpty)
        assert(PresetStore(defaults: defaults, timeZone: zone).saved.isEmpty)
        print("PASS: protected Default, duplicate/empty validation, deletion, stale selection")

        // Older presets contain an obsolete backup option. Codable must ignore
        // that unknown key, keeping every remaining setting and preferred ID.
        let legacyID = "legacy-preset"
        for removedValue in [true, false] {
            var oldSettings = try JSONSerialization.jsonObject(with: JSONEncoder().encode(edited)) as! [String: Any]
            oldSettings["failSafe"] = removedValue
            let oldPresets: [[String: Any]] = [["id": legacyID, "name": "Existing Preset", "settings": oldSettings]]
            defaults.set(try JSONSerialization.data(withJSONObject: oldPresets), forKey: "settings.presets.v1")
            let migrated = PresetStore(defaults: defaults, timeZone: zone)
            assert(migrated.storageError == nil && migrated.saved.count == 1)
            assert(migrated.saved[0].settings == edited)
            assert(migrated.matchingID(for: edited, preferredID: legacyID) == legacyID)
            try migrated.update(id: legacyID, name: "Existing Preset", settings: edited)
            let rewritten = try JSONSerialization.jsonObject(with: defaults.data(forKey: "settings.presets.v1")!) as! [[String: Any]]
            assert((rewritten[0]["settings"] as! [String: Any])["failSafe"] == nil)
        }
        print("PASS: old presets retain remaining settings and selection; rewritten data excludes removed option")

        var beforePerformance = try JSONSerialization.jsonObject(with: JSONEncoder().encode(edited)) as! [String: Any]
        beforePerformance.removeValue(forKey: "renameWorkers")
        beforePerformance.removeValue(forKey: "conversionWorkers")
        beforePerformance["performanceMode"] = "boost"
        let decodedOld = try JSONDecoder().decode(PresetSettings.self, from: JSONSerialization.data(withJSONObject: beforePerformance))
        assert(decodedOld.requestedRenameWorkers == 4 && decodedOld.requestedConversionWorkers == 4)
        var expectedOld = edited
        expectedOld.renameWorkers = 4
        expectedOld.conversionWorkers = 4
        assert(decodedOld == expectedOld)
        for legacyMode in ["eco", "standard", "boost", "future-unknown"] {
            beforePerformance["performanceMode"] = legacyMode
            let legacy = try JSONDecoder().decode(PresetSettings.self, from: JSONSerialization.data(withJSONObject: beforePerformance))
            assert(legacy == expectedOld)
            let rewritten = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
            assert(rewritten["performanceMode"] == nil)
        }
        for (rename, convert) in [(1, 1), (4, 4), (4, 10), (6, 10), (32, 32)] {
            var value = initial
            value.renameWorkers = rename
            value.conversionWorkers = convert
            let data = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(PresetSettings.self, from: data)
            assert(decoded.requestedRenameWorkers == rename && decoded.requestedConversionWorkers == convert && decoded == value)
        }
        for cores in [0, 1, 2, 4, 6, 8, 10, 12, 16, 32] {
            let available = max(cores, 1)
            for requested in [Int.min, -1, 0, 1, 2, 4, 6, 10, 32, Int.max] {
                assert(WorkerConcurrency.limit(requested, activeProcessorCount: cores) == min(max(requested, 1), available))
            }
        }
        assert(WorkerConcurrency.normalizedInput("0", activeProcessorCount: 10) == "1")
        assert(WorkerConcurrency.normalizedInput("-4", activeProcessorCount: 10) == "1")
        assert(WorkerConcurrency.normalizedInput("999", activeProcessorCount: 10) == "10")
        assert(WorkerConcurrency.normalizedInput(String(repeating: "9", count: 100), activeProcessorCount: 10) == "10")
        assert(WorkerConcurrency.normalizedInput("-" + String(repeating: "9", count: 100), activeProcessorCount: 10) == "1")
        assert(WorkerConcurrency.normalizedInput(" 06 ", activeProcessorCount: 10) == "6")
        for text in ["", "abc", "1.5", "-", "4e2"] {
            assert(WorkerConcurrency.validatedCount(text, activeProcessorCount: 10) == nil)
        }
        assert(WorkerConcurrency.validatedCount("0", activeProcessorCount: 10) == nil)
        assert(WorkerConcurrency.validatedCount("11", activeProcessorCount: 10) == nil)
        assert(WorkerConcurrency.validatedCount("10", activeProcessorCount: 10) == 10)
        var other = initial
        other.renameWorkers = 2
        assert(store.matchingID(for: other, preferredID: "default").isEmpty)
        other = initial
        other.conversionWorkers = 2
        assert(store.matchingID(for: other, preferredID: "default").isEmpty)
        print("PASS: default 4/4, independent workers saved and matched, legacy modes ignored, CPU caps 1–32, integer/overflow/invalid input checks")

        defaults.set(Data("not JSON".utf8), forKey: "settings.presets.v1")
        let damaged = PresetStore(defaults: defaults, timeZone: zone)
        assert(damaged.storageError != nil)
        do { _ = try damaged.saveNew(name: "Test", settings: initial); fatalError("corrupt data overwritten") }
        catch PresetError.unreadableStorage {}
        assert(defaults.data(forKey: "settings.presets.v1") == Data("not JSON".utf8))
        print("PASS: unreadable storage is protected from overwrite")
    }
}

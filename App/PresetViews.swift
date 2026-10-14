import SwiftUI

struct SavePresetView: View {
    @ObservedObject var store: PresetStore
    let currentPreset: SettingsPreset?
    let settings: PresetSettings
    let onSaved: (String) -> Void
    let onCancel: () -> Void
    @State private var name: String
    @State private var errorMessage: String?
    @FocusState private var nameFocused: Bool

    init(store: PresetStore, currentPreset: SettingsPreset?, settings: PresetSettings,
         onSaved: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.store = store
        self.currentPreset = currentPreset
        self.settings = settings
        self.onSaved = onSaved
        self.onCancel = onCancel
        _name = State(initialValue: currentPreset?.isDefault == false ? currentPreset!.name : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Enter a Preset Name").font(.headline)
            if let currentPreset, !currentPreset.isDefault {
                Text("Current Preset: \(currentPreset.name)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextField("Preset Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
            if let message = errorMessage ?? store.storageError {
                Text(message).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Update Current Preset") { saveCurrent() }
                    .disabled(currentPreset == nil || currentPreset?.isDefault == true
                              || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || store.storageError != nil)
                Button("Save as New Preset") { saveNew() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || store.storageError != nil)
            }
        }
        .padding(24)
        .frame(width: 530)
        .onAppear { nameFocused = true }
    }

    private func saveCurrent() {
        guard let preset = currentPreset else { return }
        do {
            try store.update(id: preset.id, name: name, settings: settings)
            onSaved(preset.id)
        } catch { errorMessage = error.localizedDescription }
    }
    private func saveNew() {
        do { onSaved(try store.saveNew(name: name, settings: settings)) }
        catch { errorMessage = error.localizedDescription }
    }
}

struct ManagePresetsView: View {
    @ObservedObject var store: PresetStore
    let onClose: () -> Void
    @State private var selection: String?
    @State private var renameTarget: SettingsPreset?
    @State private var errorMessage: String?

    init(store: PresetStore, selectedID: String, onClose: @escaping () -> Void) {
        self.store = store
        self.onClose = onClose
        _selection = State(initialValue: selectedID.isEmpty ? SettingsPreset.defaultID : selectedID)
    }

    private var selected: SettingsPreset? { store.all.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Manage Presets").font(.headline)
            List(selection: $selection) {
                ForEach(store.all) { preset in
                    HStack {
                        Text(preset.name)
                        Spacer()
                        if preset.isDefault {
                            Image(systemName: "lock.fill").foregroundStyle(.secondary)
                        }
                    }
                    .tag(preset.id)
                }
            }
            .listStyle(.bordered)
            .alternatingRowBackgrounds(.enabled)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .windowBackgroundColor))
            .frame(height: 210)
            if let message = errorMessage ?? store.storageError {
                Text(message).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Rename") { renameTarget = selected }
                    .disabled(selected == nil || selected?.isDefault == true || store.storageError != nil)
                Button("Delete") { deleteSelected() }
                    .disabled(selected == nil || selected?.isDefault == true || store.storageError != nil)
                Spacer()
                Button("Close", action: onClose).keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 430)
        .sheet(item: $renameTarget) { preset in
            RenamePresetView(store: store, preset: preset) { renameTarget = nil }
        }
    }

    private func deleteSelected() {
        guard let preset = selected else { return }
        do {
            try store.delete(id: preset.id)
            selection = SettingsPreset.defaultID
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct RenamePresetView: View {
    @ObservedObject var store: PresetStore
    let preset: SettingsPreset
    let onClose: () -> Void
    @State private var name: String
    @State private var errorMessage: String?
    @FocusState private var nameFocused: Bool

    init(store: PresetStore, preset: SettingsPreset, onClose: @escaping () -> Void) {
        self.store = store
        self.preset = preset
        self.onClose = onClose
        _name = State(initialValue: preset.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Preset").font(.headline)
            TextField("Preset Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Rename") {
                    do {
                        try store.rename(id: preset.id, name: name)
                        onClose()
                    } catch { errorMessage = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
        .onAppear { nameFocused = true }
    }
}

import SwiftUI
import Observation
import MsNotesCore

/// The settings form's own state, loaded from the store when the view opens and
/// written back on Save. Nothing is applied as you type: half-typed API keys and
/// preset prompts should not take effect.
@MainActor
@Observable
final class SettingsFormModel {
    var vaultPath = ""
    var assemblyKey = ""
    var anthropicKey = ""
    var keyTerms = ""
    var minuteCap = ""
    var autoEndEnabled = true
    var callApps = ""
    var presets: [Preset] = []
    var editingPreset = ""

    var editingPromptIndex: Int? {
        presets.firstIndex { $0.name == editingPreset }
    }

    func load(from state: AppState) {
        let settings = state.settings
        vaultPath = settings.vaultPath ?? ""
        // Keys are never read back out of the Keychain to fill these in: doing
        // so would put secrets on screen and prompt for Keychain consent every
        // time settings opened. Blank means "leave whatever is stored".
        assemblyKey = ""
        anthropicKey = ""
        keyTerms = settings.keyTerms.joined(separator: "\n")
        minuteCap = "\(settings.monthlyMinuteCap)"
        autoEndEnabled = settings.autoEndEnabled
        callApps = settings.callAppBundleIDs.joined(separator: "\n")
        presets = settings.presets
        editingPreset = presets.first?.name ?? ""
    }

    func save(to state: AppState) {
        let settings = state.settings
        let path = vaultPath.trimmingCharacters(in: .whitespaces)
        settings.vaultPath = path.isEmpty ? nil : path
        if !assemblyKey.isEmpty {
            try? settings.keychain.set(assemblyKey, for: .assemblyAI)
        }
        if !anthropicKey.isEmpty {
            try? settings.keychain.set(anthropicKey, for: .anthropic)
        }
        settings.keyTerms = lines(keyTerms)
        if let cap = Int(minuteCap.trimmingCharacters(in: .whitespaces)), cap > 0 {
            settings.monthlyMinuteCap = cap
        }
        settings.autoEndEnabled = autoEndEnabled
        let apps = lines(callApps)
        if !apps.isEmpty { settings.callAppBundleIDs = apps }
        settings.presets = presets
    }

    private func lines(_ text: String) -> [String] {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

struct SettingsRoute: View {
    let state: AppState
    let model: SessionsPanelModel
    let actions: PanelActions

    private var form: SettingsFormModel { model.settingsForm }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title: "Settings", back: { model.goToMain() }) {
                Button("Quit", action: actions.quit)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.faint)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    vault
                    keys
                    keyTerms
                    budget
                    autoEnd
                    presets
                    Text("Total spent so far: \(Format.money(state.settings.costTotalUSD))")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.faint)
                }
                .padding(.trailing, 2)
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: 380)

            Button(action: actions.saveSettings) {
                Text("Save")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Theme.accent,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(Theme.padding)
    }

    private var vault: some View {
        Field("Vault folder", note: "Notes here, transcripts in transcripts/") {
            HStack(spacing: 6) {
                TextField("", text: binding(\.vaultPath))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                Button("Choose…", action: actions.chooseVault)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
    }

    private var keys: some View {
        Field("API keys", note: state.keysConfigured
              ? "Stored in the Keychain. Leave blank to keep them."
              : "Needed before recording. Stored in the Keychain.") {
            VStack(spacing: 6) {
                SecureField("AssemblyAI key", text: binding(\.assemblyKey))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                SecureField("Anthropic key", text: binding(\.anthropicKey))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
            }
        }
    }

    private var keyTerms: some View {
        Field("Key terms",
              note: "Names and jargon the transcriber would not guess, one per line. Keep it tight; padding it makes accuracy worse.") {
            MultilineField(text: binding(\.keyTerms), height: 64)
        }
    }

    private var budget: some View {
        Field("Monthly budget",
              note: "Minutes per calendar month. Warns as you approach it, never blocks recording.") {
            HStack(spacing: 6) {
                TextField("600", text: binding(\.minuteCap))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .frame(width: 80)
                Text("minutes").font(.system(size: 11)).foregroundStyle(Theme.faint)
            }
        }
    }

    private var autoEnd: some View {
        Field("Stop automatically",
              note: "When a call app releases the microphone. Bundle IDs, one per line, matched as prefixes.") {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Stop 30s after the call ends", isOn: binding(\.autoEndEnabled))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text)
                MultilineField(text: binding(\.callApps), height: 58)
                    .opacity(form.autoEndEnabled ? 1 : 0.4)
                    .disabled(!form.autoEndEnabled)
            }
        }
    }

    private var presets: some View {
        Field("Presets", note: "The prompt that shapes each kind of note.") {
            VStack(alignment: .leading, spacing: 6) {
                Picker("", selection: binding(\.editingPreset)) {
                    ForEach(form.presets) { preset in
                        Text(preset.name).tag(preset.name)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                if let index = form.editingPromptIndex {
                    MultilineField(
                        text: Binding(get: { form.presets[index].prompt },
                                      set: { form.presets[index].prompt = $0 }),
                        height: 130)
                }
            }
        }
    }

    private func binding<Value>(_ keyPath: ReferenceWritableKeyPath<SettingsFormModel, Value>)
        -> Binding<Value> {
        Binding(get: { form[keyPath: keyPath] }, set: { form[keyPath: keyPath] = $0 })
    }
}

/// A labelled block: caption, explanation, then the control.
private struct Field<Content: View>: View {
    let label: String
    let note: String
    @ViewBuilder let content: () -> Content

    init(_ label: String, note: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.note = note
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(1)
                .foregroundStyle(Theme.accent)
            Text(note)
                .font(.system(size: 10))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
            content()
        }
    }
}

private struct MultilineField: View {
    let text: Binding<String>
    let height: CGFloat

    var body: some View {
        TextEditor(text: text)
            .font(.system(size: 10, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(4)
            .frame(height: height)
            .background(Color.black.opacity(0.28),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
    }
}

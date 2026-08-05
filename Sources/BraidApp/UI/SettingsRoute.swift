import SwiftUI
import AppKit
import Observation
import BraidCore

/// The settings form's own state, loaded from the store when the view opens and
/// written back on Save. Nothing is applied as you type: a half-typed preset
/// prompt should not take effect.
@MainActor
@Observable
final class SettingsFormModel {
    var vaultPath = ""
    var keyTerms = ""
    var autoEndEnabled = true
    var callApps = ""
    var presets: [Preset] = []
    /// Which Preset every Session uses. Chosen here rather than at Start.
    var defaultPreset = ""
    /// Which Preset's prompt the editor is showing, which is usually but not
    /// always the default one.
    var editingPreset = ""
    var localEngine: LocalEngine = .apple
    var holdForNames = false
    var summaryEngine: SummaryEngine = .appleBuiltIn

    static func summaryNote(for engine: SummaryEngine) -> String {
        switch engine {
        case .appleBuiltIn: "On this Mac. Free, but slow on long calls and refuses some subjects."
        case .openWeights: "On this Mac. Refuses nothing, 2.3GB, and very slow on 8GB."
        case .cloud: "Seconds instead of minutes, and reads a whole meeting in one pass."
        }
    }
    /// Which groups are open. Held here rather than in `@State` so the views
    /// stay pure functions of a model (ADR-0004), and so reopening Settings
    /// does not fold everything up again mid-task.
    var expanded: Set<String> = []
    /// Only the prompt editor, which is long, ugly and rarely wanted.
    var showingPrompt = false

    var editingPromptIndex: Int? {
        presets.firstIndex { $0.name == editingPreset }
    }

    func load(from state: AppState) {
        let settings = state.settings
        vaultPath = settings.vaultPath ?? ""
        keyTerms = settings.keyTerms.joined(separator: "\n")
        autoEndEnabled = settings.autoEndEnabled
        callApps = settings.callAppBundleIDs.joined(separator: "\n")
        presets = settings.presets
        defaultPreset = settings.defaultPresetName
        editingPreset = defaultPreset
        localEngine = settings.localEngine
        holdForNames = settings.delivery == .held
        summaryEngine = settings.summaryEngine
    }

    func save(to state: AppState) {
        let settings = state.settings
        let path = vaultPath.trimmingCharacters(in: .whitespaces)
        settings.vaultPath = path.isEmpty ? nil : path
        settings.keyTerms = lines(keyTerms)
        settings.autoEndEnabled = autoEndEnabled
        let apps = lines(callApps)
        if !apps.isEmpty { settings.callAppBundleIDs = apps }
        settings.presets = presets
        settings.defaultPresetName = defaultPreset
        settings.delivery = holdForNames ? .held : .immediate
        let engineChanged = settings.localEngine != localEngine
            || settings.summaryEngine != summaryEngine
        settings.localEngine = localEngine
        settings.summaryEngine = summaryEngine
        if engineChanged {
            state.applyEngineSettings()
            // Fetch the models now rather than making the next Session wait.
            state.prepareLocalModels()
        }
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

    /// Never holds the stored key — only what is being typed on the way in.
    /// Cleared the moment it is saved, so the panel is not a place a key sits.
    @State private var cloudKeyDraft = ""

    private var form: SettingsFormModel { model.settingsForm }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title: "Settings", back: { model.goToMain() }) {
                Button("Quit", action: actions.quit)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.faint)
            }

            // One visible setting and five drawers. Everything below Vault is
            // something you set once, so showing it all at once made a wall of
            // controls that had to be read to be navigated.
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    vault
                    SettingsGroup(title: "Notes", icon: "doc.text", form: form) { notes }
                    SettingsGroup(title: "Voices", icon: "person.wave.2", form: form) { people }
                    SettingsGroup(title: "Models", icon: "cpu", form: form) { models }
                    SettingsGroup(title: "Recording", icon: "record.circle", form: form) { recording }
                    Text("Everything happens on this Mac.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.faint)
                        .padding(.top, 2)
                }
                .padding(.trailing, 2)
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: 400)

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
        .onAppear { state.refreshPeople() }
    }

    /// The one thing Braid cannot work out for itself, so the one thing that
    /// is never behind a drawer.
    private var vault: some View {
        Field("Vault folder") {
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

    /// What a Note looks like and when it lands. The Preset moved here from the
    /// Start form: it is a standing preference, not a per-call decision.
    private var notes: some View {
        VStack(alignment: .leading, spacing: 10) {
            Field("Shape") {
                Picker("", selection: binding(\.defaultPreset)) {
                    ForEach(form.presets) { preset in
                        Text(preset.name).tag(preset.name)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .font(.system(size: 11))
                .onChange(of: form.defaultPreset) { _, new in form.editingPreset = new }
            }

            Toggle("Wait for speaker names", isOn: binding(\.holdForNames))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .foregroundStyle(Theme.text)
                .help("Hold the note back until you have named the voices Braid does not recognise. It never waits when it recognises everyone.")

            Disclosure(title: "Edit the prompt",
                       open: Binding(get: { form.showingPrompt },
                                     set: { form.showingPrompt = $0 })) {
                if let index = form.editingPromptIndex {
                    MultilineField(
                        text: Binding(get: { form.presets[index].prompt },
                                      set: { form.presets[index].prompt = $0 }),
                        height: 140)
                }
            }
        }
    }

    /// R29: the Voice Database is the user's to manage. Deliberately plain —
    /// every person, how much Braid has heard of them, and a way to remove any
    /// of it.
    private var people: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.knownPeople.isEmpty {
                Text("Nobody yet. Name a speaker once and Braid recognises them next time.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(state.knownPeople) { person in
                    HStack(spacing: 6) {
                        Text(person.name)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        Text("\(person.voiceprints.count)")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.faint)
                            .help("\(person.voiceprints.count) voice sample\(person.voiceprints.count == 1 ? "" : "s")")
                        Spacer(minLength: 4)
                        Button("Forget") { state.forgetPerson(id: person.id) }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.faint)
                    }
                }
            }
            HStack(spacing: 10) {
                Button("Export…", action: exportVoices)
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Button("Import…", action: importVoices)
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Spacer(minLength: 4)
                if !state.knownPeople.isEmpty {
                    Button("Forget all", action: confirmForgetEveryone)
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.recording)
                }
            }
        }
    }

    /// Who transcribes and who writes. Both choices are trade-offs rather than
    /// better-and-worse, so each keeps one line saying what it costs.
    private var models: some View {
        VStack(alignment: .leading, spacing: 10) {
            Field("Transcription", note: form.localEngine == .apple
                  ? "Takes key terms. Nothing to download."
                  : "Better on words. No key terms, 443MB.") {
                Picker("", selection: binding(\.localEngine)) {
                    ForEach(LocalEngine.allCases, id: \.self) { engine in
                        Text(engine.label).tag(engine)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .font(.system(size: 11))
            }

            Field("Summaries", note: SettingsFormModel.summaryNote(for: form.summaryEngine)) {
                // A menu, not segments. Three options do not fit side by side
                // at Theme.panelWidth, and a segmented control does not shrink
                // below its content — it overflows the panel and takes every
                // other row with it. The Preset picker above is a menu for the
                // same reason.
                Picker("", selection: binding(\.summaryEngine)) {
                    ForEach(SummaryEngine.allCases, id: \.self) { engine in
                        Text(engine.label).tag(engine)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(.system(size: 11))
            }

            // The one Engine whose input leaves the Mac says so here, every
            // time, rather than in a document nobody re-reads.
            if form.summaryEngine.isCloud {
                Label("""
                    Transcript text is sent to Google. Audio, voiceprints and \
                    voice clips never leave this Mac.
                    """, systemImage: "arrow.up.forward.app")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                if state.cloudTokensUsed > 0 {
                    Text(state.cloudUsageLine)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.faint)
                }
                Field("Gemini API key",
                      note: state.hasCloudKey
                        ? "Stored in this Mac's Keychain. Type a new one to replace it."
                        : "Required before the cloud can write a note.") {
                    // Stacked, not side by side: a field and two buttons in a row
                    // do not fit at Theme.panelWidth (see the note on it).
                    VStack(alignment: .leading, spacing: 6) {
                        SecureField("Paste a key", text: $cloudKeyDraft)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                            .frame(maxWidth: .infinity)
                        HStack(spacing: 6) {
                            Button("Save") {
                                state.setCloudKey(cloudKeyDraft)
                                cloudKeyDraft = ""
                            }
                            .font(.system(size: 11))
                            .disabled(cloudKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                            if state.hasCloudKey {
                                Button("Remove") {
                                    state.setCloudKey("")
                                    cloudKeyDraft = ""
                                }
                                .font(.system(size: 11))
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }

            if let progress = state.modelDownload {
                Text(progress)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.accent)
            }
            ForEach([state.localModelError, state.summariserProblem].compactMap { $0 },
                    id: \.self) { problem in
                Text(problem)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Field("Key terms", note: "Names and jargon, one per line.") {
                MultilineField(text: binding(\.keyTerms), height: 60)
            }
        }
    }

    private var recording: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Stop 30s after the call ends", isOn: binding(\.autoEndEnabled))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .foregroundStyle(Theme.text)
            Field("Call apps", note: "Bundle IDs, one per line.") {
                MultilineField(text: binding(\.callApps), height: 56)
                    .opacity(form.autoEndEnabled ? 1 : 0.4)
                    .disabled(!form.autoEndEnabled)
            }
        }
    }

    // MARK: - Voice database actions

    private func exportVoices() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "braid-voices.json"
        panel.message = "This file is readable. It contains voice data for everyone Braid knows."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.exportVoices(to: url)
    }

    private func importVoices() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Replaces everyone Braid currently knows."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.importVoices(from: url)
    }

    private func confirmForgetEveryone() {
        let alert = NSAlert()
        alert.messageText = "Forget every voice?"
        alert.informativeText = """
            Braid will stop recognising everyone and will not be able to read \
            what it has stored. Notes you already have keep their names.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Forget everyone")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        state.forgetEveryone()
    }

    private func binding<Value>(_ keyPath: ReferenceWritableKeyPath<SettingsFormModel, Value>)
        -> Binding<Value> {
        Binding(get: { form[keyPath: keyPath] }, set: { form[keyPath: keyPath] = $0 })
    }
}

/// A labelled block: caption, an optional line of explanation, then the control.
///
/// The note is optional now and most callers skip it. Settings had a paragraph
/// under every control, which is fine to read once and noise every time after
/// — anything that was worth keeping moved into a `.help` tooltip, and anything
/// that was not is gone.
private struct Field<Content: View>: View {
    let label: String
    let note: String?
    @ViewBuilder let content: () -> Content

    init(_ label: String, note: String? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.note = note
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(1)
                .foregroundStyle(Theme.accent)
            content()
            if let note {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A named drawer. Closed, it is one row; open, it holds a section of Settings.
///
/// Expansion lives on the form model rather than in `@State`, keyed by title,
/// which keeps the view a pure function of its model and means the drawer you
/// were working in is still open when you come back from a file picker.
private struct SettingsGroup<Content: View>: View {
    let title: String
    let icon: String
    let form: SettingsFormModel
    @ViewBuilder let content: () -> Content

    private var isOpen: Bool { form.expanded.contains(title) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                if isOpen { form.expanded.remove(title) } else { form.expanded.insert(title) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 14)
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.faint)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen { content() }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card,
                    in: RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
    }
}

/// The same idea one level down, for a single long control inside a group.
private struct Disclosure<Content: View>: View {
    let title: String
    let open: Binding<Bool>
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { open.wrappedValue.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(open.wrappedValue ? 90 : 0))
                    Text(title).font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(Theme.faint)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open.wrappedValue { content() }
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

import AppKit
import MsNotesCore

/// Settings window: Vault path, API keys (Keychain only, R13), Key Terms,
/// Presets (R12), running cost total (R14).
@MainActor
final class SettingsWindowController: NSObject {
    let state: AppState
    private var window: NSWindow?

    private let vaultField = NSTextField()
    private let assemblyField = NSSecureTextField()
    private let anthropicField = NSSecureTextField()
    private let keyTermsView = NSTextView()
    private let presetPopup = NSPopUpButton()
    private let presetView = NSTextView()
    private let costLabel = NSTextField(labelWithString: "")
    private let minuteCapField = NSTextField()
    private var editingPreset = "Meeting"

    init(state: AppState) {
        self.state = state
    }

    func show() {
        if window == nil { build() }
        load()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func scrollWrap(_ textView: NSTextView, height: CGFloat) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.autoresizingMask = [.width]
        return scroll
    }

    private func build() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "ms-notes Settings"
        window.isReleasedWhenClosed = false

        vaultField.placeholderString = "Path to the folder in your Obsidian vault"
        let chooseButton = NSButton(title: "Choose…", target: self, action: #selector(chooseVault))
        let vaultRow = NSStackView(views: [vaultField, chooseButton])
        vaultRow.orientation = .horizontal

        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        presetPopup.target = self
        presetPopup.action = #selector(presetChanged)

        let stack = NSStackView(views: [
            label("Vault folder (Notes here; Transcripts in 'transcripts/'):"),
            vaultRow,
            label("AssemblyAI API key (stored in the Keychain):"),
            assemblyField,
            label("Anthropic API key (stored in the Keychain):"),
            anthropicField,
            label("Key Terms — one per line, sent to the transcriber:"),
            scrollWrap(keyTermsView, height: 70),
            label("Monthly budget in minutes (shown in the panel; never blocks recording):"),
            minuteCapField,
            label("Presets:"),
            presetPopup,
            scrollWrap(presetView, height: 150),
            costLabel,
            saveButton,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = stack
        minuteCapField.placeholderString = "600"
        minuteCapField.translatesAutoresizingMaskIntoConstraints = false
        minuteCapField.widthAnchor.constraint(equalToConstant: 100).isActive = true
        for view in [vaultRow, assemblyField, anthropicField] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: 488).isActive = true
        }
        for view in stack.views where view is NSScrollView {
            view.widthAnchor.constraint(equalToConstant: 488).isActive = true
        }
        self.window = window
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 11, weight: .medium)
        field.textColor = .secondaryLabelColor
        return field
    }

    private func load() {
        vaultField.stringValue = state.settings.vaultPath ?? ""
        assemblyField.stringValue = state.settings.keychain.get(.assemblyAI) ?? ""
        anthropicField.stringValue = state.settings.keychain.get(.anthropic) ?? ""
        keyTermsView.string = state.settings.keyTerms.joined(separator: "\n")
        minuteCapField.stringValue = "\(state.settings.monthlyMinuteCap)"
        presetPopup.removeAllItems()
        presetPopup.addItems(withTitles: state.settings.presets.map(\.name))
        editingPreset = state.settings.presets.first?.name ?? "Meeting"
        presetView.string = state.settings.presets.first?.prompt ?? ""
        costLabel.stringValue = String(format: "Running cost total: $%.4f",
                                       state.settings.costTotalUSD)
    }

    @objc private func presetChanged() {
        // Persist edits to the preset being switched away from, in memory.
        commitPresetEdit()
        editingPreset = presetPopup.titleOfSelectedItem ?? "Meeting"
        presetView.string = state.settings.presets
            .first(where: { $0.name == editingPreset })?.prompt ?? ""
    }

    private func commitPresetEdit() {
        var presets = state.settings.presets
        if let index = presets.firstIndex(where: { $0.name == editingPreset }) {
            presets[index].prompt = presetView.string
            state.settings.presets = presets
        }
    }

    @objc private func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            vaultField.stringValue = url.path
        }
    }

    @objc private func save() {
        let path = vaultField.stringValue.trimmingCharacters(in: .whitespaces)
        state.settings.vaultPath = path.isEmpty ? nil : path
        if !assemblyField.stringValue.isEmpty {
            try? state.settings.keychain.set(assemblyField.stringValue, for: .assemblyAI)
        }
        if !anthropicField.stringValue.isEmpty {
            try? state.settings.keychain.set(anthropicField.stringValue, for: .anthropic)
        }
        state.settings.keyTerms = keyTermsView.string
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let cap = Int(minuteCapField.stringValue.trimmingCharacters(in: .whitespaces)), cap > 0 {
            state.settings.monthlyMinuteCap = cap
        }
        commitPresetEdit()
        state.bootstrap()  // keys may have just become available
        state.refreshSessions()
        window?.orderOut(nil)
    }
}

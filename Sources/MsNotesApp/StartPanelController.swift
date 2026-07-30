import AppKit
import MsNotesCore

/// The Start popover (Journey step 2): Preset, optional Title, optional
/// Participants, then Start.
@MainActor
final class StartPanelController: NSObject {
    let state: AppState
    private var panel: NSPanel?
    private let presetPopup = NSPopUpButton()
    private let titleField = NSTextField()
    private let participantsField = NSTextField()

    init(state: AppState) {
        self.state = state
    }

    func show() {
        if panel == nil { build() }
        presetPopup.removeAllItems()
        presetPopup.addItems(withTitles: state.settings.presets.map(\.name))
        titleField.stringValue = ""
        participantsField.stringValue = ""
        panel?.center()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 170),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered, defer: false)
        panel.title = "Start Recording"
        panel.isFloatingPanel = true

        titleField.placeholderString = "Title (optional — defaults to preset)"
        participantsField.placeholderString = "Participants, comma-separated (optional)"

        let startButton = NSButton(title: "Start Recording", target: self,
                                   action: #selector(startTapped))
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"

        let presetLabel = NSTextField(labelWithString: "Preset:")
        let presetRow = NSStackView(views: [presetLabel, presetPopup])
        presetRow.orientation = .horizontal

        let stack = NSStackView(views: [presetRow, titleField, participantsField, startButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        panel.contentView = stack
        NSLayoutConstraint.activate([
            titleField.widthAnchor.constraint(equalToConstant: 288),
            participantsField.widthAnchor.constraint(equalToConstant: 288),
        ])
        self.panel = panel
    }

    @objc private func startTapped() {
        state.start(title: titleField.stringValue,
                    presetName: presetPopup.titleOfSelectedItem ?? "Meeting",
                    participants: participantsField.stringValue)
        panel?.orderOut(nil)
    }
}

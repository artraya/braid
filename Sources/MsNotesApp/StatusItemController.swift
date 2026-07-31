import AppKit
import MsNotesCore

/// The menu-bar presence: icon (five R15 states) + menu. The menu is rebuilt
/// each time it opens so it always reflects current state.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    let state: AppState
    let statusItem: NSStatusItem
    let menu = NSMenu()
    lazy var startPanel = StartPanelController(state: state)
    lazy var settingsWindow = SettingsWindowController(state: state)
    lazy var namingWindow = SpeakerNamingWindowController(state: state)

    init(state: AppState) {
        self.state = state
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        menu.delegate = self
        statusItem.menu = menu
        state.onChange = { [weak self] in self?.refreshIcon() }
        refreshIcon()
    }

    func refreshIcon() {
        let image = NSImage(systemSymbolName: state.iconName,
                            accessibilityDescription: "ms-notes: \(state.phase.rawValue)")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        switch state.phase {
        case .idle:
            if !state.setupComplete {
                let item = NSMenuItem(title: "Finish setup in Settings…", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
            let start = NSMenuItem(title: "Start Recording…",
                                   action: #selector(startTapped), keyEquivalent: "r")
            start.target = self
            start.isEnabled = state.setupComplete
            menu.addItem(start)

        case .recording, .paused:
            let elapsed = state.recordingStartedAt.map {
                Transcript.timestamp(Date().timeIntervalSince($0))
            } ?? ""
            let status = NSMenuItem(
                title: "\(state.phase == .paused ? "Paused" : "Recording") — \(state.currentTitle)  \(elapsed)",
                action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)

            if state.phase == .recording {
                let pause = NSMenuItem(title: "Pause", action: #selector(pauseTapped), keyEquivalent: "p")
                pause.target = self
                menu.addItem(pause)
            } else {
                let resume = NSMenuItem(title: "Resume", action: #selector(resumeTapped), keyEquivalent: "p")
                resume.target = self
                menu.addItem(resume)
            }
            let stop = NSMenuItem(title: "Stop", action: #selector(stopTapped), keyEquivalent: "s")
            stop.target = self
            menu.addItem(stop)
        }

        if state.processingCount > 0 {
            menu.addItem(.separator())
            let item = NSMenuItem(title: "Processing \(state.processingCount) job(s)…",
                                  action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        if !state.awaitingNames.isEmpty {
            menu.addItem(.separator())
            for record in state.awaitingNames {
                let count = record.transcript.remoteSpeakerStats().count
                let item = NSMenuItem(
                    title: "Name \(count) speaker\(count == 1 ? "" : "s") — \(record.session.title)",
                    action: #selector(nameSpeakersTapped(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = record.id
                menu.addItem(item)
            }
        }

        if !state.failedJobs.isEmpty {
            menu.addItem(.separator())
            for job in state.failedJobs {
                let item = NSMenuItem(title: "⚠️ \(job.session.title) — Retry",
                                      action: #selector(retryTapped(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = job.id
                item.toolTip = job.lastError
                menu.addItem(item)
            }
        }

        if let error = state.lastError {
            menu.addItem(.separator())
            let item = NSMenuItem(title: "⚠️ \(error)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let cost = NSMenuItem(
            title: String(format: "Total cost $%.2f", state.settings.costTotalUSD),
            action: nil, keyEquivalent: "")
        cost.isEnabled = false
        menu.addItem(cost)

        let settings = NSMenuItem(title: "Settings…", action: #selector(settingsTapped), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let quit = NSMenuItem(title: "Quit ms-notes", action: #selector(quitTapped), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - Actions

    @objc func startTapped() { startPanel.show() }
    @objc func pauseTapped() { state.pause() }
    @objc func resumeTapped() { state.resume() }
    @objc func stopTapped() { state.stop() }
    @objc func settingsTapped() { settingsWindow.show() }
    @objc func quitTapped() { NSApp.terminate(nil) }

    @objc func nameSpeakersTapped(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let record = state.awaitingNames.first(where: { $0.id == id }) else { return }
        namingWindow.show(record: record)
    }

    @objc func retryTapped(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String {
            state.retry(jobID: id)
        }
    }
}

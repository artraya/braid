import AppKit
import MsNotesCore

/// The menu-bar presence: icon (five R15 states), the Sessions panel on left
/// click, and the menu on right click. The menu is rebuilt each time it opens
/// so it always reflects current state.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    let state: AppState
    let statusItem: NSStatusItem
    let menu = NSMenu()
    lazy var settingsWindow = SettingsWindowController(state: state)
    lazy var namingWindow = SpeakerNamingWindowController(state: state)
    lazy var sessionsPanel = SessionsPanelController(state: state)
    lazy var recordingHUD = RecordingHUDController(state: state)

    init(state: AppState) {
        self.state = state
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        menu.delegate = self
        // No `statusItem.menu`: that would make left click open the menu. The
        // button handles both buttons itself and pops the menu up on demand.
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        sessionsPanel.onOpenSettings = { [weak self] in self?.settingsTapped() }
        sessionsPanel.onNameSpeakers = { [weak self] id in self?.showNaming(sessionID: id) }
        state.onChange = { [weak self] in
            self?.refreshIcon()
            self?.recordingHUD.syncToPhase()
        }
        refreshIcon()
    }

    @objc func statusItemClicked() {
        let isRightClick = NSApp.currentEvent?.type == .rightMouseUp
            || NSApp.currentEvent?.modifierFlags.contains(.control) == true
        if isRightClick {
            showMenu()
        } else {
            sessionsPanel.toggle(from: statusItem.button)
        }
    }

    private func showMenu() {
        sessionsPanel.close()
        // Attaching the menu makes the button pop it up with the system's own
        // placement and highlight, then it is detached so left click still
        // belongs to the panel.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
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

        if !state.activeJobs.isEmpty {
            menu.addItem(.separator())
            for job in state.activeJobs {
                let item = NSMenuItem(title: "Cancel processing — \(job.session.title)",
                                      action: #selector(cancelJobTapped(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = job.id
                item.toolTip = "Stops before it costs anything more. The recording is kept."
                menu.addItem(item)
            }
        }

        if !state.cancelledJobs.isEmpty {
            menu.addItem(.separator())
            for job in state.cancelledJobs {
                let item = NSMenuItem(title: "Process \(job.session.title) after all",
                                      action: #selector(retryTapped(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = job.id
                menu.addItem(item)
            }
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

    @objc func startTapped() { sessionsPanel.show(from: statusItem.button) }
    @objc func pauseTapped() { state.pause() }
    @objc func resumeTapped() { state.resume() }
    @objc func stopTapped() { state.stop() }
    @objc func settingsTapped() { settingsWindow.show() }
    @objc func quitTapped() { NSApp.terminate(nil) }

    @objc func nameSpeakersTapped(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { showNaming(sessionID: id) }
    }

    func showNaming(sessionID: String) {
        guard let record = state.awaitingNames.first(where: { $0.id == sessionID }) else { return }
        namingWindow.show(record: record)
    }

    @objc func cancelJobTapped(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String {
            state.cancelJob(id: id)
        }
    }

    @objc func retryTapped(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String {
            state.retry(jobID: id)
        }
    }
}

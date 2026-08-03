import AppKit
import BraidCore

/// The menu-bar presence: the icon (five R15 states), the panel on left click,
/// and a short menu on right click.
///
/// The panel is the whole interface — recording, naming, settings and
/// confirmations are all views inside it — so this menu is only a shortcut to
/// them plus Quit. It is rebuilt each time it opens so it reflects current state.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    let state: AppState
    let statusItem: NSStatusItem
    let menu = NSMenu()
    lazy var sessionsPanel = SessionsPanelController(state: state)

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
        state.onChange = { [weak self] in
            self?.refreshIcon()
            self?.sessionsPanel.phaseChanged()
        }
        // Clicking a "speakers to name" notification lands in the naming view.
        Notifier.onOpenNaming = { [weak self] id in
            guard let self else { return }
            self.sessionsPanel.show(from: self.statusItem.button, route: .naming(id))
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
                            accessibilityDescription: "Braid: \(state.phase.rawValue)")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let open = NSMenuItem(title: state.phase == .idle ? "Open Braid" : "Show recording",
                              action: #selector(openPanel), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

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
        let minutes = Int(state.usage.minutesUsed.rounded())
        let usage = NSMenuItem(
            title: "\(minutes) min recorded this month",
            action: nil, keyEquivalent: "")
        usage.isEnabled = false
        menu.addItem(usage)

        let history = NSMenuItem(title: "History", action: #selector(historyTapped),
                                 keyEquivalent: "")
        history.target = self
        menu.addItem(history)
        let settings = NSMenuItem(title: "Settings…", action: #selector(settingsTapped),
                                  keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let quit = NSMenuItem(title: "Quit Braid", action: #selector(quitTapped),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - Actions

    @objc func openPanel() { sessionsPanel.show(from: statusItem.button) }
    @objc func settingsTapped() { sessionsPanel.show(from: statusItem.button, route: .settings) }
    @objc func historyTapped() { sessionsPanel.show(from: statusItem.button, route: .history) }
    @objc func quitTapped() { NSApp.terminate(nil) }

    @objc func nameSpeakersTapped(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        sessionsPanel.show(from: statusItem.button, route: .naming(id))
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

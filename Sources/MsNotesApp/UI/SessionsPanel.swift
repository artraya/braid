import AppKit
import SwiftUI
import Observation
import MsNotesCore

/// Everything the panel shows that is not already on AppState: which view it is
/// on, what the start form has typed into it, the live recording readout, and
/// any confirmation waiting on an answer.
///
/// The panel is the whole interface. Recording, naming speakers, settings and
/// confirmations are all views inside this one window rather than windows of
/// their own, so the app never puts a second thing on screen.
@MainActor
@Observable
final class SessionsPanelModel {
    enum Route: Equatable {
        case main
        case naming(String)   // Session id
        case settings
    }

    var route: Route = .main
    var showingStartForm = false
    var title = ""
    var participants = ""
    var presetName = ""
    /// Where the pointer sits, measured from the panel's left edge. Updated
    /// whenever the panel is placed, since it is clamped to the screen while
    /// the menu bar icon is not.
    var arrowX: CGFloat = Theme.panelWidth / 2

    // Live recording readout, ticked by the controller while the panel is open.
    var elapsed: TimeInterval = 0
    var levels: [Float] = []
    var costEstimate: Double = 0
    /// Seconds until the Session stops by itself, or nil when nothing is pending.
    var autoEndIn: Int?

    /// An irreversible action waiting on a yes or no, shown inline rather than
    /// as an alert box — an alert would be exactly the extra window the panel
    /// exists to avoid.
    struct Confirmation: Equatable {
        enum Action: Equatable {
            case discardRecording
            case deleteJob(String)
        }
        let action: Action
        let question: String
        let detail: String
        let confirmLabel: String
    }
    var confirmation: Confirmation?

    // Naming speakers.
    var namingNames: [String: String] = [:]
    var namingWorking = false
    var namingError: String?

    let settingsForm = SettingsFormModel()

    func resetForm(defaultPreset: String) {
        title = ""
        participants = ""
        presetName = defaultPreset
        showingStartForm = false
    }

    func goToMain() {
        route = .main
        confirmation = nil
        namingNames = [:]
        namingError = nil
        namingWorking = false
    }
}

/// What the panel can ask the app to do. Bundled rather than passed as a dozen
/// separate closures.
struct PanelActions {
    var start: () -> Void = {}
    var pauseResume: () -> Void = {}
    var stop: () -> Void = {}
    var discardRecording: () -> Void = {}
    var keepRecording: () -> Void = {}
    var openNote: (String) -> Void = { _ in }
    var cancelJob: (String) -> Void = { _ in }
    var retryJob: (String) -> Void = { _ in }
    var deleteJob: (String) -> Void = { _ in }
    var applyNames: (String) -> Void = { _ in }
    var chooseVault: () -> Void = {}
    var saveSettings: () -> Void = {}
    var quit: () -> Void = {}
}

@MainActor
final class SessionsPanelController: NSObject, NSWindowDelegate {
    /// One frame per LevelMeter bar, so the waveform advances smoothly without
    /// redrawing the same picture twice. Only runs while the panel is open.
    private static let tickInterval = LevelMeter.barSeconds
    static let barCount = 44

    private let state: AppState
    private let model = SessionsPanelModel()
    private var panel: FloatingPanel?
    private var anchor: MenuBarAnchor?
    private var shownAt: Date?
    /// When the panel last dismissed itself because it lost focus.
    private var autoClosedAt: Date?
    private var ticker: Timer?

    init(state: AppState) {
        self.state = state
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Clicking the icon while the panel is open must close it.
    ///
    /// It cannot simply check `isVisible`: pressing the menu bar item takes key
    /// status away from the panel first, so the auto-dismiss has already
    /// closed it by the time this runs, and a naive toggle would reopen it
    /// immediately — the panel would never close from the icon. A dismiss that
    /// happened moments ago is treated as "it was open".
    func toggle(from button: NSStatusBarButton?) {
        let justDismissed = autoClosedAt.map { Date().timeIntervalSince($0) < 0.5 } ?? false
        if isVisible || justDismissed {
            close()
        } else {
            show(from: button)
        }
    }

    func show(from button: NSStatusBarButton?, route: SessionsPanelModel.Route = .main) {
        state.refreshSessions()
        state.refreshNamingState()
        if model.route != route { model.goToMain() }
        model.route = route
        if route == .settings { model.settingsForm.load(from: state) }
        model.resetForm(defaultPreset: state.settings.presets.first?.name ?? "Meeting")
        tick()

        let panel = self.panel ?? makePanel()
        self.panel = panel
        anchor = MenuBarAnchor(statusItemButton: button) ?? anchor
        autoClosedAt = nil
        panel.layoutIfNeeded()
        panel.fitToContent()
        reposition()
        shownAt = Date()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startTicking()
        // Content settles a beat after the window is on screen; re-hang it so
        // the final height still hangs from the menu bar.
        DispatchQueue.main.async { [weak self] in self?.reposition() }
    }

    /// Re-hangs the panel and points the arrow at the icon. Called on every
    /// resize as well as on show: SwiftUI sizes the window to its content after
    /// the fact, and switching view or opening the start form changes it.
    private func reposition() {
        guard let panel, let anchor else { return }
        model.arrowX = panel.hang(from: anchor)
        panel.invalidateShadow()
    }

    func windowDidResize(_ notification: Notification) {
        reposition()
    }

    func close() {
        shownAt = nil
        stopTicking()
        panel?.orderOut(nil)
    }

    /// Called when the Session's phase changes, so an open panel switches
    /// between the idle and recording views without being reopened.
    func phaseChanged() {
        guard isVisible else { return }
        tick()
        state.phase == .idle ? stopTicking() : startTicking()
    }

    // MARK: - Live readout

    /// The timer only runs while the panel is on screen. With it closed there
    /// is nothing to animate, and a recording can last hours.
    private func startTicking() {
        guard ticker == nil, state.phase != .idle else { return }
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Common mode, or the clock freezes while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard state.phase != .idle else {
            model.levels = []
            model.autoEndIn = nil
            return
        }
        model.levels = state.engine.levels.recent(Self.barCount)
        model.costEstimate = state.liveCostEstimate
        if let startedAt = state.recordingStartedAt, state.phase == .recording {
            model.elapsed = Date().timeIntervalSince(startedAt)
        }
        model.autoEndIn = state.autoEndDeadline.map {
            max(0, Int($0.timeIntervalSinceNow.rounded(.up)))
        }
    }

    // MARK: - Content

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: Theme.panelWidth, height: 480),
            draggable: false)
        panel.delegate = self
        panel.setContent(SessionsPanelView(
            state: state, model: model, actions: actions,
            onConfirm: { [weak self] confirmed in self?.resolveConfirmation(confirmed) }))
        return panel
    }

    private var actions: PanelActions {
        PanelActions(
            start: { [weak self] in self?.start() },
            pauseResume: { [weak self] in
                guard let self else { return }
                self.state.phase == .paused ? self.state.resume() : self.state.pause()
            },
            stop: { [weak self] in self?.state.stop() },
            discardRecording: { [weak self] in self?.askToDiscardRecording() },
            keepRecording: { [weak self] in
                self?.state.cancelAutoEnd()
                self?.tick()
            },
            openNote: { [weak self] path in self?.state.openNote(at: path) },
            cancelJob: { [weak self] id in self?.state.cancelJob(id: id) },
            retryJob: { [weak self] id in self?.state.retry(jobID: id) },
            deleteJob: { [weak self] id in self?.askToDeleteJob(id) },
            applyNames: { [weak self] id in self?.applyNames(to: id) },
            chooseVault: { [weak self] in self?.chooseVault() },
            saveSettings: { [weak self] in self?.saveSettings() },
            quit: { NSApp.terminate(nil) })
    }

    // MARK: - Actions

    private func start() {
        state.start(title: model.title,
                    presetName: model.presetName,
                    participants: model.participants)
        model.resetForm(defaultPreset: state.settings.presets.first?.name ?? "Meeting")
        tick()
        startTicking()
    }

    /// Discarding destroys audio that cannot be recovered, so it always asks,
    /// inline, and the answer that keeps the recording is the plain one.
    private func askToDiscardRecording() {
        model.confirmation = SessionsPanelModel.Confirmation(
            action: .discardRecording,
            question: "Discard this recording?",
            detail: "The audio is deleted and no note is written. This cannot be undone.",
            confirmLabel: "Discard")
    }

    private func askToDeleteJob(_ id: String) {
        guard let job = state.cancelledJobs.first(where: { $0.id == id }) else { return }
        model.confirmation = SessionsPanelModel.Confirmation(
            action: .deleteJob(id),
            question: "Delete the recording for \"\(job.session.title)\"?",
            detail: "\(Format.duration(job.session.recordedDuration)) of audio is deleted and no note is written. This cannot be undone.",
            confirmLabel: "Delete")
    }

    func resolveConfirmation(_ confirmed: Bool) {
        guard let confirmation = model.confirmation else { return }
        model.confirmation = nil
        guard confirmed else { return }
        switch confirmation.action {
        case .discardRecording: state.discard()
        case .deleteJob(let id): state.discardJob(id: id)
        }
    }

    private func applyNames(to sessionID: String) {
        model.namingWorking = true
        model.namingError = nil
        state.applyNames(model.namingNames, toSessionID: sessionID) { [weak self] result in
            guard let self else { return }
            self.model.namingWorking = false
            switch result {
            case .success:
                self.model.goToMain()
            case .failure(let error):
                self.model.namingError = "\(error)"
            }
        }
    }

    private func chooseVault() {
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.allowsMultipleSelection = false
        open.prompt = "Choose"
        if open.runModal() == .OK, let url = open.url {
            model.settingsForm.vaultPath = url.path
        }
    }

    private func saveSettings() {
        model.settingsForm.save(to: state)
        state.bootstrap()   // keys may have just become available
        state.refreshSessions()
        model.goToMain()
    }

    /// Clicking away dismisses the panel, the way a menu would.
    ///
    /// Ignored for a moment after showing: activating the app hands key status
    /// around while the panel is still appearing, and acting on that resign
    /// closed the panel the instant it opened. Also ignored while a file
    /// chooser is up, or picking a vault folder would dismiss the settings
    /// view behind it.
    func windowDidResignKey(_ notification: Notification) {
        guard let shownAt, Date().timeIntervalSince(shownAt) > 0.4 else { return }
        guard NSApp.modalWindow == nil else { return }
        autoClosedAt = Date()
        close()
    }
}

// MARK: - Root view

struct SessionsPanelView: View {
    let state: AppState
    let model: SessionsPanelModel
    var actions = PanelActions()
    /// Set by the controller so an inline confirmation can be answered.
    var onConfirm: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            switch model.route {
            case .main:
                MainRoute(state: state, model: model, actions: actions, onConfirm: onConfirm)
            case .naming(let id):
                NamingRoute(state: state, model: model, sessionID: id, actions: actions)
            case .settings:
                SettingsRoute(state: state, model: model, actions: actions)
            }
        }
        .frame(width: Theme.panelWidth)
        .panelSurface(arrowX: model.arrowX)
        .preferredColorScheme(.dark)
    }
}

/// The everyday view: what is recording now, what it has cost this month, what
/// is still processing, and what has already been delivered.
private struct MainRoute: View {
    let state: AppState
    let model: SessionsPanelModel
    let actions: PanelActions
    let onConfirm: (Bool) -> Void

    private var recording: Bool { state.phase != .idle }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PanelHeader(title: recording ? "Recording" : "Sessions") {
                Button { model.route = .settings } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.faint)
                }
                .buttonStyle(.plain)
                .help("Settings")
            }

            if let confirmation = model.confirmation {
                ConfirmationStrip(confirmation: confirmation, onAnswer: onConfirm)
            }

            if recording {
                RecordingSection(state: state, model: model, actions: actions)
            }

            UsageCard(usage: state.usage)
            processingList
            sessionList

            if !recording {
                if model.showingStartForm {
                    StartForm(state: state, model: model, onStart: actions.start)
                }
                recordButton
            }
        }
        .padding(Theme.padding)
    }

    /// Work that has not been paid for yet, with the way to stop it. This sits
    /// above the history because it is the only part of the panel that is
    /// time-sensitive: once a Job finishes, cancelling it is no longer an option.
    @ViewBuilder
    private var processingList: some View {
        if !state.activeJobs.isEmpty || !state.cancelledJobs.isEmpty
            || !state.awaitingNames.isEmpty {
            VStack(spacing: 6) {
                ForEach(state.activeJobs) { job in
                    PendingRow(title: job.session.title,
                               detail: "Processing · \(Format.duration(job.session.recordedDuration))",
                               tint: Theme.accent, spinning: true) {
                        PendingAction(label: "Cancel", tint: Theme.dim) { actions.cancelJob(job.id) }
                    }
                }
                ForEach(state.cancelledJobs) { job in
                    PendingRow(title: job.session.title,
                               detail: "Cancelled · \(Format.duration(job.session.recordedDuration)) kept",
                               tint: Theme.faint, spinning: false) {
                        PendingAction(label: "Process", tint: Theme.accent) { actions.retryJob(job.id) }
                        PendingAction(label: "Delete", tint: Theme.recording) { actions.deleteJob(job.id) }
                    }
                }
                ForEach(state.awaitingNames) { record in
                    let count = record.transcript.remoteSpeakerStats().count
                    PendingRow(title: record.session.title,
                               detail: "\(count) speaker\(count == 1 ? "" : "s") to name",
                               tint: Theme.accent, spinning: false, symbol: "person.wave.2") {
                        PendingAction(label: "Name", tint: Theme.accent) {
                            model.route = .naming(record.id)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var sessionList: some View {
        if state.recentSessions.isEmpty {
            Text(state.setupComplete
                 ? "No sessions yet. Record one and the note lands in your vault."
                 : "Finish setup in Settings before recording.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.faint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 18)
        } else {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(state.recentSessions) { session in
                        SessionRow(session: session) { actions.openNote(session.notePath) }
                    }
                }
            }
            .scrollIndicators(.never)
            // Fewer rows while recording, so the panel does not run down the
            // screen when the recording block is also showing.
            .frame(maxHeight: recording ? 118 : 232)
        }
    }

    private var recordButton: some View {
        Button {
            if model.showingStartForm {
                actions.start()
            } else {
                model.showingStartForm = true
            }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.showingStartForm ? Theme.text : Color.black.opacity(0.75))
                    .frame(width: 9, height: 9)
                Text(model.showingStartForm ? "Start recording" : "Record")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(state.setupComplete ? Theme.accent : Theme.card,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!state.setupComplete)
    }
}

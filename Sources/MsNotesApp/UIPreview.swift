import AppKit
import SwiftUI
import MsNotesCore

/// `--ui-preview [--snapshot <dir>]` — the Sessions panel and the recording HUD
/// against sample data, so the layout can be checked without recording anything
/// or waiting on a real Job. With `--snapshot` it writes PNGs and exits, which
/// is repeatable in a way that screenshotting a live window is not.
///
/// It draws the real views with real models; only the data is invented.
@MainActor
enum UIPreview {
    static func run(snapshotDirectory: String?) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        if let directory = snapshotDirectory {
            snapshot(into: URL(fileURLWithPath: directory))
            exit(0)
        }
        if CommandLine.arguments.contains("--check-geometry") {
            exit(checkGeometry() ? 0 : 1)
        }

        let panel = previewWindow(
            title: "Sessions panel",
            view: SessionsPanelPreview(sessions: previewSessions, usage: previewUsage),
            size: NSSize(width: Theme.panelWidth + 40, height: 560))
        let hud = previewWindow(
            title: "Recording HUD",
            view: RecordingHUDPreview(),
            size: NSSize(width: 400, height: 290))

        // Side by side on screen.
        if let visible = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.midX - 440, y: visible.midY - 280))
            hud.setFrameOrigin(NSPoint(x: visible.midX + 30, y: visible.midY - 140))
        }
        app.activate(ignoringOtherApps: true)
        app.run()
        exit(0)
    }

    /// Renders each view offscreen and writes it as a PNG. The view has to live
    /// in a real window briefly or SwiftUI never lays it out.
    private static func snapshot(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        write(SessionsPanelPreview(sessions: previewSessions, usage: previewUsage),
              named: "panel", into: directory)
        write(SessionsPanelPreview(sessions: previewSessions, usage: previewUsage,
                                   startFormOpen: true),
              named: "panel-start-form", into: directory)
        write(SessionsPanelPreview(sessions: [], usage: Usage.empty),
              named: "panel-empty", into: directory)
        write(SessionsPanelPreview(sessions: previewSessions, usage: previewUsage,
                                   pendingJobs: [previewJob("Weekly sync", minutes: 41)],
                                   cancelledJobs: [previewJob("Another Test", minutes: 80)]),
              named: "panel-processing", into: directory)
        // The arrow near the right edge, as it sits when the icon is far right
        // and the panel has been clamped inward.
        write(SessionsPanelPreview(sessions: previewSessions, usage: previewUsage,
                                   arrowX: Theme.panelWidth - 34),
              named: "panel-arrow-right", into: directory)
        write(RecordingHUDPreview(), named: "hud", into: directory)
        write(RecordingHUDPreview(paused: true), named: "hud-paused", into: directory)
        write(RecordingHUDPreview(autoEndIn: 24), named: "hud-auto-end", into: directory)
    }

    private static func write(_ view: some View, named name: String, into directory: URL) {
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            eprintLine("snapshot \(name): could not allocate a bitmap")
            return
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            eprintLine("snapshot \(name): PNG encoding failed")
            return
        }
        let url = directory.appendingPathComponent("\(name).png")
        try? data.write(to: url)
        print("wrote \(url.path)")
    }

    private static var previewSessions: [SessionRecord] {
        [
            sample("Standup notes", minutesAgo: 90, duration: 252, cost: 0.31),
            sample("Client call — Acme", minutesAgo: 60 * 26, duration: 1720, cost: 1.94),
            sample("Book chapter dictation", minutesAgo: 60 * 52, duration: 3063, cost: 3.02),
            sample("Site handover", minutesAgo: 60 * 120, duration: 640, cost: 0.72),
        ]
    }

    private static func previewJob(_ title: String, minutes: Double) -> Job {
        Job(session: Session(title: title, presetName: "Meeting", participants: [],
                             startedAt: Date(), recordedDuration: minutes * 60),
            remoteSilent: false)
    }

    private static var previewUsage: Usage {
        Usage(minutesUsed: 412, minuteCap: 600, costUSD: 4.82, daysLeftInMonth: 18)
    }

    /// An AppState wired to throwaway storage: a private defaults suite and
    /// temporary directories, so a preview can never read or alter real data.
    static func scratchState() -> AppState {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ms-notes-preview")
        let defaults = UserDefaults(suiteName: "no.msnotes.preview") ?? .standard
        let state = AppState(
            settings: SettingsStore(defaults: defaults),
            transcripts: TranscriptStore(root: scratch.appendingPathComponent("transcripts")),
            sessions: SessionIndex(url: scratch.appendingPathComponent("sessions.json")))
        state.keysConfigured = true   // never touch the real Keychain from a preview
        return state
    }

    private static func sample(_ title: String, minutesAgo: Double,
                               duration: TimeInterval, cost: Double) -> SessionRecord {
        SessionRecord(id: UUID().uuidString, title: title, presetName: "Meeting",
                      startedAt: Date().addingTimeInterval(-minutesAgo * 60),
                      recordedDuration: duration, costUSD: cost,
                      notePath: "/tmp/\(title).md")
    }

    private static func previewWindow(title: String, view: some View, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(white: 0.08, alpha: 1)
        let hosting = NSHostingView(rootView: AnyView(
            view.frame(maxWidth: .infinity, maxHeight: .infinity)))
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        return window
    }
}

/// The panel view needs an AppState; this builds one with sample data rather
/// than reading the user's real vault.
@MainActor
private struct SessionsPanelPreview: View {
    let sessions: [SessionRecord]
    let usage: Usage
    var startFormOpen = false
    var pendingJobs: [Job] = []
    var cancelledJobs: [Job] = []
    var arrowX: CGFloat?

    var body: some View {
        let state = UIPreview.scratchState()
        state.activeJobs = pendingJobs
        state.cancelledJobs = cancelledJobs
        state.settings.vaultPath = "/tmp/preview-vault"
        state.recentSessions = sessions
        state.usage = usage
        let model = SessionsPanelModel()
        model.presetName = "Meeting"
        model.showingStartForm = startFormOpen
        model.arrowX = arrowX ?? Theme.panelWidth / 2
        return SessionsPanelView(state: state, model: model,
                                 onStart: {}, onOpenSettings: {}, onOpenNote: { _ in },
                                 onCancelJob: { _ in }, onRetryJob: { _ in },
                                 onDiscardJob: { _ in }, onNameSpeakers: { _ in })
            .padding(20)
    }
}

@MainActor
private struct RecordingHUDPreview: View {
    var paused = false
    var autoEndIn: Int?

    var body: some View {
        let state = AppState()
        state.phase = paused ? .paused : .recording
        state.currentTitle = "Another Test"
        state.recordingStartedAt = Date().addingTimeInterval(-736)
        let model = RecordingHUDModel()
        model.elapsed = 736
        model.costEstimate = 0.11
        model.autoEndIn = autoEndIn
        // A plausible speech envelope rather than noise, so the bar scaling can
        // actually be judged.
        model.levels = (0..<RecordingHUDController.barCount).map { i in
            let phrase = sin(Double(i) / 3.1) * 0.5 + 0.5
            let breath = sin(Double(i) / 11.0) * 0.35 + 0.6
            return Float(max(0.04, phrase * breath * 0.8))
        }
        return RecordingHUDView(state: state, model: model,
                                onPauseResume: {}, onStop: {}, onDiscard: {},
                                onKeepRecording: {})
            .padding(20)
    }
}

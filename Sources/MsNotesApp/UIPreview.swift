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
            size: NSSize(width: Theme.panelWidth + 40, height: 620))
        let recording = previewWindow(
            title: "Recording",
            view: SessionsPanelPreview(sessions: previewSessions, usage: previewUsage,
                                       recording: .recording),
            size: NSSize(width: Theme.panelWidth + 40, height: 780))

        // Side by side on screen.
        if let visible = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.midX - 460, y: visible.midY - 310))
            recording.setFrameOrigin(NSPoint(x: visible.midX + 40, y: visible.midY - 390))
        }
        app.activate(ignoringOtherApps: true)
        app.run()
        exit(0)
    }

    /// Verifies the whole sizing chain a real panel goes through — SwiftUI
    /// lays out, the window adopts that size, the window hangs from the menu
    /// bar — without needing a status item or a click to drive it.
    ///
    /// The bug this exists to catch: the window keeps its placeholder height,
    /// SwiftUI centres the content inside it, and the panel appears to float
    /// below the menu bar with dead space above it.
    private static func checkGeometry() -> Bool {
        var ok = true
        func check(_ label: String, _ condition: Bool, _ detail: String) {
            print("\(condition ? "ok  " : "FAIL") \(label): \(detail)")
            if !condition { ok = false }
        }

        let placeholderHeight: CGFloat = 480
        // Every view the panel can show, because each is a different height and
        // the window has to hang flush from the menu bar in all of them.
        let cases: [(String, SessionsPanelPreview)] = [
            ("populated", SessionsPanelPreview(sessions: previewSessions, usage: previewUsage)),
            ("empty", SessionsPanelPreview(sessions: [], usage: previewUsage)),
            ("recording", SessionsPanelPreview(sessions: previewSessions, usage: previewUsage,
                                               recording: .recording)),
            ("settings", SessionsPanelPreview(sessions: previewSessions, usage: previewUsage,
                                              route: .settings)),
        ]
        for (name, preview) in cases {
            let panel = FloatingPanel(
                contentRect: NSRect(x: 0, y: 0, width: Theme.panelWidth, height: placeholderHeight),
                draggable: false)
            panel.setContent(preview)
            panel.layoutIfNeeded()
            panel.fitToContent()

            let fitted = panel.contentSize ?? .zero
            check("\(name): window height follows content",
                  abs(panel.frame.height - fitted.height) < 1,
                  "window \(Int(panel.frame.height)) vs content \(Int(fitted.height))")
            check("\(name): placeholder height discarded",
                  abs(panel.frame.height - placeholderHeight) > 1 || fitted.height == placeholderHeight,
                  "height \(Int(panel.frame.height))")

            // Hang it from a synthetic menu bar and confirm it is flush.
            let screen = CGRect(x: 0, y: 0, width: 2560, height: 1416)
            let placement = PanelGeometry.place(
                panelSize: panel.frame.size, iconCentreX: 2049,
                menuBarBottomY: screen.maxY, screen: screen)
            panel.setFrameTopLeftPoint(placement.topLeft)
            check("\(name): top edge flush with the menu bar",
                  abs(panel.frame.maxY - screen.maxY) < 1,
                  "gap \(Int(screen.maxY - panel.frame.maxY))pt")
            check("\(name): arrow points at the icon",
                  abs((panel.frame.minX + placement.arrowX) - 2049) < 1,
                  "arrow at \(Int(panel.frame.minX + placement.arrowX)), icon at 2049")
        }
        print(ok ? "PANEL-GEOMETRY-OK" : "PANEL-GEOMETRY-FAILED")
        return ok
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
        write(SessionsPanelPreview(sessions: previewSessions, usage: previewUsage,
                                   recording: .recording),
              named: "panel-recording", into: directory)
        write(SessionsPanelPreview(sessions: previewSessions, usage: previewUsage,
                                   recording: .paused),
              named: "panel-recording-paused", into: directory)
        write(SessionsPanelPreview(sessions: previewSessions, usage: previewUsage,
                                   recording: .recording, autoEndIn: 24),
              named: "panel-recording-auto-end", into: directory)
        write(SessionsPanelPreview(
                sessions: previewSessions, usage: previewUsage, recording: .recording,
                confirmation: .init(action: .discardRecording,
                                    question: "Discard this recording?",
                                    detail: "The audio is deleted and no note is written. This cannot be undone.",
                                    confirmLabel: "Discard")),
              named: "panel-confirm", into: directory)
        write(SessionsPanelPreview(sessions: previewSessions, usage: previewUsage,
                                   route: .settings),
              named: "panel-settings", into: directory)
        if let naming = previewNamingRecord {
            write(SessionsPanelPreview(sessions: previewSessions, usage: previewUsage,
                                       route: .naming(naming.id), awaitingNames: [naming]),
                  named: "panel-naming", into: directory)
        }
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

    private static var previewNamingRecord: NamingRecord? {
        let session = Session(title: "Client call — Acme", presetName: "Meeting",
                              participants: ["Sarah", "Tom"], startedAt: Date(),
                              recordedDuration: 1720)
        let transcript = Transcript(utterances: [
            Utterance(speaker: "Me", start: 0, end: 20, text: "Thanks for making the time."),
            Utterance(speaker: "Speaker 1", start: 20, end: 96,
                      text: "We looked at the slope data over the weekend and the movement rates have settled right down."),
            Utterance(speaker: "Speaker 2", start: 96, end: 130,
                      text: "Agreed, though I would like another week before we sign it off."),
            Utterance(speaker: "Speaker 1", start: 130, end: 150, text: "Fine by me."),
        ])
        return NamingRecord(session: session, transcript: transcript, provider: "assemblyai",
                            costUSD: 1.94, notePath: "/tmp/note.md",
                            transcriptPath: "/tmp/transcript.md", noteHash: "")
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
    /// Drives the recording block at the top of the panel.
    var recording: AppState.Phase = .idle
    var autoEndIn: Int?
    var confirmation: SessionsPanelModel.Confirmation?
    var route: SessionsPanelModel.Route = .main
    var awaitingNames: [NamingRecord] = []

    var body: some View {
        let state = UIPreview.scratchState()
        state.activeJobs = pendingJobs
        state.cancelledJobs = cancelledJobs
        state.awaitingNames = awaitingNames
        state.settings.vaultPath = "/tmp/preview-vault"
        state.recentSessions = sessions
        state.usage = usage
        state.phase = recording
        if recording != .idle {
            state.currentTitle = "Another Test"
            state.recordingStartedAt = Date().addingTimeInterval(-736)
        }
        let model = SessionsPanelModel()
        model.presetName = "Meeting"
        model.showingStartForm = startFormOpen
        model.arrowX = arrowX ?? Theme.panelWidth / 2
        model.route = route
        model.confirmation = confirmation
        model.elapsed = 736
        model.costEstimate = 0.11
        model.autoEndIn = autoEndIn
        model.settingsForm.load(from: state)
        // A plausible speech envelope rather than noise, so the bar scaling can
        // actually be judged.
        model.levels = (0..<SessionsPanelController.barCount).map { i in
            let phrase = sin(Double(i) / 3.1) * 0.5 + 0.5
            let breath = sin(Double(i) / 11.0) * 0.35 + 0.6
            return Float(max(0.04, phrase * breath * 0.8))
        }
        return SessionsPanelView(state: state, model: model)
            .padding(20)
    }
}

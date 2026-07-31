import Foundation
import AppKit
import Observation
import ServiceManagement
import MsNotesCore

/// Bridges the CaptureEngine and JobQueue into UI state. `onChange` fires on
/// every state mutation so the status item can refresh; SwiftUI observes the
/// same properties directly.
/// Icon precedence when states coincide (SPEC Design):
/// recording/paused (the active Session) > error > processing > idle.
@MainActor
@Observable
final class AppState {
    enum Phase: String { case idle, recording, paused }

    var phase: Phase = .idle { didSet { onChange?() } }
    var processingCount = 0 { didSet { onChange?() } }
    var failedJobs: [MsNotesCore.Job] = [] { didSet { onChange?() } }
    var lastError: String? { didSet { onChange?() } }
    var currentTitle = ""
    var recordingStartedAt: Date?
    let settings: SettingsStore
    let transcripts: TranscriptStore
    let sessions: SessionIndex
    var onChange: (() -> Void)?

    /// Injectable so `--ui-preview` can run against a scratch defaults suite
    /// rather than reading, or writing, the real settings.
    init(settings: SettingsStore = SettingsStore(),
         transcripts: TranscriptStore = TranscriptStore(),
         sessions: SessionIndex = SessionIndex()) {
        self.settings = settings
        self.transcripts = transcripts
        self.sessions = sessions
    }

    /// Finished Sessions whose Remote speakers are still "Speaker 1", "Speaker 2".
    var awaitingNames: [NamingRecord] = [] { didSet { onChange?() } }
    /// Delivered Sessions, newest first, for the panel's list.
    var recentSessions: [SessionRecord] = []
    var usage = Usage.empty

    let engine = CaptureEngine()
    private var queue: JobQueue?
    private var currentSession: Session?
    private var namer: SpeakerNamer?

    /// SF Symbol per state (R15: five distinct states).
    var iconName: String {
        switch phase {
        case .recording: return "record.circle.fill"
        case .paused: return "pause.circle.fill"
        case .idle: break
        }
        if !failedJobs.isEmpty || lastError != nil { return "exclamationmark.triangle.fill" }
        if processingCount > 0 { return "arrow.triangle.2.circlepath.circle.fill" }
        return "waveform.circle"
    }

    /// Cached, not queried on demand: SwiftUI reads `setupComplete` on every
    /// redraw, and a Keychain lookup per frame is both slow and a good way to
    /// provoke consent prompts.
    var keysConfigured = false

    var setupComplete: Bool { keysConfigured && settings.vaultPath != nil }

    func refreshKeyState() {
        keysConfigured = settings.keychain.get(.assemblyAI) != nil
            && settings.keychain.get(.anthropic) != nil
    }

    // MARK: - Lifecycle

    func bootstrap() {
        refreshKeyState()
        guard queue == nil else { return }
        guard let sttKey = settings.keychain.get(.assemblyAI),
              let claudeKey = settings.keychain.get(.anthropic) else { return }
        let summariser = Summariser(apiKey: claudeKey)
        let env = JobQueue.Environment(
            provider: AssemblyAIAdapter(apiKey: sttKey),
            summariser: summariser,
            settings: settings,
            transcripts: transcripts,
            sessions: sessions,
            onEvent: { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            })
        let queue = JobQueue(env: env)
        self.queue = queue
        self.namer = SpeakerNamer(summariser: summariser, settings: settings,
                                  store: transcripts, sessions: sessions)
        transcripts.purgeExpired()
        refreshNamingState()
        refreshSessions()
        Task {
            await queue.loadPersisted()
            await self.refreshJobState()
        }
        Notifier.requestPermission()
        // Launch at login (SPEC R15); only meaningful from the installed bundle.
        if Bundle.main.bundleIdentifier == "no.msnotes.app" {
            try? SMAppService.mainApp.register()
        }
    }

    private func handle(_ event: JobQueue.Event) {
        switch event {
        case .jobStarted:
            break
        case .jobDone(_, let noteURL):
            refreshSessions()
            Notifier.notify(title: "Note ready",
                            body: noteURL.deletingPathExtension().lastPathComponent)
        case .jobFailed(let job, let transient):
            if !transient {
                Notifier.notify(title: "ms-notes: processing failed",
                                body: job.lastError ?? "Unknown error — Retry from the menu")
            }
        case .remoteSilentWarning:
            Notifier.notify(title: "No system audio captured",
                            body: "Check the System Audio Recording permission. The note will only contain your side.")
        case .speakersDetected(let job, let stats):
            refreshNamingState()
            let count = stats.count
            Notifier.notify(
                title: "\(count) speaker\(count == 1 ? "" : "s") to name",
                body: "\(job.session.title) — name them from the menu to rewrite the note.")
        }
        Task { await refreshJobState() }
    }

    func refreshJobState() async {
        guard let queue else { return }
        processingCount = await queue.pendingCount()
        failedJobs = await queue.failedJobs()
    }

    func refreshNamingState() {
        awaitingNames = transcripts.all().filter { !$0.namesApplied }
    }

    func refreshSessions() {
        recentSessions = sessions.recent(20)
        usage = sessions.usage(minuteCap: settings.monthlyMinuteCap)
    }

    /// What the Session running right now has cost so far: both Tracks at the
    /// elapsed recorded duration, plus a flat estimate for the summary. Shown
    /// live in the HUD, so it is deliberately an estimate and rounds up rather
    /// than surprising you at the end.
    var liveCostEstimate: Double {
        guard let startedAt = recordingStartedAt else { return 0 }
        let hours = Date().timeIntervalSince(startedAt) / 3600
        let table = CostTable.current
        let keyterms = !settings.keyTerms.isEmpty
        return table.sttCost(trackHours: hours, diarized: false, keyterms: keyterms)
            + table.sttCost(trackHours: hours, diarized: true, keyterms: keyterms)
            + table.claudeCost(inputTokens: Int(hours * 9_000), outputTokens: 1_200)
    }

    /// Opens a Note in Obsidian, falling back to whatever handles markdown.
    func openNote(at path: String) {
        let url = URL(fileURLWithPath: path)
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        if let obsidian = components.url, NSWorkspace.shared.open(obsidian) { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Speaker naming

    /// Relabels a delivered Session and re-runs the Summariser. Costs one
    /// Claude call; the Recording is long gone, so nothing is re-transcribed.
    func applyNames(_ names: [String: String], toSessionID id: String,
                    completion: @escaping (Result<SpeakerNamer.Result, Error>) -> Void) {
        guard let namer else {
            completion(.failure(PipelineError.permanent("API keys not configured")))
            return
        }
        Task {
            do {
                let result = try await namer.apply(names: names, toSessionID: id)
                self.refreshNamingState()
                self.refreshSessions()
                Notifier.notify(
                    title: "Note updated",
                    body: result.wroteNewPair
                        ? "The original had been edited, so a new note was written."
                        : result.noteURL.deletingPathExtension().lastPathComponent)
                completion(.success(result))
            } catch {
                self.lastError = "Could not apply names: \(error)"
                completion(.failure(error))
            }
        }
    }

    // MARK: - Session control

    func start(title: String, presetName: String, participants: String) {
        guard phase == .idle else { return }
        bootstrap()
        let names = participants
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let resolvedTitle = title.trimmingCharacters(in: .whitespaces).isEmpty
            ? presetName
            : title.trimmingCharacters(in: .whitespaces)
        let session = Session(title: resolvedTitle, presetName: presetName,
                              participants: names, startedAt: Date())
        let dir = JobQueue.appSupportURL.appendingPathComponent("jobs")
            .appendingPathComponent(session.id)
        do {
            try engine.start(into: dir)
            currentSession = session
            currentTitle = resolvedTitle
            recordingStartedAt = session.startedAt
            lastError = nil
            phase = .recording
        } catch {
            lastError = "Could not start recording: \(error)"
        }
    }

    func pause() {
        guard phase == .recording else { return }
        do { try engine.pause(); phase = .paused }
        catch { lastError = "\(error)" }
    }

    func resume() {
        guard phase == .paused else { return }
        do { try engine.resume(); phase = .recording }
        catch { lastError = "\(error)" }
    }

    /// −50 dBFS (SPEC R16).
    static let silenceThreshold: Float = 0.00316

    func stop() {
        guard phase == .recording || phase == .paused, var session = currentSession else { return }
        do {
            let result = try engine.stop()
            session.recordedDuration = result.recordedDuration
            session.pauseSpans = result.pauseSpans.map {
                Transcript.PauseMarker(atRecordedSeconds: $0.atRecordedSeconds,
                                       wallGapSeconds: $0.wallGapSeconds)
            }
            let silent = result.remotePeak < Self.silenceThreshold
            currentSession = nil
            recordingStartedAt = nil
            phase = .idle
            let queue = self.queue
            Task {
                await queue?.enqueue(session: session, remoteSilent: silent)
                await self.refreshJobState()
            }
        } catch {
            lastError = "Could not stop recording: \(error)"
            phase = .idle
        }
    }

    /// Throws the current Session away: stops capture, deletes the Recording,
    /// queues nothing. The caller confirms first — this is the one action in the
    /// app that destroys something the user cannot get back.
    func discard() {
        guard phase == .recording || phase == .paused, let session = currentSession else { return }
        let dir = JobQueue.appSupportURL.appendingPathComponent("jobs")
            .appendingPathComponent(session.id)
        _ = try? engine.stop()
        currentSession = nil
        recordingStartedAt = nil
        currentTitle = ""
        phase = .idle
        try? FileManager.default.removeItem(at: dir)
    }

    func retry(jobID: String) {
        let queue = self.queue
        Task {
            await queue?.retry(id: jobID)
            await self.refreshJobState()
        }
    }
}

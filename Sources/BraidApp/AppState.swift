import Foundation
import AppKit
import Observation
import ServiceManagement
import BraidCore

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
    var failedJobs: [BraidCore.Job] = [] { didSet { onChange?() } }
    /// In flight or waiting, so they can be cancelled before they cost anything.
    var activeJobs: [BraidCore.Job] = [] { didSet { onChange?() } }
    /// Cancelled but still holding their Recording, awaiting process or delete.
    var cancelledJobs: [BraidCore.Job] = [] { didSet { onChange?() } }
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

    /// Set when a call app has let go of the mic and the Session is about to
    /// stop by itself. The HUD counts down against it and offers a way out.
    var autoEndDeadline: Date? { didSet { onChange?() } }

    let engine = CaptureEngine()
    private var queue: JobQueue?
    private var currentSession: Session?
    private var namer: SpeakerNamer?
    private var callWatcher: CallWatcher?
    private var autoEndTimer: Timer?

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
        Notifier.onApplyName = { [weak self] sessionID in
            self?.applyOneToOneCandidate(sessionID: sessionID)
        }
        // Launch at login (SPEC R15); only meaningful from the installed bundle.
        if Bundle.main.bundleIdentifier == "no.braid.app" {
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
                Notifier.notify(title: "Braid: processing failed",
                                body: job.lastError ?? "Unknown error — Retry from the menu")
            }
        case .remoteSilentWarning:
            Notifier.notify(title: "No system audio captured",
                            body: "Check the System Audio Recording permission. The note will only contain your side.")
        case .jobCancelled:
            break   // the user just asked for this; a notification would be noise
        case .speakersDetected(let job, let stats, let mismatch):
            refreshNamingState()
            let count = stats.count
            let candidate = transcripts.load(job.id)?.oneToOneCandidate
            var body = job.session.title
            if let mismatch {
                body += " — \(mismatch.message)"
            } else if let candidate {
                body += " — one voice heard. Apply \u{201C}\(candidate.name)\u{201D}?"
            } else {
                body += " — name them from the menu to rewrite the note."
            }
            Notifier.notifySpeakers(
                sessionID: job.id,
                title: "\(count) speaker\(count == 1 ? "" : "s") to name",
                body: body,
                offerApply: candidate != nil)
        }
        Task { await refreshJobState() }
    }

    func refreshJobState() async {
        guard let queue else { return }
        processingCount = await queue.pendingCount()
        failedJobs = await queue.failedJobs()
        activeJobs = await queue.activeJobs()
        cancelledJobs = await queue.cancelledJobs()
    }

    /// Stops a Job before it spends anything more. The Recording is kept, so
    /// the choice is only about money, never about losing audio.
    func cancelJob(id: String) {
        let queue = self.queue
        Task {
            await queue?.cancel(id: id)
            await self.refreshJobState()
        }
    }

    /// Deletes a cancelled Job's Recording. Callers confirm first.
    func discardJob(id: String) {
        let queue = self.queue
        Task {
            await queue?.discard(id: id)
            await self.refreshJobState()
        }
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

    /// The notification's Apply button: the user has confirmed the 1:1
    /// candidate, so this is explicit action, not auto-assignment (R6a).
    func applyOneToOneCandidate(sessionID: String) {
        guard let candidate = transcripts.load(sessionID)?.oneToOneCandidate else { return }
        applyNames([candidate.speaker: candidate.name], toSessionID: sessionID) { _ in }
    }

    // MARK: - Session control

    func start(title: String, presetName: String, participants: String,
               speakerCount: Int? = nil, speakersStrict: Bool = false) {
        guard phase == .idle else { return }
        bootstrap()
        let names = participants
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let resolvedTitle = title.trimmingCharacters(in: .whitespaces).isEmpty
            ? presetName
            : title.trimmingCharacters(in: .whitespaces)
        let expectation = speakerCount.map {
            Session.SpeakerExpectation(count: $0, strict: speakersStrict)
        }
        let session = Session(title: resolvedTitle, presetName: presetName,
                              participants: names, expectedSpeakers: expectation,
                              startedAt: Date())
        let dir = JobQueue.appSupportURL.appendingPathComponent("jobs")
            .appendingPathComponent(session.id)
        do {
            try engine.start(into: dir)
            currentSession = session
            currentTitle = resolvedTitle
            recordingStartedAt = session.startedAt
            lastError = nil
            phase = .recording
            startCallWatcher()
        } catch {
            lastError = "Could not start recording: \(error)"
        }
    }

    // MARK: - Auto-end

    /// How long the HUD counts down before stopping on its own.
    static let autoEndGrace: TimeInterval = 30

    private func startCallWatcher() {
        guard settings.autoEndEnabled else { return }
        let watcher = CallWatcher(bundleIDs: settings.callAppBundleIDs) { [weak self] in
            Task { @MainActor in self?.callEnded() }
        }
        callWatcher = watcher
        watcher.start()
    }

    private func stopCallWatcher() {
        callWatcher?.stop()
        callWatcher = nil
        cancelAutoEndTimer()
        autoEndDeadline = nil
    }

    private func cancelAutoEndTimer() {
        autoEndTimer?.invalidate()
        autoEndTimer = nil
    }

    /// The call app released the microphone. Warn rather than stop outright: a
    /// false positive that ends a live meeting is far worse than a recording
    /// that runs 30 seconds long.
    private func callEnded() {
        guard phase == .recording || phase == .paused, autoEndDeadline == nil else { return }
        let deadline = Date().addingTimeInterval(Self.autoEndGrace)
        autoEndDeadline = deadline
        Notifier.notify(title: "Call ended",
                        body: "Stopping in \(Int(Self.autoEndGrace)) seconds. Open Braid to keep recording.")
        let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.autoEndFired() }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoEndTimer = timer
    }

    private func autoEndFired() {
        guard autoEndDeadline != nil, phase == .recording || phase == .paused else { return }
        autoEndDeadline = nil
        stop()
    }

    /// "Keep recording": stand the countdown down and wait for a fresh call
    /// before arming again.
    func cancelAutoEnd() {
        cancelAutoEndTimer()
        autoEndDeadline = nil
        callWatcher?.keepRecording()
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
        stopCallWatcher()
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
        stopCallWatcher()
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

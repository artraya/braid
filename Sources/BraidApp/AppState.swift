import Foundation
import AppKit
import Observation
import ServiceManagement
import BraidCore
import BraidMLX

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
    /// Why the local models could not be prepared, shown in Settings. Separate
    /// from `lastError`, which drives the menu-bar error state: a model that
    /// has not downloaded yet is a setup step, not a failed recording.
    var localModelError: String? { didSet { onChange?() } }
    var currentTitle = ""
    var recordingStartedAt: Date?
    let settings: SettingsStore
    let transcripts: TranscriptStore
    let sessions: SessionIndex
    let voices: VoiceStore
    let clips: VoiceClipStore
    var onChange: (() -> Void)?

    /// Injectable so `--ui-preview` can run against a scratch defaults suite
    /// rather than reading, or writing, the real settings.
    init(settings: SettingsStore = SettingsStore(),
         transcripts: TranscriptStore = TranscriptStore(),
         sessions: SessionIndex = SessionIndex(),
         voices: VoiceStore = VoiceStore(),
         clips: VoiceClipStore = VoiceClipStore()) {
        self.settings = settings
        self.transcripts = transcripts
        self.sessions = sessions
        self.voices = voices
        self.clips = clips
    }

    /// The people Braid can recognise, for the Settings list (R29).
    var knownPeople: [Person] = []
    /// Set when the on-device model cannot write Notes right now.
    var summariserProblem: String?
    /// Progress while the open-weights model downloads, nil when idle.
    var modelDownload: String? { didSet { onChange?() } }

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

    /// Setup is one decision now: where the Vault is. No accounts, no keys
    /// (R13, ADR-0006).
    var setupComplete: Bool { settings.vaultPath != nil }

    /// Applies an Engine change to the running queue.
    func applyEngineSettings() {
        guard let queue else { return }
        let transcriber = Transcriber.make(engine: settings.localEngine)
        let summariser = makeSummariser()
        Task {
            await queue.updateTranscriber(transcriber)
            await queue.updateSummariser(summariser)
        }
    }

    /// The chosen Note writer. The MLX model is only constructed when it is
    /// actually selected, so choosing Apple's never touches the open-weights
    /// path at all.
    func makeSummariser() -> any NoteSummarising {
        switch settings.summaryEngine {
        case .appleBuiltIn:
            return AppleSummariser()
        case .openWeights:
            let model = MLXSummariser.Model(rawValue: settings.openWeightsModel) ?? .qwen3_4b
            return MLXSummariser(model: model)
        case .cloud:
            return GeminiSummariser(model: settings.cloudModel, rates: settings.cloudRates)
        }
    }

    /// Loads the on-device models so the first Session after switching does not
    /// stall, and checks that the Summariser can actually run. Safe to call
    /// repeatedly.
    func prepareLocalModels() {
        let engine = settings.localEngine
        let settings = self.settings
        // Apple's engine and the cloud both have an availability answer — one
        // about Apple Intelligence, one about a missing key. The open-weights
        // one either downloads or reports why it could not.
        switch settings.summaryEngine {
        case .appleBuiltIn: summariserProblem = AppleSummariser.availability
        case .cloud: summariserProblem = GeminiSummariser(model: settings.cloudModel).availability
        case .openWeights: summariserProblem = nil
        }
        let openWeights: MLXSummariser? = settings.summaryEngine == .openWeights
            ? MLXSummariser(model: MLXSummariser.Model(rawValue: settings.openWeightsModel) ?? .qwen3_4b)
            : nil
        Task {
            do {
                try await Transcriber.make(engine: engine).prepare()
                if let openWeights {
                    await MainActor.run { self.modelDownload = "Fetching the summary model…" }
                    try await openWeights.prepare { fraction in
                        Task { @MainActor in
                            self.modelDownload = fraction < 1
                                ? "Fetching the summary model… \(Int(fraction * 100))%"
                                : nil
                        }
                    }
                }
                await MainActor.run {
                    settings.localModelsInstalled = true
                    self.localModelError = nil
                    self.modelDownload = nil
                }
            } catch {
                await MainActor.run {
                    self.localModelError = "\(error)"
                    self.modelDownload = nil
                }
            }
        }
    }

    // MARK: - The Voice Database (R29)

    func refreshPeople() {
        let voices = self.voices
        Task {
            let people = await voices.persons()
            await MainActor.run { self.knownPeople = people }
        }
    }

    func renamePerson(id: String, to name: String) {
        let voices = self.voices
        Task {
            await voices.rename(personID: id, to: name)
            await MainActor.run { self.refreshPeople() }
        }
    }

    func forgetPerson(id: String) {
        let voices = self.voices
        Task {
            await voices.forget(personID: id)
            await MainActor.run { self.refreshPeople() }
        }
    }

    func forgetEveryone() {
        let voices = self.voices
        Task {
            await voices.deleteEverything()
            await MainActor.run { self.refreshPeople() }
        }
    }

    func exportVoices(to url: URL) {
        let voices = self.voices
        Task {
            do { try await voices.export(to: url) }
            catch { await MainActor.run { self.lastError = "Could not export: \(error)" } }
        }
    }

    func importVoices(from url: URL) {
        let voices = self.voices
        Task {
            do {
                try await voices.importDatabase(from: url)
                await MainActor.run { self.refreshPeople() }
            } catch {
                await MainActor.run {
                    self.lastError = "Could not import: the file is not a voice database from this app's model version."
                }
            }
        }
    }

    // MARK: - Lifecycle

    func bootstrap() {
        guard queue == nil else { return }
        let env = JobQueue.Environment(
            transcriber: Transcriber.make(engine: settings.localEngine),
            summariser: makeSummariser(),
            settings: settings,
            voices: voices,
            clips: clips,
            transcripts: transcripts,
            sessions: sessions,
            onEvent: { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            })
        let queue = JobQueue(env: env)
        self.queue = queue
        transcripts.purgeExpired()
        summariserProblem = AppleSummariser.availability
        refreshNamingState()
        refreshSessions()
        refreshPeople()
        refreshCloudKeyState()
        // Clips belong to a Session whose naming record is still around, named
        // or not — that is the window in which Re-naming can reach it. Once the
        // record ages out at 30 days the clips are audio with no reason to
        // exist, and `purgeExpired` above has just made them orphans (R25).
        clips.purgeOrphans(keeping: Set(transcripts.all().map(\.id)))
        Task {
            await queue.loadPersisted()
            await self.refreshJobState()
        }
        Notifier.requestPermission()
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
        case .echoBleedWarning:
            Notifier.notify(
                title: "Recorded on speakers",
                body: "The far end leaked into your mic. Duplicated lines will be removed — headphones avoid this next time.")
        case .speakersDetected(let job, let stats, let mismatch):
            refreshNamingState()
            let count = stats.count
            let body = job.session.title + (mismatch.map { " — \($0.message)" }
                ?? " — name them to rewrite the note.")
            Notifier.notifySpeakers(
                sessionID: job.id,
                title: "\(count) voice\(count == 1 ? "" : "s") to name",
                body: body)
        case .heldForNames(let job, let stats, let mismatch):
            // R26: nothing is written yet, so the notification has to say that
            // plainly — otherwise a Note that never arrives reads as a failure.
            refreshNamingState()
            let count = stats.count
            let body = job.session.title + " — the note is waiting on these names."
                + (mismatch.map { " \($0.message)" } ?? "")
            Notifier.notifySpeakers(
                sessionID: job.id,
                title: "\(count) voice\(count == 1 ? "" : "s") to name",
                body: body)
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
        let all = transcripts.all()
        awaitingNames = all.filter { !$0.namesApplied }
        // Every record still inside its retention window can be re-opened, not
        // just the ones still asking. A name Braid applied on its own
        // confidence is the one kind that reaches the Vault without anybody
        // checking it, so noticing it was wrong a week later has to lead
        // somewhere.
        renamable = Set(all.map(\.id))
    }

    /// Session ids whose naming record is still around, so History can offer
    /// Re-name. Ids rather than records: the row only needs to know whether the
    /// button belongs there.
    var renamable: Set<String> = [] { didSet { onChange?() } }

    var cloudTokensUsed: Int { settings.cloudTokensUsed }

    /// What the cloud has consumed. Tokens always, because they are measured;
    /// dollars only once someone has filled in a rate, because an invented
    /// figure is worse than none (R14).
    var cloudUsageLine: String {
        let tokens = settings.cloudTokensUsed
        let formatted = tokens.formatted(.number.grouping(.automatic))
        guard settings.cloudSpendUSD > 0 else {
            return "\(formatted) tokens so far. Set a rate in Settings to see spend."
        }
        return String(format: "%@ tokens so far · $%.2f", formatted, settings.cloudSpendUSD)
    }

    /// True when a Gemini key is stored. The key itself is never read into the
    /// UI — Settings can set or clear it, never display it.
    ///
    /// Cached, and deliberately not a computed property that asks the store.
    /// Reading it unseals a file with the Keychain-held key, and a SwiftUI body
    /// is evaluated far too often for that: as a computed property it hit the
    /// Keychain on every re-render, and in a headless render with no window
    /// server to show an authorisation prompt it simply never returned.
    private(set) var hasCloudKey = false { didSet { onChange?() } }

    func refreshCloudKeyState() {
        hasCloudKey = APIKeyStore().hasKey
    }

    func setCloudKey(_ value: String) {
        APIKeyStore().save(value)
        refreshCloudKeyState()
        prepareLocalModels()
    }

    func refreshSessions() {
        recentSessions = sessions.recent(20)
        usage = sessions.usage()
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

    /// Puts names to a Session's voices and teaches the Voice Database what it
    /// just learned (R24). A delivered Session is re-summarised and rewritten;
    /// a Held one is summarised and written for the first time (R26).
    func applyNames(_ names: [String: String], toSessionID id: String,
                    completion: @escaping (Result<URL, Error>) -> Void) {
        bootstrap()
        guard let queue else {
            completion(.failure(PipelineError.permanent("the pipeline is not running")))
            return
        }
        Task {
            do {
                let noteURL = try await queue.applyNames(sessionID: id, names: names)
                self.refreshNamingState()
                self.refreshSessions()
                self.refreshPeople()
                await self.refreshJobState()
                Notifier.notify(title: "Note updated",
                                body: noteURL.deletingPathExtension().lastPathComponent)
                completion(.success(noteURL))
            } catch {
                self.lastError = "Could not apply names: \(error)"
                completion(.failure(error))
            }
        }
    }

    /// R25: the user would rather not name these. That resolves the Session —
    /// the clips go, and a Held Session delivers with generic labels.
    func skipNaming(sessionID: String) {
        bootstrap()
        let queue = self.queue
        Task {
            do {
                _ = try await queue?.skipNaming(sessionID: sessionID)
                self.refreshNamingState()
                self.refreshSessions()
                await self.refreshJobState()
            } catch {
                self.lastError = "Could not skip naming: \(error)"
            }
        }
    }

    // MARK: - Session control

    /// Starts a Session. Nothing is asked for that Braid can work out itself:
    /// the Preset comes from Settings and the title comes from the summary
    /// afterwards (R9a), so the only thing the panel passes in is who is on the
    /// call and how many voices to expect.
    func start(participants: [String], speakerCount: Int? = nil,
               speakersStrict: Bool = false) {
        guard phase == .idle else { return }
        bootstrap()
        let names = participants
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let startedAt = Date()
        let placeholder = Session.placeholderTitle(at: startedAt)
        let expectation = speakerCount.map {
            Session.SpeakerExpectation(count: $0, strict: speakersStrict)
        }
        let session = Session(title: placeholder,
                              presetName: settings.defaultPresetName,
                              participants: names, expectedSpeakers: expectation,
                              startedAt: startedAt, autoTitled: true)
        let dir = JobQueue.appSupportURL.appendingPathComponent("jobs")
            .appendingPathComponent(session.id)
        do {
            try engine.start(into: dir)
            currentSession = session
            currentTitle = placeholder
            recordingStartedAt = session.startedAt
            lastError = nil
            phase = .recording
            // Hold back local inference for the duration: capture has R4's
            // 100MB budget to itself, and the models peak far above it.
            let queue = self.queue
            Task { await queue?.setRecordingActive(true) }
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

    /// The recording block's speaker-bleed line: correlation proof outranks
    /// the device prior; silence when neither applies (echo cycle).
    var bleedWarning: String? {
        guard phase != .idle else { return nil }
        if engine.bleedDetector.verdict.confirmed {
            return "Speakers are bleeding into your mic — plug in headphones. Duplicates will be cleaned from the note."
        }
        if engine.speakerOutputLikely {
            return "Playing through speakers — the far end may bleed into your mic. Headphones fix it."
        }
        return nil
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
            session.bleedDetected = result.bleedDetected
            let silent = result.remotePeak < Self.silenceThreshold
            currentSession = nil
            recordingStartedAt = nil
            phase = .idle
            let queue = self.queue
            Task {
                // Releases anything held back during the recording, then adds
                // this Session behind it.
                await queue?.setRecordingActive(false)
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
        // Nothing is queued for this Session, but earlier Jobs held back for
        // the recording are free to run again.
        let queue = self.queue
        Task { await queue?.setRecordingActive(false) }
    }

    func retry(jobID: String) {
        let queue = self.queue
        Task {
            await queue?.retry(id: jobID)
            await self.refreshJobState()
        }
    }
}

import Foundation
import os

/// One Job: the post-Stop pipeline run for a Session (CONTEXT.md):
/// upload → transcribe → summarise → write Transcript and Note → delete Recording.
public struct Job: Sendable, Codable, Identifiable {
    public enum Status: String, Sendable, Codable {
        case queued          // waiting to run (or retry after transient failure)
        case running
        case failed          // non-transient; waits for user-initiated Retry (R7)
        case cancelled       // user stopped it before the cloud was paid for
        case done
    }

    public var id: String { session.id }
    public var session: Session
    public var status: Status
    public var attempts: Int
    public var lastError: String?
    /// Set when the Remote Track never exceeded −50 dBFS (R16).
    public var remoteSilent: Bool
    public var noteURL: String?

    public init(session: Session, remoteSilent: Bool) {
        self.session = session
        self.status = .queued
        self.attempts = 0
        self.lastError = nil
        self.remoteSilent = remoteSilent
        self.noteURL = nil
    }
}

/// Serial Job runner with JSON state per Job in Application Support (SPEC
/// Architecture: State). Transient failures re-queue with exponential backoff
/// (30s doubling, capped 10 min); non-transient failures park as `.failed`
/// until user Retry (R7/R8). The Recording is deleted only after both the
/// Note and Transcript are confirmed on disk (R7).
public actor JobQueue {
    public static let appSupportURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Braid")

    public struct Environment: Sendable {
        public var provider: STTProvider
        public var summariser: any NoteSummarising
        public var settings: SettingsStore
        public var costTable: CostTable
        public var jobsRoot: URL
        public var transcripts: TranscriptStore
        public var sessions: SessionIndex
        /// Called on status changes so the UI can react (icon state, notifications).
        public var onEvent: @Sendable (Event) -> Void

        public init(provider: STTProvider, summariser: any NoteSummarising, settings: SettingsStore,
                    costTable: CostTable = .current,
                    jobsRoot: URL = JobQueue.appSupportURL.appendingPathComponent("jobs"),
                    transcripts: TranscriptStore = TranscriptStore(),
                    sessions: SessionIndex = SessionIndex(),
                    onEvent: @escaping @Sendable (Event) -> Void = { _ in }) {
            self.provider = provider
            self.summariser = summariser
            self.settings = settings
            self.costTable = costTable
            self.jobsRoot = jobsRoot
            self.transcripts = transcripts
            self.sessions = sessions
            self.onEvent = onEvent
        }
    }

    public enum Event: Sendable {
        case jobStarted(Job)
        case jobDone(Job, noteURL: URL)
        case jobFailed(Job, transient: Bool)
        case remoteSilentWarning(Job)
        /// The Note is already written; these are the Remote speakers the user
        /// may want to put names to, and any heard-vs-expected disagreement.
        case speakersDetected(Job, [Transcript.SpeakerStat], Session.SpeakerCountMismatch?)
        case jobCancelled(Job)
    }

    let log = Logger(subsystem: "no.braid.app", category: "pipeline")
    var env: Environment
    var jobs: [String: Job] = [:]
    var runnerActive = false
    /// The Job currently in flight, held so it can be cancelled mid-upload.
    var currentJobID: String?
    var currentTask: Task<URL, Error>?

    public init(env: Environment) {
        self.env = env
    }

    // MARK: - Public API

    /// Loads persisted Jobs from disk (crash/relaunch recovery) and resumes
    /// queued ones. Jobs found `running` were interrupted — re-queue them.
    public func loadPersisted() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: env.jobsRoot,
                includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  var job = try? JSONDecoder().decode(Job.self, from: data) else { continue }
            // Finished Jobs have nothing to resume; drop their state file.
            if job.status == .done { try? fm.removeItem(at: file); continue }
            // A Job found `running` was interrupted mid-flight — re-queue it.
            if job.status == .running { job.status = .queued }
            jobs[job.id] = job
        }
        log.notice("loaded \(self.jobs.count) persisted jobs")
        kickRunner()
    }

    /// Directory a new Session should record into.
    public nonisolated static func recordingDirectory(root: URL, sessionID: String) -> URL {
        root.appendingPathComponent(sessionID)
    }

    /// Enqueues a finished Session whose Recording sits in its Job directory.
    public func enqueue(session: Session, remoteSilent: Bool) {
        var job = Job(session: session, remoteSilent: remoteSilent)
        if remoteSilent {
            env.onEvent(.remoteSilentWarning(job))
            log.warning("no system audio captured for \(job.id, privacy: .public) — check permission (R16)")
        }
        job.status = .queued
        jobs[job.id] = job
        persist(job)
        kickRunner()
    }

    /// User-initiated Retry for a `.failed` or `.cancelled` Job (R7).
    public func retry(id: String) {
        guard var job = jobs[id], job.status == .failed || job.status == .cancelled else { return }
        job.status = .queued
        job.lastError = nil
        jobs[id] = job
        persist(job)
        kickRunner()
    }

    /// Stops a Job before it costs anything more, and keeps its Recording.
    ///
    /// The point is money: a Session started by mistake would otherwise upload
    /// two Tracks and pay for a summary with no one wanting the note. Cancelling
    /// mid-flight tears down the in-flight request, so whatever has not been
    /// billed yet never is. Anything already billed stays billed — the upload
    /// cannot be unsent.
    ///
    /// The Recording is deliberately kept. Cancelling is a decision about
    /// spending, not about throwing audio away, and R7's rule that only a
    /// confirmed-success Job may delete a Recording still holds. `discard`
    /// deletes it, once the user says so.
    public func cancel(id: String) {
        guard var job = jobs[id], job.status == .queued || job.status == .running else { return }
        if currentJobID == id {
            currentTask?.cancel()
        }
        job.status = .cancelled
        job.lastError = nil
        jobs[id] = job
        persist(job)
        log.notice("job \(id, privacy: .public) cancelled by user")
        env.onEvent(.jobCancelled(job))
    }

    /// Deletes a cancelled or failed Job's Recording and forgets it. The only
    /// path in the app that destroys audio no Note was written from, so callers
    /// confirm first.
    public func discard(id: String) {
        guard let job = jobs[id], job.status != .running else { return }
        try? FileManager.default.removeItem(at: env.jobsRoot.appendingPathComponent(id))
        try? FileManager.default.removeItem(
            at: env.jobsRoot.appendingPathComponent("\(id).json"))
        jobs[id] = nil
        log.notice("job \(job.id, privacy: .public) discarded, recording deleted")
    }

    public func allJobs() -> [Job] { Array(jobs.values) }
    public func failedJobs() -> [Job] { jobs.values.filter { $0.status == .failed } }
    public func cancelledJobs() -> [Job] { jobs.values.filter { $0.status == .cancelled } }
    /// Jobs in flight or waiting, newest first, so the panel can offer Cancel.
    public func activeJobs() -> [Job] {
        jobs.values
            .filter { $0.status == .queued || $0.status == .running }
            .sorted { $0.session.startedAt > $1.session.startedAt }
    }
    public func pendingCount() -> Int { activeJobs().count }

    // MARK: - Runner

    func kickRunner() {
        guard !runnerActive else { return }
        runnerActive = true
        Task { await runLoop() }
    }

    func runLoop() async {
        defer { runnerActive = false }
        while let next = jobs.values.first(where: { $0.status == .queued }) {
            await run(jobID: next.id)
        }
    }

    func run(jobID: String) async {
        guard var job = jobs[jobID] else { return }
        job.status = .running
        job.attempts += 1
        jobs[jobID] = job
        persist(job)
        env.onEvent(.jobStarted(job))
        log.notice("job \(jobID, privacy: .public) started (attempt \(job.attempts))")

        // Run in a child Task so `cancel` can tear it down mid-flight: while
        // this awaits, the actor stays free to take that call.
        let task = Task { try await self.execute(job) }
        currentJobID = jobID
        currentTask = task
        defer { currentJobID = nil; currentTask = nil }

        do {
            let noteURL = try await task.value
            job.status = .done
            job.noteURL = noteURL.path
            job.lastError = nil
            jobs[jobID] = job
            persist(job)
            env.onEvent(.jobDone(job, noteURL: noteURL))
            log.notice("job \(jobID, privacy: .public) done -> \(noteURL.lastPathComponent, privacy: .public)")
        } catch {
            let pipelineError = error as? PipelineError
                ?? (error is CancellationError ? .cancelled : .permanent("\(error)"))

            // `cancel` has already set the status and told the UI. Anything the
            // torn-down request threw on the way out is noise, not a failure.
            if pipelineError.isCancellation || jobs[jobID]?.status == .cancelled {
                log.notice("job \(jobID, privacy: .public) stopped after cancellation")
                return
            }

            job.lastError = pipelineError.description
            if pipelineError.isTransient {
                job.status = .queued
                jobs[jobID] = job
                persist(job)
                env.onEvent(.jobFailed(job, transient: true))
                let delay = min(600, 30.0 * pow(2, Double(max(0, job.attempts - 1))))
                log.warning("job \(jobID, privacy: .public) transient failure, backing off \(Int(delay))s: \(pipelineError.description, privacy: .public)")
                try? await Task.sleep(for: .seconds(delay))
            } else {
                job.status = .failed
                jobs[jobID] = job
                persist(job)
                env.onEvent(.jobFailed(job, transient: false))
                log.error("job \(jobID, privacy: .public) failed: \(pipelineError.description, privacy: .public)")
            }
        }
    }

    /// The pipeline itself. Throws PipelineError; only reaching the end
    /// deletes the Recording.
    func execute(_ job: Job) async throws -> URL {
        let dir = env.jobsRoot.appendingPathComponent(job.id)
        let micCAF = dir.appendingPathComponent("mic.caf")
        let remoteCAF = dir.appendingPathComponent("remote.caf")
        guard let vaultPath = env.settings.vaultPath else {
            throw PipelineError.permanent("no Vault path configured")
        }

        // Cancellation is checked before each expensive or billable step.
        // Transcoding an hour of audio is slow, and everything after it costs
        // money, so a cancel landing here must not push on regardless.
        try checkCancelled()

        // Transcode to FLAC for upload (kept beside the CAF originals).
        let micFLAC = try Transcoder.toFLAC(micCAF)
        let remoteFLAC = try Transcoder.toFLAC(remoteCAF)

        try checkCancelled()

        // R6 (amended): the Mic Track has exactly one speaker, so it goes
        // without diarization and is labelled "Me". The Remote Track is
        // diarized; a speaker count rides along only when the user asserted
        // one at Start — never derived from Participants (see
        // AssemblyAIAdapter.requestBody). Participants do join the Key Terms,
        // so the names R11 needs as evidence arrive spelled correctly.
        let keyTerms = job.session.mergedKeyTerms(global: env.settings.keyTerms)

        async let micTask = env.provider.transcribe(
            track: micFLAC, diarize: false, keyTerms: keyTerms, expectedSpeakers: nil)
        async let remoteTask = env.provider.transcribe(
            track: remoteFLAC, diarize: true, keyTerms: keyTerms,
            expectedSpeakers: job.session.expectedSpeakers)
        let (micUtterances, remoteUtterances) = try await (micTask, remoteTask)

        let transcript = mergeTranscripts(
            mic: micUtterances, remote: remoteUtterances,
            pauseSpans: job.session.pauseSpans)

        // Transcription is paid for by now; the summary is not.
        try checkCancelled()

        guard let preset = env.settings.presets.first(where: { $0.name == job.session.presetName })
                ?? env.settings.presets.first else {
            throw PipelineError.permanent("no Preset named \(job.session.presetName)")
        }
        let summary = try await env.summariser.summarise(
            transcript: transcript, session: job.session, preset: preset)

        // Cost (R10/R14): per submitted Track + Claude tokens.
        let trackHours = job.session.recordedDuration / 3600
        let cost = env.costTable.sttCost(trackHours: trackHours, diarized: false,
                                         keyterms: !keyTerms.isEmpty)
            + env.costTable.sttCost(trackHours: trackHours, diarized: true,
                                    keyterms: !keyTerms.isEmpty)
            + env.costTable.claudeCost(inputTokens: summary.inputTokens,
                                       outputTokens: summary.outputTokens)

        // Write Note + Transcript into the Vault (atomic, R9/R10).
        let writer = VaultWriter(vaultURL: URL(fileURLWithPath: vaultPath))
        let written: VaultWriter.Written
        do {
            written = try writer.write(session: job.session, noteBody: summary.noteBody,
                                       transcript: transcript,
                                       provider: env.provider.name, costUSD: cost)
        } catch {
            throw PipelineError.permanent("Vault write: \(error.localizedDescription)")
        }

        // Verify both files exist before touching the Recording (R7).
        let fm = FileManager.default
        guard fm.fileExists(atPath: written.noteURL.path),
              fm.fileExists(atPath: written.transcriptURL.path) else {
            throw PipelineError.permanent("Vault write verification failed")
        }

        env.settings.addCost(cost)
        env.sessions.add(SessionRecord(session: job.session, costUSD: cost,
                                       notePath: written.noteURL.path))

        // Keep the structured Transcript so speakers can be named later. The
        // Vault only holds markdown, and the Recording is about to go. Any
        // heard-vs-expected mismatch is computed here, after delivery, so it
        // can only ever inform — never block (Journey step 7 stays hands-off).
        let stats = transcript.remoteSpeakerStats()
        if !stats.isEmpty {
            let mismatch = job.session.speakerMismatch(heardRemoteSpeakers: stats.count)
            if let mismatch {
                log.warning("speaker mismatch for \(job.id, privacy: .public): \(mismatch.message, privacy: .public)")
            }
            let noteContents = (try? String(contentsOf: written.noteURL, encoding: .utf8)) ?? ""
            env.transcripts.save(NamingRecord(
                session: job.session, transcript: transcript, provider: env.provider.name,
                costUSD: cost, notePath: written.noteURL.path,
                transcriptPath: written.transcriptURL.path,
                noteHash: NamingRecord.hash(noteContents),
                speakerMismatch: mismatch))
            env.onEvent(.speakersDetected(job, stats, mismatch))
        }

        // Only a confirmed-success Job may delete a Recording (Operation).
        try? fm.removeItem(at: dir)
        return written.noteURL
    }

    /// Throws `.cancelled` if the user has stopped this Job. Used at the points
    /// where continuing would cost money or a lot of time.
    nonisolated func checkCancelled() throws {
        if Task.isCancelled { throw PipelineError.cancelled }
    }

    // MARK: - Persistence

    /// Job state lives *beside* the Recording directory, never inside it —
    /// writing state into `<jobsRoot>/<id>/` would recreate the directory the
    /// pipeline just deleted on success (R7).
    func persist(_ job: Job) {
        try? FileManager.default.createDirectory(at: env.jobsRoot, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(job) {
            try? data.write(to: env.jobsRoot.appendingPathComponent("\(job.id).json"),
                            options: .atomic)
        }
    }
}

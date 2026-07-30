import Foundation
import os

/// One Job: the post-Stop pipeline run for a Session (CONTEXT.md):
/// upload → transcribe → summarise → write Transcript and Note → delete Recording.
public struct Job: Sendable, Codable, Identifiable {
    public enum Status: String, Sendable, Codable {
        case queued          // waiting to run (or retry after transient failure)
        case running
        case failed          // non-transient; waits for user-initiated Retry (R7)
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
        .appendingPathComponent("ms-notes")

    public struct Environment: Sendable {
        public var provider: STTProvider
        public var summariser: Summariser
        public var settings: SettingsStore
        public var costTable: CostTable
        public var jobsRoot: URL
        /// Called on status changes so the UI can react (icon state, notifications).
        public var onEvent: @Sendable (Event) -> Void

        public init(provider: STTProvider, summariser: Summariser, settings: SettingsStore,
                    costTable: CostTable = .current,
                    jobsRoot: URL = JobQueue.appSupportURL.appendingPathComponent("jobs"),
                    onEvent: @escaping @Sendable (Event) -> Void = { _ in }) {
            self.provider = provider
            self.summariser = summariser
            self.settings = settings
            self.costTable = costTable
            self.jobsRoot = jobsRoot
            self.onEvent = onEvent
        }
    }

    public enum Event: Sendable {
        case jobStarted(Job)
        case jobDone(Job, noteURL: URL)
        case jobFailed(Job, transient: Bool)
        case remoteSilentWarning(Job)
    }

    let log = Logger(subsystem: "no.msnotes.app", category: "pipeline")
    var env: Environment
    var jobs: [String: Job] = [:]
    var runnerActive = false

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

    /// User-initiated Retry for a `.failed` Job (R7).
    public func retry(id: String) {
        guard var job = jobs[id], job.status == .failed else { return }
        job.status = .queued
        job.lastError = nil
        jobs[id] = job
        persist(job)
        kickRunner()
    }

    public func allJobs() -> [Job] { Array(jobs.values) }
    public func failedJobs() -> [Job] { jobs.values.filter { $0.status == .failed } }
    public func pendingCount() -> Int {
        jobs.values.filter { $0.status == .queued || $0.status == .running }.count
    }

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

        do {
            let noteURL = try await execute(job)
            job.status = .done
            job.noteURL = noteURL.path
            job.lastError = nil
            jobs[jobID] = job
            persist(job)
            env.onEvent(.jobDone(job, noteURL: noteURL))
            log.notice("job \(jobID, privacy: .public) done -> \(noteURL.lastPathComponent, privacy: .public)")
        } catch {
            let pipelineError = error as? PipelineError ?? .permanent("\(error)")
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

        // Transcode to FLAC for upload (kept beside the CAF originals).
        let micFLAC = try Transcoder.toFLAC(micCAF)
        let remoteFLAC = try Transcoder.toFLAC(remoteCAF)

        // Speaker hints (R6): Mic Track has exactly one speaker — submitted
        // without diarization and labelled "Me". Remote Track range: 1 to
        // participants+1, or 6 with no Participants given.
        let speakerRange = AssemblyAIAdapter.remoteSpeakerRange(
            participantCount: job.session.participants.count)
        let keyTerms = env.settings.keyTerms

        async let micTask = env.provider.transcribe(
            track: micFLAC, diarize: false, speakerRange: nil, keyTerms: keyTerms)
        async let remoteTask = env.provider.transcribe(
            track: remoteFLAC, diarize: true, speakerRange: speakerRange, keyTerms: keyTerms)
        let (micUtterances, remoteUtterances) = try await (micTask, remoteTask)

        let transcript = mergeTranscripts(
            mic: micUtterances, remote: remoteUtterances,
            pauseSpans: job.session.pauseSpans)

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

        // Only a confirmed-success Job may delete a Recording (Operation).
        try? fm.removeItem(at: dir)
        return written.noteURL
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

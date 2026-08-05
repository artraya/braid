import Foundation
import os

/// One Job: the post-Stop pipeline run for a Session (CONTEXT.md):
/// transcribe → identify → summarise → write Transcript and Note → delete
/// Recording. Everything in it happens on this Mac.
public struct Job: Sendable, Codable, Identifiable {
    public enum Status: String, Sendable, Codable {
        case queued          // waiting to run (or retry after transient failure)
        case running
        /// Held Delivery, transcribed, waiting for the user to name voices
        /// (R26). Not a failure and not in flight: the Recording is retained
        /// and the Job finishes the moment names arrive.
        case awaitingNames
        case failed          // non-transient; waits for user-initiated Retry (R7)
        case cancelled       // user stopped it before it finished
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
        public var transcriber: any TrackTranscribing
        public var summariser: any NoteSummarising
        public var settings: SettingsStore
        public var voices: VoiceStore
        public var clips: VoiceClipStore
        public var identifier: VoiceIdentifier
        public var jobsRoot: URL
        public var transcripts: TranscriptStore
        public var sessions: SessionIndex
        /// Called on status changes so the UI can react (icon state, notifications).
        public var onEvent: @Sendable (Event) -> Void

        public init(transcriber: any TrackTranscribing,
                    summariser: any NoteSummarising,
                    settings: SettingsStore,
                    voices: VoiceStore = VoiceStore(),
                    clips: VoiceClipStore = VoiceClipStore(),
                    identifier: VoiceIdentifier = VoiceIdentifier(),
                    jobsRoot: URL = JobQueue.appSupportURL.appendingPathComponent("jobs"),
                    transcripts: TranscriptStore = TranscriptStore(),
                    sessions: SessionIndex = SessionIndex(),
                    onEvent: @escaping @Sendable (Event) -> Void = { _ in }) {
            self.transcriber = transcriber
            self.summariser = summariser
            self.settings = settings
            self.voices = voices
            self.clips = clips
            self.identifier = identifier
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
        /// The Note is written; these are the voices the user may want to name.
        case speakersDetected(Job, [Transcript.SpeakerStat], Session.SpeakerCountMismatch?)
        /// Held Delivery: nothing is written until these voices have names (R26).
        case heldForNames(Job, [Transcript.SpeakerStat], Session.SpeakerCountMismatch?)
        case jobCancelled(Job)
        /// The Session was recorded with confirmed speaker bleed; echoes will
        /// be cleaned from the Mic Track (echo cycle).
        case echoBleedWarning(Job)
    }

    let log = Logger(subsystem: "no.braid.app", category: "pipeline")
    var env: Environment
    var jobs: [String: Job] = [:]
    var runnerActive = false
    /// True while a Session is being recorded. Inference is held back until
    /// Stop: the models peak in the hundreds of MB, and R4 budgets 100MB for
    /// the whole app during a call on an 8GB machine. This is the condition
    /// ADR-0005 leans on when it argues the 8GB constraint does not apply to
    /// local ML — so it has to actually hold.
    var recordingActive = false
    /// The Job currently in flight, held so it can be cancelled mid-run.
    var currentJobID: String?
    var currentTask: Task<URL?, Error>?

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
        if session.bleedDetected == true {
            env.onEvent(.echoBleedWarning(job))
            log.warning("speaker bleed confirmed for \(job.id, privacy: .public) — echoes will be cleaned from the Mic Track")
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

    /// Stops a Job and keeps its Recording.
    ///
    /// The Recording is deliberately kept. Cancelling is a decision about not
    /// wanting this note now, not about throwing audio away, and R7's rule that
    /// only a confirmed-success Job may delete a Recording still holds.
    /// `discard` deletes it, once the user says so.
    public func cancel(id: String) {
        guard var job = jobs[id],
              job.status == .queued || job.status == .running
                || job.status == .awaitingNames else { return }
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
        env.clips.delete(sessionID: id)
        env.transcripts.remove(id)
        jobs[id] = nil
        log.notice("job \(job.id, privacy: .public) discarded, recording deleted")
    }

    /// Swaps the Transcriber after a settings change. Takes effect for the next
    /// Job; one already in flight finishes on the Engine it started with, so a
    /// Note is never assembled from two of them.
    public func updateTranscriber(_ transcriber: any TrackTranscribing) {
        env.transcriber = transcriber
        log.notice("engine set: \(transcriber.name, privacy: .public)")
    }

    /// Swaps the Note writer after a settings change. Same rule as the
    /// Transcriber: a Job already running finishes with the one it started on.
    public func updateSummariser(_ summariser: any NoteSummarising) {
        env.summariser = summariser
    }

    public func allJobs() -> [Job] { Array(jobs.values) }
    public func failedJobs() -> [Job] { jobs.values.filter { $0.status == .failed } }
    public func cancelledJobs() -> [Job] { jobs.values.filter { $0.status == .cancelled } }
    public func heldJobs() -> [Job] { jobs.values.filter { $0.status == .awaitingNames } }
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

    /// Held back while recording, so a Job never competes with capture for
    /// memory. Releasing it is `setRecordingActive(false)`, which kicks the
    /// runner again.
    public func setRecordingActive(_ active: Bool) {
        guard recordingActive != active else { return }
        recordingActive = active
        if !active { kickRunner() }
    }

    func runLoop() async {
        defer { runnerActive = false }
        while let next = jobs.values.first(where: { $0.status == .queued }) {
            if recordingActive {
                log.notice("holding Jobs until the recording stops")
                return
            }
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
            guard let noteURL else {
                // Held: transcribed and waiting for names, not finished.
                if jobs[jobID]?.status == .awaitingNames { persist(jobs[jobID]!) }
                return
            }
            // Take the stored copy back: `execute` may have retitled the
            // Session from the summary (R9a), and the local `job` still holds
            // the placeholder it started with.
            if let latest = jobs[jobID] { job = latest }
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
            // torn-down work threw on the way out is noise, not a failure.
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

    /// The pipeline itself. Throws PipelineError; returns nil when the Session
    /// is Held for naming. Only reaching the end deletes the Recording.
    func execute(_ job: Job) async throws -> URL? {
        let dir = env.jobsRoot.appendingPathComponent(job.id)
        let micCAF = dir.appendingPathComponent("mic.caf")
        let remoteCAF = dir.appendingPathComponent("remote.caf")
        guard env.settings.vaultPath != nil else {
            throw PipelineError.permanent("no Vault path configured")
        }
        try checkCancelled()

        // R6: the Mic Track has exactly one speaker, so it is never split. The
        // Remote Track is diarized; a speaker count rides along only when the
        // user asserted one at Start — never derived from Participants.
        // Participants do join the Key Terms, so the names R11 needs as
        // evidence arrive spelled correctly.
        let keyTerms = job.session.mergedKeyTerms(global: env.settings.keyTerms)
        let database = await env.voices.database()

        // R28: learn the owner's own voice while Braid has too few exemplars of
        // it, then stop. Only ever used to catch echo.
        let wantsMe = (database.me?.voiceprints.count ?? 0) < 3
        let mic = try await env.transcriber.transcribeMic(
            track: micCAF, keyTerms: keyTerms, wantsVoice: wantsMe)
        if let voice = mic.voices.first {
            await env.voices.enrollMe(voice)
        }

        try checkCancelled()

        // Always ask for voice data, even against an empty database. Matching
        // has nothing to do on the first ever Session, but *enrolling* does:
        // the centroid collected here is what naming turns into the first
        // Voiceprint. Skipping it when the database looks empty meant the first
        // person the user ever named taught Braid nothing, and there was no way
        // to bootstrap out of that. The per-chunk embeddings cost a megabyte or
        // two per audio-hour and are discarded with the Job.
        let known = database
        let remote = try await env.transcriber.transcribeRemote(
            track: remoteCAF, keyTerms: keyTerms,
            expectedSpeakers: job.session.expectedSpeakers, known: known)

        try checkCancelled()

        let merged = mergeTranscripts(mic: mic.utterances, remote: remote.utterances,
                                      pauseSpans: job.session.pauseSpans)
        var transcript = merged.transcript

        // Echo cycle, layer 3: only a Session with correlation-proved bleed is
        // deduped — no proof, no risk to real speech.
        if job.session.bleedDetected == true {
            let (deduped, dropped) = transcript.dedupingEchoes()
            transcript = deduped
            if dropped > 0 {
                log.notice("echo dedup for \(job.id, privacy: .public): dropped \(dropped) duplicated Mic utterance\(dropped == 1 ? "" : "s")")
            }
        }

        // Identification works in the diarizer's labels; everything after the
        // merge works in "Speaker N". Carry both across the rename.
        var voices: [String: SpeakerVoice] = [:]
        var matches: [String: VoiceMatch] = [:]
        for (diarizerLabel, mergedLabel) in merged.remoteLabels {
            if let voice = remote.voice(for: diarizerLabel) {
                voices[mergedLabel] = SpeakerVoice(speakerId: mergedLabel,
                                                   centroid: voice.centroid,
                                                   seconds: voice.seconds)
            }
            if let match = remote.matches[diarizerLabel] {
                matches[mergedLabel] = match
            }
        }

        let identified = identify(transcript: transcript, voices: voices, matches: matches,
                                  session: job.session, database: known)
        transcript = identified.transcript

        // Voice Clips are cut before anything is deleted (R25). The spans are
        // in the diarizer's labels and the naming flow works in Transcript
        // labels, so the clips are cut under the former and filed under the
        // latter.
        //
        // Auto-named voices get a clip too, which they did not used to. A name
        // the user was asked about is one they can check by reading the Note; a
        // name Braid applied on its own confidence is the only kind that can be
        // wrong without anybody being asked. That is exactly the case worth
        // being able to listen back to, and the whole reason Re-naming exists.
        let needsClip = Set(identified.unnamed).union(identified.autoNamed.keys)
        if !needsClip.isEmpty {
            var wanted: [String: String] = [:]
            for (diarizerLabel, mergedLabel) in merged.remoteLabels {
                // Both sets are keyed by the label the Transcript ended up with,
                // so the merge label has to be carried across the rename before
                // it can be matched — otherwise an auto-named voice is looked up
                // as "Speaker 1" and never gets a clip.
                let final = identified.finalLabels[mergedLabel] ?? mergedLabel
                guard needsClip.contains(final) else { continue }
                wanted[diarizerLabel] = final
            }
            env.clips.extract(from: remoteCAF, spans: remote.spans,
                              speakers: wanted, sessionID: job.id)
        }

        let stats = transcript.remoteSpeakerStats()
        let mismatch = job.session.speakerMismatch(heardRemoteSpeakers: stats.count)
        if let mismatch {
            log.warning("speaker mismatch for \(job.id, privacy: .public): \(mismatch.message, privacy: .public)")
        }

        var record = NamingRecord(
            session: job.session, transcript: transcript,
            engine: env.transcriber.name, speakerMismatch: mismatch,
            candidates: identified.candidates, suggestions: identified.suggestions,
            autoNamed: identified.autoNamed)

        // R26: Held Delivery stops here when there is still something to ask.
        // Nothing is summarised, nothing is written, and the Recording stays
        // until names arrive.
        if env.settings.delivery == .held, !identified.unnamed.isEmpty {
            env.transcripts.save(record)
            var held = job
            held.status = .awaitingNames
            jobs[job.id] = held
            persist(held)
            log.notice("job \(job.id, privacy: .public) held for \(identified.unnamed.count) unnamed voice(s)")
            env.onEvent(.heldForNames(held, stats, mismatch))
            return nil
        }

        try checkCancelled()

        let delivered = try await summariseAndWrite(session: job.session, transcript: transcript)
        let written = delivered.written
        // The summariser may have named this Session (R9a). Everything filed
        // from here on uses that name, including the Job, so the menu bar and
        // the naming view stop showing the time-of-day placeholder.
        var job = job
        job.session = delivered.session
        record.session = delivered.session
        record.notePath = written.noteURL.path
        record.transcriptPath = written.transcriptURL.path
        record.noteHash = NamingRecord.hash(
            (try? String(contentsOf: written.noteURL, encoding: .utf8)) ?? "")
        record.namesApplied = identified.unnamed.isEmpty

        await enroll(identified.autoNamed, candidates: identified.candidates)
        env.sessions.add(SessionRecord(session: job.session, notePath: written.noteURL.path))
        jobs[job.id] = job

        if !stats.isEmpty {
            env.transcripts.save(record)
            if !identified.unnamed.isEmpty {
                env.onEvent(.speakersDetected(job, stats, mismatch))
            }
            // Clips are no longer dropped the moment Identification resolves.
            // They age out with the naming record instead (R25 as amended), so
            // a name that turns out to be wrong can still be checked against
            // the voice weeks later. They are a few hundred KB per Session.
        }

        // Only a confirmed-success Job may delete a Recording (Operation).
        try? FileManager.default.removeItem(at: dir)
        return written.noteURL
    }

    // MARK: - Identification

    struct Identified {
        var transcript: Transcript
        /// Transcript labels still carrying a generic "Speaker N".
        var unnamed: [String]
        var candidates: [String: SpeakerVoice]
        var suggestions: [String: String]
        /// Speaker label → Person id, for names applied without asking.
        var autoNamed: [String: String]
        /// Pre-rename label → the label the Transcript ended up with. Everything
        /// downstream of `identify` works in the latter — including the Voice
        /// Clips, which are filed under the name the naming view will show.
        var finalLabels: [String: String]
    }

    /// Folds echo, applies confident matches, and leaves everything else for
    /// the user. Never guesses among voices (R6a, R23).
    func identify(transcript: Transcript, voices: [String: SpeakerVoice],
                  matches: [String: VoiceMatch], session: Session,
                  database: VoiceDatabase?) -> Identified {
        var transcript = transcript
        var names: [String: String] = [:]
        var autoNamed: [String: String] = [:]
        var suggestions: [String: String] = [:]
        var candidates: [String: SpeakerVoice] = [:]
        var resolved = Set<String>()

        for label in transcript.remoteSpeakers {
            let voice = voices[label]
            if let voice { candidates[label] = voice }

            // R28: the owner's own voice bouncing back off the far end. Folded,
            // never dropped — those words were said, and losing them would be
            // worse than labelling them oddly.
            if let voice, let database, env.identifier.isEcho(voice, in: database) {
                names[label] = "Me (echo)"
                resolved.insert(label)
                candidates[label] = nil
                log.notice("folded an echo of the owner's own voice back into Me")
                continue
            }

            switch matches[label] {
            case .confident(let personID, let name, let score):
                names[label] = name
                autoNamed[label] = personID
                resolved.insert(label)
                log.notice("auto-named a returning voice (score \(String(format: "%.2f", score)))")
            case .suggestion(_, let name, _):
                suggestions[label] = name
            case .unknown, nil:
                break
            }
        }

        // R6a: exactly one declared Participant and exactly one heard voice is
        // unambiguous — unless a confident match names somebody else, in which
        // case the two disagree and Braid asks rather than picks.
        let remaining = transcript.remoteSpeakers.filter { !resolved.contains($0) }
        if session.participants.count == 1, transcript.remoteSpeakers.count == 1,
           let only = remaining.first {
            names[only] = session.participants[0]
            resolved.insert(only)
            log.notice("named the single voice from the single declared participant")
        }

        let before = transcript.remoteSpeakers
        transcript = transcript.renamingSpeakers(names)
        let unnamed = transcript.remoteSpeakers.filter { $0.hasPrefix("Speaker ") }

        // Everything the record carries is re-keyed to the label the Transcript
        // ended up with, because that is what the naming flow works in. Without
        // this an auto-named voice would be filed under "Speaker 1" while the
        // user is looking at "Sarah", and correcting a wrong auto-name could
        // never find the Voiceprint that caused it (R24).
        func finalLabel(_ label: String) -> String { names[label] ?? label }
        var keyedCandidates: [String: SpeakerVoice] = [:]
        for (label, voice) in candidates {
            let key = finalLabel(label)
            keyedCandidates[key] = SpeakerVoice(speakerId: key, centroid: voice.centroid,
                                                seconds: voice.seconds)
        }
        var keyedAutoNamed: [String: String] = [:]
        for (label, personID) in autoNamed { keyedAutoNamed[finalLabel(label)] = personID }
        var keyedSuggestions: [String: String] = [:]
        for (label, name) in suggestions where unnamed.contains(finalLabel(label)) {
            keyedSuggestions[finalLabel(label)] = name
        }

        var finalLabels: [String: String] = [:]
        for label in before { finalLabels[label] = finalLabel(label) }

        return Identified(
            transcript: transcript, unnamed: unnamed,
            candidates: keyedCandidates.filter {
                unnamed.contains($0.key) || keyedAutoNamed[$0.key] != nil
            },
            suggestions: keyedSuggestions,
            autoNamed: keyedAutoNamed,
            finalLabels: finalLabels)
    }

    /// R24: naming is teaching. Enrollment happens here and nowhere else.
    ///
    /// A Person recognised again contributes a fresh exemplar, which is the
    /// point of the cap: the ten most recent recordings of someone track how
    /// they sound on this headset in this room, which their first ever
    /// recording does not.
    func enroll(_ named: [String: String], candidates: [String: SpeakerVoice]) async {
        for (label, personID) in named {
            guard let voice = candidates[label] else { continue }
            let database = await env.voices.database()
            guard let person = database.person(id: personID) else { continue }
            await env.voices.enroll(voice, as: person.name)
        }
    }

    // MARK: - Naming (R6a, R26)

    /// Applies user-assigned names to a Session, whether it is Held or already
    /// delivered, and teaches the database what it just learned.
    ///
    /// One entry point for both, because the difference is only where the Note
    /// comes from: a Held Session has never been summarised, a delivered one is
    /// re-summarised so its prose says "Sarah" rather than "Speaker 1".
    @discardableResult
    public func applyNames(sessionID: String, names: [String: String]) async throws -> URL {
        guard let record = env.transcripts.load(sessionID) else {
            throw PipelineError.permanent("no stored transcript for session \(sessionID)")
        }
        let assigned = names.compactMapValues { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard !assigned.isEmpty else {
            throw PipelineError.permanent("no names given")
        }

        // A corrected auto-name means the Voiceprint that produced it was
        // wrong, so it goes (R24) before the right one is learned.
        for (label, personID) in record.autoNamed {
            guard let typed = assigned[label], let voice = record.candidates[label] else { continue }
            let database = await env.voices.database()
            guard let person = database.person(id: personID),
                  person.name.caseInsensitiveCompare(typed) != .orderedSame else { continue }
            await env.voices.removeVoiceprint(from: personID, nearest: voice)
            log.notice("a wrong auto-name was corrected; the voiceprint behind it is gone")
        }
        for (label, name) in assigned {
            await env.voices.enroll(record.candidates[label], as: name)
        }

        let renamed = record.transcript.renamingSpeakers(assigned)
        // The named speakers become Participants: they are now facts about the
        // Session rather than guesses typed before it started.
        var session = record.session
        let existing = Set(session.participants)
        session.participants += assigned.values.filter { !existing.contains($0) }

        var updated = record
        updated.session = session
        updated.transcript = renamed
        updated.namesApplied = true
        updated.candidates = [:]
        updated.suggestions = [:]

        let noteURL: URL
        if record.isDelivered {
            // Naming relabels a Note; it does not rewrite one. The Summariser
            // does put speaker labels in the prose ("Owner: Speaker 1"), so the
            // body has to change — but by substitution, which is instant, not
            // by a second summarising pass, which costs tens of minutes on the
            // machine this app is shaped around and replaces prose the user has
            // already read. `resummarise` remains for the case where the Note
            // is no longer where it was written.
            let written = try await rename(record: record, session: session,
                                           transcript: renamed, names: assigned)
            updated.notePath = written.noteURL.path
            updated.transcriptPath = written.transcriptURL.path
            updated.noteHash = NamingRecord.hash(
                (try? String(contentsOf: written.noteURL, encoding: .utf8)) ?? "")
            env.sessions.add(SessionRecord(session: session, notePath: written.noteURL.path))
            noteURL = written.noteURL
        } else {
            // Held: this is the Session's first and only Note, so this is also
            // where a Held Session gets its title (R9a).
            let delivered = try await summariseAndWrite(session: session, transcript: renamed)
            let written = delivered.written
            updated.session = delivered.session
            updated.notePath = written.noteURL.path
            updated.transcriptPath = written.transcriptURL.path
            updated.noteHash = NamingRecord.hash(
                (try? String(contentsOf: written.noteURL, encoding: .utf8)) ?? "")
            env.sessions.add(SessionRecord(session: delivered.session,
                                           notePath: written.noteURL.path))
            try? FileManager.default.removeItem(
                at: env.jobsRoot.appendingPathComponent(sessionID))
            if var job = jobs[sessionID] {
                job.session = delivered.session
                job.status = .done
                job.noteURL = written.noteURL.path
                jobs[sessionID] = job
                persist(job)
                env.onEvent(.jobDone(job, noteURL: written.noteURL))
            }
            noteURL = written.noteURL
        }

        env.transcripts.save(updated)
        // The clips stay (R25 as amended). A name applied here can still turn
        // out to be wrong — especially one Braid auto-applied — and the whole
        // point of Re-naming is being able to listen back and fix it. They are
        // filed under the Transcript's label, so they follow the rename.
        env.clips.rename(sessionID: sessionID, names: assigned)
        log.notice("named \(assigned.count) speaker(s) in \(sessionID, privacy: .public)")
        return noteURL
    }

    /// R25: the user chose not to name these voices. That resolves the Session
    /// just as naming does — the clips go, and a Held Job delivers with the
    /// generic labels it has.
    @discardableResult
    public func skipNaming(sessionID: String) async throws -> URL? {
        guard let record = env.transcripts.load(sessionID) else { return nil }
        var updated = record
        updated.namesApplied = true
        updated.candidates = [:]
        updated.suggestions = [:]

        var noteURL: URL?
        if !record.isDelivered {
            let delivered = try await summariseAndWrite(session: record.session,
                                                        transcript: record.transcript)
            let written = delivered.written
            updated.session = delivered.session
            updated.notePath = written.noteURL.path
            updated.transcriptPath = written.transcriptURL.path
            updated.noteHash = NamingRecord.hash(
                (try? String(contentsOf: written.noteURL, encoding: .utf8)) ?? "")
            env.sessions.add(SessionRecord(session: delivered.session,
                                           notePath: written.noteURL.path))
            try? FileManager.default.removeItem(
                at: env.jobsRoot.appendingPathComponent(sessionID))
            if var job = jobs[sessionID] {
                job.session = delivered.session
                job.status = .done
                job.noteURL = written.noteURL.path
                jobs[sessionID] = job
                persist(job)
                env.onEvent(.jobDone(job, noteURL: written.noteURL))
            }
            noteURL = written.noteURL
        }
        env.transcripts.save(updated)
        // Skipping still drops the clips, unlike naming. "I would rather not
        // name these" is an explicit decision about these voices, not a maybe
        // — so there is nothing to come back and listen to (R25).
        env.clips.delete(sessionID: sessionID)
        return noteURL
    }

    // MARK: - Writing

    /// A written Note, and the Session as it stands after writing — which may
    /// carry a different title than it went in with (R9a).
    struct Delivered {
        var written: VaultWriter.Written
        var session: Session
    }

    private func summariseAndWrite(session: Session,
                                   transcript: Transcript) async throws -> Delivered {
        guard let vaultPath = env.settings.vaultPath else {
            throw PipelineError.permanent("no Vault path configured")
        }
        guard let preset = env.settings.presets.first(where: { $0.name == session.presetName })
                ?? env.settings.presets.first else {
            throw PipelineError.permanent("no Preset named \(session.presetName)")
        }
        let summary = try await env.summariser.summarise(
            transcript: transcript, session: session, preset: preset)
        meter(summary.usage)

        // The Note names itself. Only while the title is still the automatic
        // stand-in: once a Session has a real title it is in the user's Vault
        // and possibly linked from other notes, and a second summarising pass
        // must not quietly rename it.
        var session = session
        if session.titleIsAutomatic, let title = summary.title {
            log.notice("session \(session.id, privacy: .public) titled by the summariser")
            session.title = title
            session.autoTitled = false
        }

        let writer = VaultWriter(vaultURL: URL(fileURLWithPath: vaultPath))
        let written: VaultWriter.Written
        do {
            written = try writer.write(session: session, noteBody: summary.noteBody,
                                       transcript: transcript, engine: env.transcriber.name)
        } catch {
            throw PipelineError.permanent("Vault write: \(error.localizedDescription)")
        }
        // Verify both files exist before anything downstream touches the
        // Recording (R7).
        let fm = FileManager.default
        guard fm.fileExists(atPath: written.noteURL.path),
              fm.fileExists(atPath: written.transcriptURL.path) else {
            throw PipelineError.permanent("Vault write verification failed")
        }
        return Delivered(written: written, session: session)
    }

    /// Puts names to a delivered pair by substitution: the Transcript is
    /// relabelled, the Note's prose has its generic labels swapped, and the
    /// frontmatter picks up the new Participants. No model runs.
    ///
    /// The Note body is taken from disk rather than from the record, so edits
    /// made in Obsidian since delivery survive the rename instead of being
    /// clobbered — which is strictly better than the summarising path, where
    /// the only options were to overwrite the edits or abandon the pair.
    /// A Note that has been moved or renamed away has no body to substitute
    /// into, and only that case falls back to summarising.
    private func rename(record: NamingRecord, session: Session,
                        transcript: Transcript,
                        names: [String: String]) async throws -> VaultWriter.Written {
        guard let vaultPath = env.settings.vaultPath else {
            throw PipelineError.permanent("no Vault path configured")
        }
        let noteURL = URL(fileURLWithPath: record.notePath)
        let transcriptURL = URL(fileURLWithPath: record.transcriptPath)
        guard let current = try? String(contentsOf: noteURL, encoding: .utf8) else {
            log.notice("note for \(record.id, privacy: .public) is not where it was written — summarising a new pair")
            return try await resummarise(record: record, session: session,
                                         transcript: transcript)
        }

        let body = Self.renaming(Self.noteBody(of: current), names)
        let writer = VaultWriter(vaultURL: URL(fileURLWithPath: vaultPath))
        do {
            return try writer.overwrite(
                noteURL: noteURL, transcriptURL: transcriptURL, session: session,
                noteBody: body, transcript: transcript, engine: record.engine)
        } catch {
            throw PipelineError.permanent("Vault write: \(error.localizedDescription)")
        }
    }

    /// The Note without the frontmatter block `VaultWriter` put on it. Anything
    /// that does not start with one is already a body.
    static func noteBody(of contents: String) -> String {
        guard contents.hasPrefix("---\n") else { return contents }
        let afterOpen = contents.index(contents.startIndex, offsetBy: 4)
        guard let close = contents.range(of: "\n---\n",
                                         range: afterOpen..<contents.endIndex) else {
            return contents
        }
        return String(contents[close.upperBound...])
    }

    /// Longest label first, so "Speaker 1" can never match inside "Speaker 10".
    static func renaming(_ text: String, _ names: [String: String]) -> String {
        var out = text
        for (label, name) in names.sorted(by: { $0.key.count > $1.key.count }) {
            out = out.replacingOccurrences(of: label, with: name)
        }
        return out
    }

    /// Rewrites a delivered pair in place, unless the Note has changed on disk
    /// since we wrote it — in which case a new pair is written and the user's
    /// edits are left alone (R6a).
    private func resummarise(record: NamingRecord, session: Session,
                             transcript: Transcript) async throws -> VaultWriter.Written {
        guard let vaultPath = env.settings.vaultPath else {
            throw PipelineError.permanent("no Vault path configured")
        }
        guard let preset = env.settings.presets.first(where: { $0.name == session.presetName })
                ?? env.settings.presets.first else {
            throw PipelineError.permanent("no Preset named \(session.presetName)")
        }
        let summary = try await env.summariser.summarise(
            transcript: transcript, session: session, preset: preset)
        meter(summary.usage)

        let noteURL = URL(fileURLWithPath: record.notePath)
        let transcriptURL = URL(fileURLWithPath: record.transcriptPath)
        let writer = VaultWriter(vaultURL: URL(fileURLWithPath: vaultPath))
        do {
            let current = (try? String(contentsOf: noteURL, encoding: .utf8))
                .map { NamingRecord.hash($0) }
            if let current, !record.noteHash.isEmpty, current == record.noteHash {
                return try writer.overwrite(
                    noteURL: noteURL, transcriptURL: transcriptURL, session: session,
                    noteBody: summary.noteBody, transcript: transcript,
                    engine: record.engine)
            }
            // Moved, renamed, or edited in Obsidian. Never clobber that.
            log.notice("note for \(record.id, privacy: .public) changed since delivery — writing a new pair")
            return try writer.write(session: session, noteBody: summary.noteBody,
                                    transcript: transcript, engine: record.engine)
        } catch let error as PipelineError {
            throw error
        } catch {
            throw PipelineError.permanent("Vault write: \(error.localizedDescription)")
        }
    }

    /// R14: adds what a metered Engine just consumed to the running totals.
    /// On-device Engines report nothing and this does nothing, which is the
    /// honest answer for them — they cost no money.
    func meter(_ usage: SummaryUsage?) {
        guard let usage else { return }
        env.settings.cloudTokensUsed += usage.promptTokens + usage.replyTokens
        env.settings.cloudSpendUSD += usage.costUSD
    }

    /// Throws `.cancelled` if the user has stopped this Job. Used at the points
    /// where continuing would cost a lot of time.
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

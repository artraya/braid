import Foundation
import Synchronization
import Testing
@testable import BraidCore

// MARK: - Merge rule (SPEC Architecture)

@Test func mergeInterleavesByStartAndRelabelsSpeakers() {
    let mic = [
        Utterance(speaker: "A", start: 0.0, end: 2.0, text: "Hello from me"),
        Utterance(speaker: "A", start: 10.0, end: 12.0, text: "Me again"),
    ]
    let remote = [
        Utterance(speaker: "B", start: 3.0, end: 5.0, text: "First remote"),
        Utterance(speaker: "A", start: 6.0, end: 8.0, text: "Second remote"),
        Utterance(speaker: "B", start: 13.0, end: 14.0, text: "First remote again"),
    ]
    let t = mergeTranscripts(mic: mic, remote: remote, pauseSpans: [])
    #expect(t.utterances.map(\.speaker) == ["Me", "Speaker 1", "Speaker 2", "Me", "Speaker 1"])
    #expect(t.utterances.map(\.text) == [
        "Hello from me", "First remote", "Second remote", "Me again", "First remote again"])
    #expect(t.remoteSpeakers == ["Speaker 1", "Speaker 2"])
}

@Test func mergeNumbersRemoteSpeakersByFirstAppearance() {
    // Provider labels arrive as B-first; canonical numbering follows time.
    let remote = [
        Utterance(speaker: "B", start: 1, end: 2, text: "early"),
        Utterance(speaker: "A", start: 5, end: 6, text: "late"),
    ]
    let t = mergeTranscripts(mic: [], remote: remote, pauseSpans: [])
    #expect(t.utterances[0].speaker == "Speaker 1")
    #expect(t.utterances[1].speaker == "Speaker 2")
}

// MARK: - Transcript markdown (SPEC Transcript format, R3)

@Test func markdownFormatsUtterancesAndPauseMarker() {
    let t = Transcript(
        utterances: [
            Utterance(speaker: "Me", start: 0, end: 2, text: "Hi"),
            Utterance(speaker: "Speaker 1", start: 65, end: 70, text: "Hello"),
        ],
        pauseSpans: [.init(atRecordedSeconds: 30, wallGapSeconds: 252)])
    let md = t.markdown()
    #expect(md.contains("- **00:00:00 Me:** Hi"))
    #expect(md.contains("- **00:01:05 Speaker 1:** Hello"))
    #expect(md.contains("[recording paused — 4m 12s]"))
    // Marker sits between the utterances (position 30s).
    let lines = md.components(separatedBy: "\n").filter { !$0.isEmpty }
    #expect(lines[1].contains("recording paused"))
}

@Test func gapFormatting() {
    #expect(Transcript.gap(37) == "37s")
    #expect(Transcript.gap(252) == "4m 12s")
    #expect(Transcript.gap(3723) == "1h 2m 3s")
    #expect(Transcript.gap(0) == "0s")
}

// MARK: - Note filename (R9)

@Test func titleSanitisation() {
    #expect(VaultWriter.sanitizeTitle("a/b\\c:d#e^f[g]h|i") == "a-b-c-d-e-f-g-h-i")
    #expect(VaultWriter.sanitizeTitle("  ") == "Untitled")
    #expect(VaultWriter.sanitizeTitle("Project Sync") == "Project Sync")
}

@Test func baseNameUsesSessionStartLocalTime() {
    var comps = DateComponents()
    comps.year = 2026; comps.month = 7; comps.day = 31; comps.hour = 14; comps.minute = 30
    let date = Calendar.current.date(from: comps)!
    #expect(VaultWriter.baseName(startedAt: date, title: "Project Sync")
            == "2026-07-31 1430 Project Sync")
}

@Test func collisionAppendsLowestFreeInteger() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("vault-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let writer = VaultWriter(vaultURL: dir)
    let session = Session(title: "Sync", presetName: "Meeting", participants: [],
                          startedAt: Date(timeIntervalSince1970: 1_790_000_000),
                          recordedDuration: 60)
    let t = Transcript(utterances: [Utterance(speaker: "Me", start: 0, end: 1, text: "x")])
    let first = try writer.write(session: session, noteBody: "# A", transcript: t,
                                 provider: "assemblyai", costUSD: 0.1)
    let second = try writer.write(session: session, noteBody: "# B", transcript: t,
                                  provider: "assemblyai", costUSD: 0.1)
    let third = try writer.write(session: session, noteBody: "# C", transcript: t,
                                 provider: "assemblyai", costUSD: 0.1)
    let base = first.noteURL.deletingPathExtension().lastPathComponent
    #expect(second.noteURL.deletingPathExtension().lastPathComponent == "\(base) 2")
    #expect(third.noteURL.deletingPathExtension().lastPathComponent == "\(base) 3")
    // Transcript names track the Note's suffix.
    #expect(third.transcriptURL.lastPathComponent == "\(base) 3 (transcript).md")
}

// MARK: - Frontmatter (R10)

@Test func frontmatterCarriesAllRequiredKeys() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("vault-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let writer = VaultWriter(vaultURL: dir)
    let session = Session(title: "Sync", presetName: "Meeting",
                          participants: ["Sarah", "Tom"],
                          startedAt: Date(), recordedDuration: 2832)
    let t = Transcript(utterances: [Utterance(speaker: "Me", start: 0, end: 1, text: "x")])
    let written = try writer.write(session: session, noteBody: "# Note", transcript: t,
                                   provider: "assemblyai", costUSD: 0.1234)
    let note = try String(contentsOf: written.noteURL, encoding: .utf8)
    for key in ["date:", "start:", "duration: 00:47:12", "preset: Meeting",
                "participants: [Sarah, Tom]", "provider: assemblyai",
                "cost: 0.1234", "transcript: \"[["] {
        #expect(note.contains(key), "missing \(key)")
    }
    #expect(note.contains("(transcript)]]\""))
}

// MARK: - Presets (R11, R12)

@Test func allFourPresetsShipAndEmbedTheNamingRule() {
    #expect(Preset.defaults.map(\.name) == ["Meeting", "Lecture", "Interview", "Training"])
    for preset in Preset.defaults {
        #expect(preset.prompt.contains(Preset.namingRule), "\(preset.name) missing R11 rule")
    }
}

// MARK: - Cost (R14)

@Test func costMatchesRateTable() {
    let table = CostTable.current
    // 1h Session = 1h plain Mic Track + 1h diarized Remote Track, keyterms on both.
    let stt = table.sttCost(trackHours: 1, diarized: false, keyterms: true)
        + table.sttCost(trackHours: 1, diarized: true, keyterms: true)
    #expect(abs(stt - (0.26 + 0.28)) < 0.0001)
    let claude = table.claudeCost(inputTokens: 10_000, outputTokens: 2_000)
    #expect(abs(claude - (0.05 + 0.05)) < 0.0001)
}

// MARK: - AssemblyAI response mapping

@Test func adapterMapsDiarizedUtterances() {
    let json: [String: Any] = [
        "status": "completed",
        "utterances": [
            ["speaker": "B", "start": 32.0, "end": 5082.0, "text": "Hi there"],
            ["speaker": "A", "start": 5082.0, "end": 6610.0, "text": "Hello"],
        ],
    ]
    let utterances = AssemblyAIAdapter.utterances(from: json)
    #expect(utterances.count == 2)
    #expect(utterances[0].speaker == "B")
    #expect(abs(utterances[0].start - 0.032) < 0.001)
    #expect(utterances[1].text == "Hello")
}

@Test func adapterFallsBackToPlainText() {
    let json: [String: Any] = ["status": "completed", "text": "just words",
                               "audio_duration": 5.0]
    let utterances = AssemblyAIAdapter.utterances(from: json)
    #expect(utterances.count == 1)
    #expect(utterances[0].text == "just words")
}

// MARK: - Error taxonomy (Journey step 8)

@Test func errorClassification() {
    #expect(PipelineError.classify(status: 500, body: "", context: "x").isTransient)
    #expect(PipelineError.classify(status: 429, body: "", context: "x").isTransient)
    #expect(!PipelineError.classify(status: 401, body: "", context: "x").isTransient)
    #expect(!PipelineError.classify(status: 400, body: "", context: "x").isTransient)
    let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
    #expect(PipelineError.classify(transport: offline, context: "x").isTransient)
}

// MARK: - Provider request parameters (R6)

@Test func remoteTrackRequestCarriesLanguageAndKeyterms() {
    let body = AssemblyAIAdapter.requestBody(
        audioURL: "https://example/x", diarize: true,
        keyTerms: ["Acme Geo", "SlopeWatch"])
    #expect(body["language_code"] as? String == "en_au")
    #expect(body["speech_models"] as? [String] == ["universal-3-5-pro"])
    #expect(body["speaker_labels"] as? Bool == true)
    #expect(body["keyterms_prompt"] as? [String] == ["Acme Geo", "SlopeWatch"])
}

@Test func micTrackRequestIsUndiarized() {
    let body = AssemblyAIAdapter.requestBody(
        audioURL: "https://example/x", diarize: false, keyTerms: [])
    #expect(body["language_code"] as? String == "en_au")
    #expect(body["speaker_labels"] as? Bool == false)
    #expect(body["keyterms_prompt"] == nil)
}

/// Amended R6: by default no request carries a speaker count. Capping it at
/// Participants+1 once meant a late joiner was folded into an existing speaker.
@Test func defaultRequestsNeverConstrainTheSpeakerCount() {
    for diarize in [true, false] {
        let body = AssemblyAIAdapter.requestBody(
            audioURL: "https://example/x", diarize: diarize, keyTerms: ["Acme Geo"])
        #expect(body["speaker_options"] == nil)
        #expect(body["speakers_expected"] == nil)
    }
}

/// Amended R6: an asserted count is sent as a minimum — it can fix two voices
/// heard as one, and can never fold a late joiner into an existing speaker.
@Test func assertedCountSendsTheMinimumOnly() throws {
    let body = AssemblyAIAdapter.requestBody(
        audioURL: "https://example/x", diarize: true, keyTerms: [],
        expectedSpeakers: Session.SpeakerExpectation(count: 3))
    let options = try #require(body["speaker_options"] as? [String: Any])
    #expect(options["min_speakers_expected"] as? Int == 3)
    #expect(options["max_speakers_expected"] == nil)
    #expect(body["speakers_expected"] == nil)
}

/// Amended R6: only the explicit strict choice adds the maximum — the setting
/// whose label owns the late-joiner cost.
@Test func strictAddsTheMaximum() throws {
    let body = AssemblyAIAdapter.requestBody(
        audioURL: "https://example/x", diarize: true, keyTerms: [],
        expectedSpeakers: Session.SpeakerExpectation(count: 2, strict: true))
    let options = try #require(body["speaker_options"] as? [String: Any])
    #expect(options["min_speakers_expected"] as? Int == 2)
    #expect(options["max_speakers_expected"] as? Int == 2)
}

/// Amended R6: the undiarized Mic request never carries speaker fields, even
/// when the Session asserted a count.
@Test func micRequestNeverCarriesSpeakerFields() {
    let body = AssemblyAIAdapter.requestBody(
        audioURL: "https://example/x", diarize: false, keyTerms: [],
        expectedSpeakers: Session.SpeakerExpectation(count: 4, strict: true))
    #expect(body["speaker_options"] == nil)
    #expect(body["speakers_expected"] == nil)
}

/// Amended R6: Participants reach the Provider as vocabulary — the names R11
/// needs as transcript evidence arrive spelled correctly — never as a count.
@Test func participantsJoinTheKeyTermsDeduplicated() {
    let session = Session(title: "Sync", presetName: "Meeting",
                          participants: ["Sarah", "acme geo", "Tom"],
                          startedAt: Date())
    let merged = session.mergedKeyTerms(global: ["Acme Geo", "SlopeWatch"])
    #expect(merged == ["Acme Geo", "SlopeWatch", "Sarah", "Tom"])

    let body = AssemblyAIAdapter.requestBody(
        audioURL: "https://example/x", diarize: true, keyTerms: merged)
    #expect(body["keyterms_prompt"] as? [String] == ["Acme Geo", "SlopeWatch", "Sarah", "Tom"])
    #expect(body["speaker_options"] == nil)
}

// MARK: - Speaker count mismatch (amended R6)

@Test func mismatchComparesAgainstTheAssertedCountFirst() {
    let session = Session(title: "Sync", presetName: "Meeting",
                          participants: ["Sarah", "Tom"],
                          expectedSpeakers: .init(count: 2),
                          startedAt: Date())
    // Matches the asserted count: no warning, whatever Participants say.
    #expect(session.speakerMismatch(heardRemoteSpeakers: 2) == nil)

    let mismatch = session.speakerMismatch(heardRemoteSpeakers: 3)
    #expect(mismatch == Session.SpeakerCountMismatch(heard: 3, expected: 2, asserted: true))
    #expect(mismatch?.message == "Heard 3 voices; you set 2.")
}

@Test func mismatchFallsBackToParticipantsAsASoftSignal() {
    let session = Session(title: "Sync", presetName: "Meeting",
                          participants: ["Sarah", "Tom"], startedAt: Date())
    #expect(session.speakerMismatch(heardRemoteSpeakers: 2) == nil)
    let mismatch = session.speakerMismatch(heardRemoteSpeakers: 1)
    #expect(mismatch == Session.SpeakerCountMismatch(heard: 1, expected: 2, asserted: false))
    // Fewer than expected: the audio is gone (R7), so the advice is the next call.
    #expect(mismatch?.message ==
        "Heard 1 voice; you listed 2 participants. If voices were merged, set the speaker count before the next call.")
}

@Test func noExpectationMeansNoWarningEver() {
    let session = Session(title: "Sync", presetName: "Meeting",
                          participants: [], startedAt: Date())
    for heard in 0...5 {
        #expect(session.speakerMismatch(heardRemoteSpeakers: heard) == nil)
    }
    // Zero heard is R16's territory, not a diarization mismatch.
    let expecting = Session(title: "Sync", presetName: "Meeting", participants: [],
                            expectedSpeakers: .init(count: 2), startedAt: Date())
    #expect(expecting.speakerMismatch(heardRemoteSpeakers: 0) == nil)
}

// MARK: - Speaker stats and renaming

@Test func speakerStatsRankByTalkTimeAndSampleTheLongestLine() {
    let t = Transcript(utterances: [
        Utterance(speaker: "Me", start: 0, end: 30, text: "my long opening"),
        Utterance(speaker: "Speaker 1", start: 30, end: 32, text: "yeah"),
        Utterance(speaker: "Speaker 2", start: 32, end: 52, text: "a considered point"),
        Utterance(speaker: "Speaker 1", start: 52, end: 55, text: "quick follow up"),
    ])
    let stats = t.remoteSpeakerStats()
    // "Me" is never offered for naming.
    #expect(stats.map(\.speaker) == ["Speaker 2", "Speaker 1"])
    #expect(abs(stats[0].totalSeconds - 20) < 0.001)
    #expect(stats[1].utteranceCount == 2)
    // Longest utterance, not the first, identifies a voice best.
    #expect(stats[1].sample == "quick follow up")
    #expect(abs(stats[1].firstAt - 30) < 0.001)
}

@Test func speakerStatsTruncateLongSamples() {
    let t = Transcript(utterances: [
        Utterance(speaker: "Speaker 1", start: 0, end: 5, text: String(repeating: "a", count: 300)),
    ])
    let sample = t.remoteSpeakerStats(sampleLimit: 20)[0].sample
    #expect(sample.count == 21)
    #expect(sample.hasSuffix("…"))
}

@Test func renamingAppliesNamesButNeverTouchesMe() {
    let t = Transcript(utterances: [
        Utterance(speaker: "Me", start: 0, end: 1, text: "a"),
        Utterance(speaker: "Speaker 1", start: 1, end: 2, text: "b"),
        Utterance(speaker: "Speaker 2", start: 2, end: 3, text: "c"),
        Utterance(speaker: "Speaker 3", start: 3, end: 4, text: "d"),
    ])
    let renamed = t.renamingSpeakers([
        "Speaker 1": "Sarah",
        "Speaker 2": "   ",     // blank: left alone
        "Me": "Someone Else",   // R11: ignored
    ])
    #expect(renamed.utterances.map(\.speaker) == ["Me", "Sarah", "Speaker 2", "Speaker 3"])
}

// MARK: - Cancelling a Job before it costs anything

/// Records what the pipeline actually asked the cloud to do, and can be made
/// slow enough to cancel mid-flight.
private final class SpyProvider: STTProvider, @unchecked Sendable {
    struct Call: Sendable {
        let diarize: Bool
        let keyTerms: [String]
        let expectedSpeakers: Session.SpeakerExpectation?
    }

    let name = "spy"
    let delay: Duration
    /// Speakers returned for the diarized (Remote) request.
    let remoteSpeakers: [String]
    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: Int { lock.withLock { _calls.count } }
    var recorded: [Call] { lock.withLock { _calls } }
    /// Signals that transcription has genuinely started, so a test never
    /// cancels before the work is under way.
    let started = AsyncStream<Void>.makeStream()

    init(delay: Duration = .milliseconds(50), remoteSpeakers: [String] = ["A"]) {
        self.delay = delay
        self.remoteSpeakers = remoteSpeakers
    }

    func transcribe(track: URL, diarize: Bool, keyTerms: [String],
                    expectedSpeakers: Session.SpeakerExpectation?) async throws -> [Utterance] {
        lock.withLock {
            _calls.append(Call(diarize: diarize, keyTerms: keyTerms,
                               expectedSpeakers: expectedSpeakers))
        }
        started.continuation.yield()
        try await Task.sleep(for: delay)
        guard diarize else {
            return [Utterance(speaker: "A", start: 0, end: 1, text: "hello")]
        }
        return remoteSpeakers.enumerated().map { index, speaker in
            Utterance(speaker: speaker, start: Double(index) * 2 + 2,
                      end: Double(index) * 2 + 3, text: "line \(index)")
        }
    }
}

/// Lets a Job run to completion without the network, recording what it was
/// asked to summarise.
private final class StubSummariser: NoteSummarising, @unchecked Sendable {
    private let lock = NSLock()
    private var _transcripts: [Transcript] = []
    var transcripts: [Transcript] { lock.withLock { _transcripts } }
    var callCount: Int { lock.withLock { _transcripts.count } }

    func summarise(transcript: Transcript, session: Session,
                   preset: Preset) async throws -> Summariser.Output {
        lock.withLock { _transcripts.append(transcript) }
        return Summariser.Output(noteBody: "# Stub note", inputTokens: 100, outputTokens: 50)
    }
}

/// A real, short CAF written by the app's own TrackWriter, so a Job under test
/// gets far enough to actually transcode and reach the Provider.
private func writeTestCAF(at url: URL, seconds: Double = 0.25) throws {
    let rate = 16_000.0
    let writer = try TrackWriter(url: url, deviceRate: rate)
    var samples = [Float](repeating: 0, count: Int(rate * seconds))
    for i in samples.indices {
        samples[i] = Float(sin(Double(i) / 8) * 0.4)
    }
    samples.withUnsafeMutableBufferPointer { buffer in
        writer.writeAsync(buffer.baseAddress!, frames: buffer.count)
    }
    writer.close()
}

private func makeQueueEnvironment(provider: STTProvider, root: URL,
                                  summariser: any NoteSummarising = Summariser(apiKey: "unused"),
                                  keyTerms: [String] = [],
                                  onEvent: @escaping @Sendable (JobQueue.Event) -> Void = { _ in })
    -> JobQueue.Environment {
    let defaults = UserDefaults(suiteName: "no.braid.test.\(UUID().uuidString)")!
    let settings = SettingsStore(defaults: defaults)
    settings.vaultPath = root.appendingPathComponent("vault").path
    settings.keyTerms = keyTerms
    return JobQueue.Environment(
        provider: provider,
        summariser: summariser,
        settings: settings,
        jobsRoot: root.appendingPathComponent("jobs"),
        transcripts: TranscriptStore(root: root.appendingPathComponent("transcripts")),
        sessions: SessionIndex(url: root.appendingPathComponent("sessions.json")),
        onEvent: onEvent)
}

/// A queued Job that is cancelled before the runner reaches it must never call
/// the Provider at all. This is the case that actually protects the credits.
@Test func cancellingAQueuedJobNeverCallsTheProvider() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("cancel-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    // A provider slow enough that the first Job is still running when the
    // second is cancelled behind it.
    let provider = SpyProvider(delay: .seconds(30))
    let queue = JobQueue(env: makeQueueEnvironment(provider: provider, root: root))

    let first = Session(title: "First", presetName: "Meeting", participants: [],
                        startedAt: Date(), recordedDuration: 60)
    let second = Session(title: "Second", presetName: "Meeting", participants: [],
                         startedAt: Date(), recordedDuration: 60)
    for session in [first, second] {
        let dir = root.appendingPathComponent("jobs").appendingPathComponent(session.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    await queue.enqueue(session: first, remoteSilent: false)
    await queue.enqueue(session: second, remoteSilent: false)

    await queue.cancel(id: second.id)

    let cancelled = await queue.cancelledJobs()
    #expect(cancelled.map(\.id) == [second.id])
    // Its Recording is kept: cancelling is about spending, not about the audio.
    #expect(FileManager.default.fileExists(
        atPath: root.appendingPathComponent("jobs").appendingPathComponent(second.id).path))
    // And it is no longer counted as work in progress.
    let active = await queue.activeJobs()
    #expect(!active.contains { $0.id == second.id })

    await queue.cancel(id: first.id)
}

@Test func cancellingLeavesTheRecordingUntilDiscardIsAsked() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("cancel-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let queue = JobQueue(env: makeQueueEnvironment(
        provider: SpyProvider(delay: .seconds(30)), root: root))
    let session = Session(title: "Mistake", presetName: "Meeting", participants: [],
                          startedAt: Date(), recordedDuration: 60)
    let dir = root.appendingPathComponent("jobs").appendingPathComponent(session.id)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: dir.appendingPathComponent("mic.caf"))

    await queue.enqueue(session: session, remoteSilent: false)
    await queue.cancel(id: session.id)
    #expect(FileManager.default.fileExists(atPath: dir.path))

    // A cancelled Job can be sent through after all.
    await queue.retry(id: session.id)
    #expect(await queue.cancelledJobs().isEmpty)
    await queue.cancel(id: session.id)

    // Discard is what actually deletes the audio.
    await queue.discard(id: session.id)
    #expect(!FileManager.default.fileExists(atPath: dir.path))
    #expect(await queue.allJobs().isEmpty)
}

@Test func cancellingIsNotAFailure() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("cancel-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let events = Mutex<[String]>([])
    let provider = SpyProvider(delay: .seconds(30))
    let queue = JobQueue(env: makeQueueEnvironment(
        provider: provider, root: root,
        onEvent: { event in
            switch event {
            case .jobFailed: events.withLock { $0.append("failed") }
            case .jobCancelled: events.withLock { $0.append("cancelled") }
            default: break
            }
        }))
    let session = Session(title: "Mistake", presetName: "Meeting", participants: [],
                          startedAt: Date(), recordedDuration: 60)
    let dir = root.appendingPathComponent("jobs").appendingPathComponent(session.id)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // Real audio, so transcoding runs and the Provider is genuinely reached.
    for track in ["mic.caf", "remote.caf"] {
        try writeTestCAF(at: dir.appendingPathComponent(track))
    }

    await queue.enqueue(session: session, remoteSilent: false)
    // Cancel only once the upload is genuinely under way, so this exercises
    // tearing down an in-flight request rather than skipping a queued Job.
    var iterator = provider.started.stream.makeAsyncIterator()
    _ = await iterator.next()
    await queue.cancel(id: session.id)
    try await Task.sleep(for: .milliseconds(300))
    #expect(provider.calls > 0)

    // The torn-down request must not surface as something going wrong.
    #expect(events.withLock { $0 } == ["cancelled"])
    #expect(await queue.failedJobs().isEmpty)
}

@Test func cancellationIsClassifiedAsCancellationNotFailure() {
    let urlCancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
    let classified = PipelineError.classify(transport: urlCancelled, context: "assemblyai")
    #expect(classified.isCancellation)
    #expect(!classified.isTransient)   // must never auto-retry

    #expect(PipelineError.classify(transport: CancellationError(), context: "x").isCancellation)
    // A genuine network failure is still transient.
    let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
    #expect(!PipelineError.classify(transport: offline, context: "x").isCancellation)
}

// MARK: - Mismatch surfaces after delivery, never blocking it (amended R6)

/// Three voices heard against an asserted two: the Note still delivers
/// hands-off, the warning rides the speakersDetected event and the
/// NamingRecord, and the Recording is deleted as on any success.
@Test func mismatchWarnsAfterDeliveryWithoutBlockingIt() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("mismatch-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let provider = SpyProvider(delay: .milliseconds(1), remoteSpeakers: ["A", "B", "C"])
    let events = Mutex<[JobQueue.Event]>([])
    let done = AsyncStream<URL>.makeStream()
    let env = makeQueueEnvironment(
        provider: provider, root: root, summariser: StubSummariser(),
        keyTerms: ["Acme Geo"],
        onEvent: { event in
            events.withLock { $0.append(event) }
            if case .jobDone(_, let noteURL) = event {
                done.continuation.yield(noteURL)
            }
        })

    let session = Session(title: "Mismatch", presetName: "Meeting",
                          participants: ["Sarah"],
                          expectedSpeakers: .init(count: 2),
                          startedAt: Date(), recordedDuration: 60)
    let dir = root.appendingPathComponent("jobs").appendingPathComponent(session.id)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for track in ["mic.caf", "remote.caf"] {
        try writeTestCAF(at: dir.appendingPathComponent(track))
    }

    let queue = JobQueue(env: env)
    await queue.enqueue(session: session, remoteSilent: false)

    var doneIterator = done.stream.makeAsyncIterator()
    let noteURL = try #require(await doneIterator.next())

    // Delivered hands-off: Note on disk, Recording gone.
    #expect(FileManager.default.fileExists(atPath: noteURL.path))
    #expect(!FileManager.default.fileExists(atPath: dir.path))

    // The warning rode along after delivery.
    let detected = events.withLock { $0 }.compactMap { event
        -> (Int, Session.SpeakerCountMismatch?)? in
        if case .speakersDetected(_, let stats, let mismatch) = event {
            return (stats.count, mismatch)
        }
        return nil
    }
    #expect(detected.count == 1)
    #expect(detected.first?.0 == 3)
    #expect(detected.first?.1 ==
        Session.SpeakerCountMismatch(heard: 3, expected: 2, asserted: true))

    // And persisted for the naming sheet.
    let record = try #require(
        TranscriptStore(root: root.appendingPathComponent("transcripts")).load(session.id))
    #expect(record.speakerMismatch?.heard == 3)

    // The wiring the mismatch depends on: the asserted count reached only the
    // diarized request, and Participants joined the Key Terms on both.
    let calls = provider.recorded
    #expect(calls.count == 2)
    for call in calls {
        #expect(call.keyTerms == ["Acme Geo", "Sarah"])
        #expect(call.expectedSpeakers == (call.diarize ? .init(count: 2) : nil))
    }
}

// MARK: - Merging and the 1:1 candidate

/// The merge affordance: the same name typed on two voices folds them into one
/// speaker everywhere.
@Test func sameNameOnTwoSpeakersMergesThem() {
    let t = Transcript(utterances: [
        Utterance(speaker: "Me", start: 0, end: 1, text: "a"),
        Utterance(speaker: "Speaker 1", start: 1, end: 2, text: "b"),
        Utterance(speaker: "Speaker 2", start: 2, end: 3, text: "c"),
        Utterance(speaker: "Speaker 1", start: 3, end: 4, text: "d"),
    ])
    let merged = t.renamingSpeakers(["Speaker 1": "Sarah", "Speaker 2": "Sarah"])
    #expect(merged.utterances.map(\.speaker) == ["Me", "Sarah", "Sarah", "Sarah"])
    #expect(merged.remoteSpeakers == ["Sarah"])
    #expect(merged.remoteSpeakerStats().count == 1)
}

/// Runs a Job to completion and returns everything the assertions need.
private func runFixtureJob(
    session: Session, remoteSpeakers: [String], root: URL
) async throws -> (noteURL: URL, events: [JobQueue.Event],
                   summariser: StubSummariser, record: NamingRecord?) {
    let provider = SpyProvider(delay: .milliseconds(1), remoteSpeakers: remoteSpeakers)
    let summariser = StubSummariser()
    let events = Mutex<[JobQueue.Event]>([])
    let done = AsyncStream<URL>.makeStream()
    let env = makeQueueEnvironment(
        provider: provider, root: root, summariser: summariser,
        onEvent: { event in
            events.withLock { $0.append(event) }
            if case .jobDone(_, let noteURL) = event {
                done.continuation.yield(noteURL)
            }
        })
    let dir = root.appendingPathComponent("jobs").appendingPathComponent(session.id)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for track in ["mic.caf", "remote.caf"] {
        try writeTestCAF(at: dir.appendingPathComponent(track))
    }
    let queue = JobQueue(env: env)
    await queue.enqueue(session: session, remoteSilent: false)
    var iterator = done.stream.makeAsyncIterator()
    let noteURL = try #require(await iterator.next())
    let record = TranscriptStore(root: root.appendingPathComponent("transcripts"))
        .load(session.id)
    return (noteURL, events.withLock { $0 }, summariser, record)
}

/// Amended R6a: one declared Participant, one heard voice — the Note arrives
/// already named, with one summarise call and nothing prompting.
@Test func autoAssignNamesTheSingleVoiceBeforeSummarising() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("autoassign-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let session = Session(title: "One on one", presetName: "Meeting",
                          participants: ["Priya"], startedAt: Date(),
                          recordedDuration: 60)
    let run = try await runFixtureJob(session: session, remoteSpeakers: ["A"], root: root)

    // The Summariser saw the name — exactly once, before delivery.
    #expect(run.summariser.callCount == 1)
    #expect(run.summariser.transcripts.first?.remoteSpeakers == ["Priya"])

    // The delivered transcript file carries the name too.
    let record = try #require(run.record)
    let transcriptText = try String(
        contentsOf: URL(fileURLWithPath: record.transcriptPath), encoding: .utf8)
    #expect(transcriptText.contains("Priya:"))
    #expect(!transcriptText.contains("Speaker 1"))

    // Already named: nothing prompts.
    #expect(record.namesApplied)
    #expect(!run.events.contains { if case .speakersDetected = $0 { return true }
                                   return false })
}

/// Amended R6a: more voices than declared names is a guess, and Braid does not
/// guess among voices — the naming flow stays exactly as it was.
@Test func autoAssignNeverGuessesAmongVoices() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("autoassign-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let session = Session(title: "Group call", presetName: "Meeting",
                          participants: ["Priya"], startedAt: Date(),
                          recordedDuration: 60)
    let run = try await runFixtureJob(session: session,
                                      remoteSpeakers: ["A", "B", "C"], root: root)

    #expect(run.summariser.transcripts.first?.remoteSpeakers ==
        ["Speaker 1", "Speaker 2", "Speaker 3"])
    let record = try #require(run.record)
    #expect(!record.namesApplied)
    #expect(run.events.contains { if case .speakersDetected = $0 { return true }
                                  return false })
}

// MARK: - Auto-end detection

/// Feeds a detector a sequence of (secondsFromStart, callAppHoldingMic) and
/// returns the offsets at which it judged the call to have ended.
private func firings(_ detector: inout CallEndDetector,
                     _ samples: [(TimeInterval, Bool)]) -> [TimeInterval] {
    let start = Date(timeIntervalSince1970: 1_790_000_000)
    var fired: [TimeInterval] = []
    for (offset, holding) in samples {
        if detector.update(callAppHoldingMic: holding,
                           now: start.addingTimeInterval(offset)) {
            fired.append(offset)
        }
    }
    return fired
}

@Test func autoEndNeverFiresWithoutACallAppFirst() {
    // Dictating into a quiet room: no call app ever takes the mic.
    var detector = CallEndDetector(grace: 15)
    let samples = stride(from: 0.0, through: 600, by: 2).map { ($0, false) }
    #expect(firings(&detector, samples).isEmpty)
    #expect(!detector.armed)
}

@Test func autoEndFiresOnceAfterTheGracePeriod() {
    var detector = CallEndDetector(grace: 15)
    var samples: [(TimeInterval, Bool)] = stride(from: 0.0, to: 60, by: 2).map { ($0, true) }
    samples += stride(from: 60.0, through: 120, by: 2).map { ($0, false) }
    let fired = firings(&detector, samples)
    // Released at 60, so it fires on the first sample at or past 75.
    #expect(fired == [76])
    #expect(!detector.armed)
}

@Test func autoEndRidesOutAReconnect() {
    var detector = CallEndDetector(grace: 15)
    var samples: [(TimeInterval, Bool)] = [(0, true), (2, true)]
    // Teams drops for 8 seconds and comes back: shorter than the grace period.
    samples += [(4, false), (6, false), (8, false), (10, false), (12, true), (14, true)]
    #expect(firings(&detector, samples).isEmpty)
    #expect(detector.armed)
}

@Test func keepRecordingDisarmsUntilTheNextCall() {
    var detector = CallEndDetector(grace: 15)
    _ = firings(&detector, [(0, true), (2, true)])

    // The user says keep recording while the app is still off the mic.
    detector.reset()
    #expect(firings(&detector, stride(from: 4.0, through: 300, by: 2).map { ($0, false) }).isEmpty)

    // A fresh call arms it again, and ending that one does fire.
    var samples: [(TimeInterval, Bool)] = [(302, true), (304, true)]
    samples += stride(from: 306.0, through: 340, by: 2).map { ($0, false) }
    #expect(firings(&detector, samples) == [322])
}

@Test func callAppMatchingCoversHelpersAndVersionedBundles() {
    // Browsers and Electron apps open the mic from a helper process.
    #expect(CallWatcher.matches("com.google.Chrome.helper", watched: "com.google.Chrome"))
    #expect(CallWatcher.matches("com.microsoft.edgemac.helper", watched: "com.microsoft.edgemac"))
    #expect(CallWatcher.matches("com.microsoft.teams", watched: "com.microsoft.teams"))
    // The current Teams client is "teams2".
    #expect(CallWatcher.matches("com.microsoft.teams2", watched: "com.microsoft.teams"))
    // A prefix must not swallow an unrelated app.
    #expect(!CallWatcher.matches("com.google.ChromeRemoteDesktop", watched: "com.google.Chrome"))
    #expect(!CallWatcher.matches("us.zoom.xos", watched: "com.apple.Safari"))
}

// MARK: - Panel placement

/// A 2560x1440 screen with a 24pt menu bar, and a 380pt panel.
private let testScreen = CGRect(x: 0, y: 0, width: 2560, height: 1416)
private let testPanel = CGSize(width: 380, height: 300)
private let menuBarBottom: CGFloat = 1416

@Test func panelHangsFromTheMenuBarCentredUnderItsIcon() {
    let placement = PanelGeometry.place(
        panelSize: testPanel, iconCentreX: 1280,
        menuBarBottomY: menuBarBottom, screen: testScreen)
    // Flush with the menu bar: no floating gap.
    #expect(placement.topLeft.y == menuBarBottom)
    #expect(placement.topLeft.x == CGFloat(1090))
    // Arrow lands dead centre, pointing at the icon.
    #expect(placement.arrowX == CGFloat(190))
}

@Test func panelStaysOnScreenAndTheArrowFollowsTheIcon() {
    // A menu bar item near the right edge, where the panel must be pulled in.
    let placement = PanelGeometry.place(
        panelSize: testPanel, iconCentreX: 2500,
        menuBarBottomY: menuBarBottom, screen: testScreen)
    #expect(placement.topLeft.x == CGFloat(2172))   // clamped, not centred
    #expect(placement.topLeft.x + testPanel.width <= testScreen.maxX)
    // The panel moved but the icon did not, so the arrow must not stay centred.
    #expect(placement.arrowX == CGFloat(328))
    #expect(placement.arrowX > testPanel.width / 2)
    // Still points at the actual icon.
    #expect(placement.topLeft.x + placement.arrowX == CGFloat(2500))
}

@Test func panelClampsAtTheLeftEdgeToo() {
    let placement = PanelGeometry.place(
        panelSize: testPanel, iconCentreX: 30,
        menuBarBottomY: menuBarBottom, screen: testScreen)
    #expect(placement.topLeft.x == 8)
    #expect(placement.arrowX == 22)
}

@Test func panelPlacementSurvivesAScreenNarrowerThanItself() {
    let narrow = CGRect(x: 0, y: 0, width: 300, height: 800)
    let placement = PanelGeometry.place(
        panelSize: testPanel, iconCentreX: 150,
        menuBarBottomY: 800, screen: narrow)
    // Bounds cross; stay inside the left edge rather than jumping off-screen.
    #expect(placement.topLeft.x == 8)
}

@Test func panelPlacementRespectsASecondScreenOffset() {
    // A display to the right of the primary one: coordinates do not start at 0.
    let second = CGRect(x: 2560, y: 0, width: 1920, height: 1080)
    let placement = PanelGeometry.place(
        panelSize: testPanel, iconCentreX: 4460,
        menuBarBottomY: 1056, screen: second)
    #expect(placement.topLeft.x == CGFloat(4092))
    #expect(placement.topLeft.x + placement.arrowX == CGFloat(4460))
}

// MARK: - Display formatting

@Test func durationAndClockFormatting() {
    #expect(Format.duration(252) == "4:12")
    #expect(Format.duration(1720) == "28:40")
    #expect(Format.duration(3063) == "51:03")
    #expect(Format.duration(3723) == "1:02:03")
    #expect(Format.duration(0) == "0:00")
    // The HUD clock is fixed width so it does not jitter as it counts.
    #expect(Format.clock(0) == "00:00:00")
    #expect(Format.clock(736) == "00:12:16")
    #expect(Format.clock(3723) == "01:02:03")
    #expect(Format.clock(-5) == "00:00:00")
}

@Test func relativeDayFormatting() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Australia/Perth")!
    func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }
    let now = at(2026, 7, 31, 14, 0)   // a Friday
    #expect(Format.when(at(2026, 7, 31, 9, 14), now: now, calendar: calendar) == "Today 09:14")
    #expect(Format.when(at(2026, 7, 30, 8, 47), now: now, calendar: calendar) == "Yesterday 08:47")
    #expect(Format.when(at(2026, 7, 29, 10, 0), now: now, calendar: calendar) == "Wed")
    // Past a week, a weekday name stops telling you which week it was.
    #expect(Format.when(at(2026, 7, 3, 10, 0), now: now, calendar: calendar) == "3 Jul")
}

@Test func moneyFormatting() {
    #expect(Format.money(4.823) == "$4.82")
    #expect(Format.money(0) == "$0.00")
}

// MARK: - Waveform levels

@Test func levelMeterBucketsPeaksIntoBarsOldestFirst() {
    let meter = LevelMeter()
    meter.configure(sampleRate: 1000)   // 50 ms bars -> 50 frames per bar

    // Nothing recorded yet: silence, not garbage.
    #expect(meter.recent(4) == [0, 0, 0, 0])

    // One bar's worth in two callbacks keeps the louder of the two.
    meter.push(peak: 0.2, frames: 25)
    #expect(meter.recent(4) == [0, 0, 0, 0])   // bar not closed yet
    meter.push(peak: 0.8, frames: 25)
    #expect(meter.recent(4) == [0, 0, 0, 0.8])

    meter.push(peak: 0.4, frames: 50)
    #expect(meter.recent(4) == [0, 0, 0.8, 0.4])
    // The window resets, so a quiet bar reads quiet rather than holding the peak.
    meter.push(peak: 0.1, frames: 50)
    #expect(meter.recent(2) == [0.4, 0.1])
}

@Test func levelMeterWrapsAndResets() {
    let meter = LevelMeter()
    meter.configure(sampleRate: 1000)
    for i in 0..<(LevelMeter.capacity + 10) {
        meter.push(peak: Float(i % 10) / 10, frames: 50)
    }
    let recent = meter.recent(3)
    #expect(recent.count == 3)
    // Newest bar is the last one pushed.
    let last = Float((LevelMeter.capacity + 9) % 10) / 10
    #expect(abs(recent[2] - last) < 0.0001)

    meter.reset()
    #expect(meter.recent(8).allSatisfy { $0 == 0 })
}

// MARK: - Session history and usage

private func makeIndex() -> (SessionIndex, URL) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sessions-test-\(UUID().uuidString)")
        .appendingPathComponent("sessions.json")
    return (SessionIndex(url: url), url.deletingLastPathComponent())
}

private func record(_ title: String, at date: Date, minutes: Double,
                    cost: Double = 0) -> SessionRecord {
    SessionRecord(id: UUID().uuidString, title: title, presetName: "Meeting",
                  startedAt: date, recordedDuration: minutes * 60, costUSD: cost,
                  notePath: "/tmp/\(title).md")
}

@Test func sessionIndexKeepsNewestFirstAndTrimsTheTail() throws {
    let (index, dir) = makeIndex()
    defer { try? FileManager.default.removeItem(at: dir) }

    let now = Date()
    index.add(record("older", at: now.addingTimeInterval(-3600), minutes: 10))
    index.add(record("newer", at: now, minutes: 5))
    #expect(index.all().map(\.title) == ["newer", "older"])

    for i in 0..<SessionIndex.limit {
        index.add(record("bulk \(i)", at: now, minutes: 1))
    }
    #expect(index.all().count == SessionIndex.limit)
    #expect(index.all().first?.title == "bulk \(SessionIndex.limit - 1)")
}

@Test func usageCountsThisMonthOnly() throws {
    let (index, dir) = makeIndex()
    defer { try? FileManager.default.removeItem(at: dir) }

    let calendar = Calendar.current
    let now = Date()
    let lastMonth = calendar.date(byAdding: .month, value: -1, to: now)!
    index.add(record("this month", at: now, minutes: 90, cost: 1.20))
    index.add(record("also this month", at: now, minutes: 30, cost: 0.40))
    index.add(record("last month", at: lastMonth, minutes: 500, cost: 9.99))

    let usage = index.usage(minuteCap: 600, now: now)
    #expect(abs(usage.minutesUsed - 120) < 0.001)
    #expect(abs(usage.costUSD - 1.60) < 0.001)
    #expect(abs(usage.fraction - 0.2) < 0.001)
    #expect(!usage.isNearCap)
    #expect(!usage.isOverCap)
}

@Test func usageFlagsTheCapWithoutEverBlocking() {
    let near = Usage(minutesUsed: 480, minuteCap: 600, costUSD: 5, daysLeftInMonth: 3)
    #expect(near.isNearCap)
    #expect(!near.isOverCap)

    let over = Usage(minutesUsed: 700, minuteCap: 600, costUSD: 8, daysLeftInMonth: 1)
    #expect(over.isOverCap)
    // The bar saturates rather than overflowing.
    #expect(over.fraction == 1)

    // A cap of zero means no cap; never divide by it.
    let uncapped = Usage(minutesUsed: 100, minuteCap: 0, costUSD: 1, daysLeftInMonth: 5)
    #expect(uncapped.fraction == 0)
    #expect(!uncapped.isOverCap)
}

@Test func daysLeftCountsTodayAndResetsOnTheFirst() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Australia/Perth")!
    func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }
    // July has 31 days.
    #expect(SessionIndex.daysLeftInMonth(now: day(2026, 7, 1), calendar: calendar) == 31)
    #expect(SessionIndex.daysLeftInMonth(now: day(2026, 7, 13), calendar: calendar) == 19)
    #expect(SessionIndex.daysLeftInMonth(now: day(2026, 7, 31), calendar: calendar) == 1)
    // February 2028 is a leap year.
    #expect(SessionIndex.daysLeftInMonth(now: day(2028, 2, 1), calendar: calendar) == 29)
}

@Test func namingAddsToASessionsCostWithoutDuplicatingIt() throws {
    let (index, dir) = makeIndex()
    defer { try? FileManager.default.removeItem(at: dir) }

    let entry = record("Client call", at: Date(), minutes: 30, cost: 0.54)
    index.add(entry)
    index.addCost(0.10, toSessionID: entry.id)

    #expect(index.all().count == 1)
    #expect(abs((index.all().first?.costUSD ?? 0) - 0.64) < 0.001)

    // An unknown id is ignored rather than creating a phantom entry.
    index.addCost(5, toSessionID: "nope")
    #expect(index.all().count == 1)
    #expect(abs((index.all().first?.costUSD ?? 0) - 0.64) < 0.001)
}

// MARK: - Naming records

@Test func transcriptStoreRoundTripsAndPurges() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("transcripts-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TranscriptStore(root: dir)

    let session = Session(title: "Sync", presetName: "Meeting", participants: [],
                          startedAt: Date(), recordedDuration: 60)
    let t = Transcript(utterances: [Utterance(speaker: "Speaker 1", start: 0, end: 1, text: "x")])
    let record = NamingRecord(session: session, transcript: t, provider: "assemblyai",
                              costUSD: 0.5, notePath: "/tmp/n.md",
                              transcriptPath: "/tmp/t.md", noteHash: "abc")
    store.save(record)

    let loaded = try #require(store.load(session.id))
    #expect(loaded.transcript == t)
    #expect(loaded.namesApplied == false)
    #expect(store.all().count == 1)

    // Inside the window it survives; past it, it goes.
    store.purgeExpired(now: record.completedAt.addingTimeInterval(TranscriptStore.retention - 60))
    #expect(store.all().count == 1)
    store.purgeExpired(now: record.completedAt.addingTimeInterval(TranscriptStore.retention + 60))
    #expect(store.all().isEmpty)
}

@Test func overwriteKeepsBothFilenamesAndRelinksTranscript() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("vault-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let writer = VaultWriter(vaultURL: dir)
    var session = Session(title: "Sync", presetName: "Meeting", participants: [],
                          startedAt: Date(timeIntervalSince1970: 1_790_000_000),
                          recordedDuration: 60)
    let before = Transcript(utterances: [
        Utterance(speaker: "Speaker 1", start: 0, end: 1, text: "hello"),
    ])
    let first = try writer.write(session: session, noteBody: "# Before", transcript: before,
                                 provider: "assemblyai", costUSD: 0.1)

    session.participants = ["Sarah"]
    let after = before.renamingSpeakers(["Speaker 1": "Sarah"])
    let second = try writer.overwrite(
        noteURL: first.noteURL, transcriptURL: first.transcriptURL, session: session,
        noteBody: "# After", transcript: after, provider: "assemblyai", costUSD: 0.2)

    #expect(second.noteURL == first.noteURL)
    // No stray duplicate left behind.
    let notes = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "md" }
    #expect(notes.count == 1)

    let note = try String(contentsOf: second.noteURL, encoding: .utf8)
    #expect(note.contains("# After"))
    #expect(note.contains("participants: [Sarah]"))
    #expect(note.contains("cost: 0.2000"))
    // The wikilink still points at the transcript that was actually rewritten.
    let transcriptName = first.transcriptURL.deletingPathExtension().lastPathComponent
    #expect(note.contains("transcript: \"[[\(transcriptName)]]\""))
    let body = try String(contentsOf: second.transcriptURL, encoding: .utf8)
    #expect(body.contains("Sarah:** hello"))
}

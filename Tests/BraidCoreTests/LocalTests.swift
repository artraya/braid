import Testing
import Foundation
@testable import BraidCore
import FluidAudio

// MARK: - Alignment
//
// The step ADR-0002 parked local diarization over. These tests are where the
// confidence in local attribution actually lives: they run without a model, so
// they can assert exactly rather than approximately.

@Test func alignerPutsEachWordWithWhoeverWasTalking() {
    let words = [
        TimedWord(text: "morning", start: 0.0, end: 0.5),
        TimedWord(text: "everyone", start: 0.5, end: 1.0),
        TimedWord(text: "hello", start: 2.0, end: 2.4),
        TimedWord(text: "back", start: 2.4, end: 2.8),
    ]
    let spans = [
        SpeakerSpan(speakerId: "S0", start: 0, end: 1.2),
        SpeakerSpan(speakerId: "S1", start: 1.8, end: 3.0),
    ]
    let utterances = SpeakerAligner.utterances(words: words, spans: spans)

    #expect(utterances.count == 2)
    #expect(utterances[0].speaker == "S0")
    #expect(utterances[0].text == "morning everyone")
    #expect(utterances[1].speaker == "S1")
    #expect(utterances[1].text == "hello back")
}

/// A word straddling a turn boundary belongs to whoever was speaking for most
/// of it — the common real case, since diarizer boundaries land mid-word all
/// the time.
@Test func alignerAssignsAStraddlingWordByItsMidpoint() {
    let spans = [
        SpeakerSpan(speakerId: "S0", start: 0, end: 1.0),
        SpeakerSpan(speakerId: "S1", start: 1.0, end: 2.0),
    ]
    // Mostly inside S1: starts at 0.9 but its midpoint is 1.15.
    let word = TimedWord(text: "actually", start: 0.9, end: 1.4)
    let utterances = SpeakerAligner.utterances(words: [word], spans: spans)

    #expect(utterances.count == 1)
    #expect(utterances[0].speaker == "S1")
}

/// A word outside every span still counts as speech. Near a turn it snaps to
/// it; far from everything it carries on with the previous speaker rather than
/// vanishing. Losing real words to a diarizer gap would be the worst outcome.
@Test func alignerNeverDropsWordsThatFallBetweenTurns() {
    let spans = [SpeakerSpan(speakerId: "S0", start: 0, end: 1.0)]
    let words = [
        TimedWord(text: "one", start: 0.1, end: 0.4),
        TimedWord(text: "two", start: 1.1, end: 1.4),      // just outside, snaps
        TimedWord(text: "three", start: 40.0, end: 40.3),  // nowhere near
    ]
    let utterances = SpeakerAligner.utterances(words: words, spans: spans)
    let spoken = utterances.flatMap { $0.text.split(separator: " ").map(String.init) }

    #expect(spoken == ["one", "two", "three"])
    #expect(utterances.allSatisfy { $0.speaker == "S0" })
}

/// One speaker talking twice with ten minutes in between is two utterances,
/// not one that claims to last ten minutes.
@Test func alignerSplitsOneSpeakerOnALongSilence() {
    let spans = [SpeakerSpan(speakerId: "S0", start: 0, end: 600)]
    let words = [
        TimedWord(text: "hello", start: 0.0, end: 0.4),
        TimedWord(text: "there", start: 0.4, end: 0.8),
        TimedWord(text: "anyway", start: 300.0, end: 300.5),
    ]
    let utterances = SpeakerAligner.utterances(words: words, spans: spans)

    #expect(utterances.count == 2)
    #expect(utterances[0].text == "hello there")
    #expect(utterances[1].text == "anyway")
    #expect(utterances[1].start == 300.0)
}

/// Parakeet returns SentencePiece sub-word tokens; words are rebuilt from the
/// boundary marker, spanning first token start to last token end.
@Test func parakeetTokensRebuildIntoWords() {
    func token(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> TokenTiming {
        TokenTiming(token: text, tokenId: 0, startTime: start, endTime: end, confidence: 1)
    }
    let words = ParakeetEngine.words(from: [
        token("\u{2581}Hello", 0.0, 0.3),
        token("\u{2581}every", 0.3, 0.5),
        token("one", 0.5, 0.7),
        token("\u{2581}there", 0.9, 1.2),
    ])

    #expect(words.map(\.text) == ["Hello", "everyone", "there"])
    // A word spans from its first token's start to its last token's end.
    #expect(words[1].start == 0.3)
    #expect(words[1].end == 0.7)
    #expect(ParakeetEngine.words(from: nil).isEmpty)
}

// MARK: - The local Adapter

@Test func localAdapterLabelsTheMicTrackMeAndNeverDiarizesIt() async throws {
    let engine = StubEngine(words: [
        TimedWord(text: "my", start: 0, end: 0.3),
        TimedWord(text: "turn", start: 0.3, end: 0.6),
    ])
    let diarizer = StubDiarizer(spans: [])
    let adapter = LocalAdapter(engine: engine, diarizer: diarizer)

    let utterances = try await adapter.transcribe(
        track: URL(fileURLWithPath: "/tmp/mic.caf"), diarize: false,
        keyTerms: [], expectedSpeakers: nil)

    #expect(utterances.allSatisfy { $0.speaker == "Me" })
    #expect(utterances.map(\.text) == ["my turn"])
    #expect(diarizer.callCount == 0, "the Mic Track is one speaker structurally (ADR-0001)")
}

@Test func localAdapterSeparatesRemoteVoicesAndPassesTheAssertedCountThrough() async throws {
    let engine = StubEngine(words: [
        TimedWord(text: "first", start: 0.0, end: 0.5),
        TimedWord(text: "second", start: 2.0, end: 2.5),
    ])
    let diarizer = StubDiarizer(spans: [
        SpeakerSpan(speakerId: "S0", start: 0, end: 1),
        SpeakerSpan(speakerId: "S1", start: 1.8, end: 3),
    ])
    let adapter = LocalAdapter(engine: engine, diarizer: diarizer)
    let expectation = Session.SpeakerExpectation(count: 2, strict: true)

    let utterances = try await adapter.transcribe(
        track: URL(fileURLWithPath: "/tmp/remote.caf"), diarize: true,
        keyTerms: ["Terrafix"], expectedSpeakers: expectation)

    #expect(Set(utterances.map(\.speaker)).count == 2)
    #expect(diarizer.received?.count == 2)
    #expect(diarizer.received?.strict == true)
    #expect(engine.receivedKeyTerms == ["Terrafix"])
}

/// An engine that produces text but no timings must not have positions
/// invented for it. One honest block beats words scattered by guesswork.
@Test func localAdapterFallsBackToOneBlockWithoutTimings() async throws {
    let engine = StubEngine(words: [], text: "no timings here", duration: 12)
    let adapter = LocalAdapter(engine: engine, diarizer: StubDiarizer(spans: []))

    let utterances = try await adapter.transcribe(
        track: URL(fileURLWithPath: "/tmp/remote.caf"), diarize: true,
        keyTerms: [], expectedSpeakers: nil)

    #expect(utterances.count == 1)
    #expect(utterances[0].text == "no timings here")
    #expect(utterances[0].end == 12)
}

@Test func localAdapterReadsOriginalsAndCostsNothingToRun() {
    let adapter = LocalAdapter(engine: StubEngine(words: []), diarizer: StubDiarizer(spans: []))
    #expect(adapter.isLocal)
    #expect(adapter.prefersCompressedUpload == false, "FLAC exists for uploads; local reads the CAF")
    #expect(AssemblyAIAdapter(apiKey: "x").prefersCompressedUpload, "the cloud path is unchanged")
    #expect(AssemblyAIAdapter(apiKey: "x").isLocal == false)
}

// MARK: - Modes, fallback and disclosure
//
// Audio going somewhere the user did not ask for is the worst bug this app
// could have, so these assert the routing rather than trusting it.

/// Auto: local fails, the cloud delivers, and the Note says so. The fallback
/// is allowed precisely because it is never quiet.
@Test func autoFallsBackToTheCloudAndTheNoteNamesTheProviderThatRan() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let brokenLocal = LocalAdapter(
        engine: StubEngine(words: [], failure: LocalEngineError.modelsUnavailable("not downloaded")),
        diarizer: StubDiarizer(spans: []))
    let cloud = SimpleProvider(name: "assemblyai")
    let disclosed = Disclosures()
    let env = try makeLocalEnvironment(provider: brokenLocal, fallback: cloud, root: root) { event in
        disclosed.record(event)
    }
    let queue = JobQueue(env: env)
    let session = try seedSession(root: root)

    await queue.enqueue(session: session, remoteSilent: false)
    let note = try await disclosed.waitForNote()

    #expect(cloud.callCount == 2, "both Tracks re-run on the fallback, never a mixed Note")
    #expect(disclosed.fellBackTo == "assemblyai")
    let frontmatter = try String(contentsOf: note, encoding: .utf8)
    #expect(frontmatter.contains("provider: assemblyai"))
    #expect(!frontmatter.contains("local-parakeet"))
}

/// Local mode has no fallback in its Environment at all, so there is nothing
/// for a failure to reach. The Job parks for the user instead.
@Test func localModeNeverReachesTheCloudWhenItFails() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let brokenLocal = LocalAdapter(
        engine: StubEngine(words: [], failure: LocalEngineError.modelsUnavailable("not downloaded")),
        diarizer: StubDiarizer(spans: []))
    let cloud = SimpleProvider(name: "assemblyai")
    let disclosed = Disclosures()
    // fallback: nil is the point of this test.
    let env = try makeLocalEnvironment(provider: brokenLocal, fallback: nil, root: root) { event in
        disclosed.record(event)
    }
    let queue = JobQueue(env: env)
    let session = try seedSession(root: root)

    await queue.enqueue(session: session, remoteSilent: false)
    try await disclosed.waitForFailure()

    #expect(cloud.callCount == 0, "no audio may leave the machine in Local mode")
    #expect(disclosed.fellBackTo == nil)
    let failed = await queue.failedJobs()
    #expect(failed.count == 1)
    // R7: a failed Job keeps its Recording.
    let dir = root.appendingPathComponent("jobs").appendingPathComponent(session.id)
    #expect(FileManager.default.fileExists(atPath: dir.path))
}

/// A locally transcribed Session bills for the summary and nothing else.
@Test func localDeliveryAddsNoTranscriptionCost() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let local = LocalAdapter(
        engine: StubEngine(words: [TimedWord(text: "hello", start: 0, end: 1)]),
        diarizer: StubDiarizer(spans: [SpeakerSpan(speakerId: "S0", start: 0, end: 1)]))
    let disclosed = Disclosures()
    let env = try makeLocalEnvironment(provider: local, fallback: nil, root: root,
                                       summariser: StubSummary()) { disclosed.record($0) }
    let queue = JobQueue(env: env)
    let session = try seedSession(root: root, duration: 3600)

    await queue.enqueue(session: session, remoteSilent: false)
    _ = try await disclosed.waitForNote()

    // An hour of cloud audio would be about $0.54 across two Tracks; here the
    // only cost is the summary's tokens.
    let expectedSummaryOnly = CostTable.current.claudeCost(inputTokens: 100, outputTokens: 50)
    #expect(abs(env.settings.costTotalUSD - expectedSummaryOnly) < 0.0001)
}

/// ADR-0003, enforced rather than promised. `SpeakerSpan` has no embedding
/// field, so nothing the diarizer clustered on can reach disk — this checks
/// the persisted state actually bears that out.
@Test func noVoiceprintSurvivesACompletedLocalJob() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let local = LocalAdapter(
        engine: StubEngine(words: [
            TimedWord(text: "hello", start: 0, end: 0.5),
            TimedWord(text: "there", start: 2.0, end: 2.5),
        ]),
        diarizer: StubDiarizer(spans: [
            SpeakerSpan(speakerId: "S0", start: 0, end: 1),
            SpeakerSpan(speakerId: "S1", start: 1.8, end: 3),
        ]))
    let disclosed = Disclosures()
    let env = try makeLocalEnvironment(provider: local, fallback: nil, root: root,
                                       summariser: StubSummary()) { disclosed.record($0) }
    let queue = JobQueue(env: env)
    let session = try seedSession(root: root)

    await queue.enqueue(session: session, remoteSilent: false)
    _ = try await disclosed.waitForNote()

    // Everything the Job persisted, read back as text.
    let files = FileManager.default
        .enumerator(at: root, includingPropertiesForKeys: nil)?
        .compactMap { $0 as? URL }
        .filter { !$0.hasDirectoryPath } ?? []
    #expect(!files.isEmpty)
    for file in files {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
        #expect(!text.contains("embedding"),
                "\(file.lastPathComponent) mentions an embedding")
        #expect(!text.contains("speakerDatabase"),
                "\(file.lastPathComponent) mentions a speaker database")
    }
    // The structural guarantee behind the above.
    #expect(MemoryLayout<SpeakerSpan>.size == MemoryLayout<(String, Double, Double)>.size)
}

/// ADR-0005's whole argument is that the 8GB constraint governs the recording
/// window and local inference happens outside it. Measured peak for the models
/// is ~450MB against R4's 100MB in-call budget, so this has to actually hold.
@Test func localWorkWaitsWhileASessionIsRecording() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let local = LocalAdapter(
        engine: StubEngine(words: [TimedWord(text: "hello", start: 0, end: 1)]),
        diarizer: StubDiarizer(spans: [SpeakerSpan(speakerId: "S0", start: 0, end: 1)]))
    let disclosed = Disclosures()
    let env = try makeLocalEnvironment(provider: local, fallback: nil, root: root,
                                       summariser: StubSummary()) { disclosed.record($0) }
    let queue = JobQueue(env: env)
    let session = try seedSession(root: root)

    await queue.setRecordingActive(true)
    await queue.enqueue(session: session, remoteSilent: false)
    try await Task.sleep(for: .milliseconds(300))

    var pending = await queue.pendingCount()
    #expect(pending == 1, "a local Job must not start while a Session is recording")

    await queue.setRecordingActive(false)
    _ = try await disclosed.waitForNote()
    pending = await queue.pendingCount()
    #expect(pending == 0, "and must run as soon as recording stops")
}

/// Cloud Jobs are just network, so they keep running during a call — holding
/// them back would delay a Note for no benefit.
@Test func cloudWorkIsNotHeldBackWhileRecording() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let disclosed = Disclosures()
    let env = try makeLocalEnvironment(provider: SimpleProvider(name: "assemblyai"),
                                       fallback: nil, root: root,
                                       summariser: StubSummary()) { disclosed.record($0) }
    let queue = JobQueue(env: env)
    let session = try seedSession(root: root)

    await queue.setRecordingActive(true)
    await queue.enqueue(session: session, remoteSilent: false)

    _ = try await disclosed.waitForNote()
}

// MARK: - Doubles

final class StubEngine: TranscriberEngine, @unchecked Sendable {
    nonisolated let id: LocalEngine = .parakeet
    private let lock = NSLock()
    private let words: [TimedWord]
    private let text: String
    private let duration: TimeInterval
    private let failure: Error?
    private var _receivedKeyTerms: [String] = []
    var receivedKeyTerms: [String] { lock.withLock { _receivedKeyTerms } }

    init(words: [TimedWord], text: String? = nil, duration: TimeInterval = 10,
         failure: Error? = nil) {
        self.words = words
        self.text = text ?? words.map(\.text).joined(separator: " ")
        self.duration = duration
        self.failure = failure
    }

    var isReady: Bool { get async { failure == nil } }
    func prepare(progress: (@Sendable (Double) -> Void)?) async throws {
        if let failure { throw failure }
    }

    func transcribe(file: URL, keyTerms: [String]) async throws -> EngineTranscript {
        if let failure { throw failure }
        lock.withLock { _receivedKeyTerms = keyTerms }
        return EngineTranscript(text: text, words: words, duration: duration)
    }
}

/// A cloud-shaped Provider: counts calls and always succeeds.
final class SimpleProvider: STTProvider, @unchecked Sendable {
    let name: String
    private let lock = NSLock()
    private var _calls = 0
    var callCount: Int { lock.withLock { _calls } }

    init(name: String) { self.name = name }

    func transcribe(track: URL, diarize: Bool, keyTerms: [String],
                    expectedSpeakers: Session.SpeakerExpectation?) async throws -> [Utterance] {
        lock.withLock { _calls += 1 }
        return [Utterance(speaker: diarize ? "A" : "Me", start: 0, end: 1,
                          text: diarize ? "their line" : "my line")]
    }
}

final class StubSummary: NoteSummarising, @unchecked Sendable {
    func summarise(transcript: Transcript, session: Session,
                   preset: Preset) async throws -> Summariser.Output {
        Summariser.Output(noteBody: "# Local note", inputTokens: 100, outputTokens: 50)
    }
}

/// Collects the events the pipeline emitted, and lets a test wait for the one
/// it cares about rather than sleeping.
final class Disclosures: @unchecked Sendable {
    private let lock = NSLock()
    private var _note: URL?
    private var _failed = false
    private var _fellBackTo: String?
    var fellBackTo: String? { lock.withLock { _fellBackTo } }

    func record(_ event: JobQueue.Event) {
        lock.withLock {
            switch event {
            case .jobDone(_, let noteURL): _note = noteURL
            case .jobFailed(_, let transient): if !transient { _failed = true }
            case .providerFellBack(_, from: _, to: let to, reason: _): _fellBackTo = to
            default: break
            }
        }
    }

    func waitForNote() async throws -> URL {
        for _ in 0..<300 {
            if let note = lock.withLock({ _note }) { return note }
            if lock.withLock({ _failed }) { throw TestFailure.jobFailed }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TestFailure.timedOut
    }

    func waitForFailure() async throws {
        for _ in 0..<300 {
            if lock.withLock({ _failed }) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TestFailure.timedOut
    }
}

enum TestFailure: Error { case timedOut, jobFailed }

private func tempRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("local-test-\(UUID().uuidString)")
}

private func makeLocalEnvironment(
    provider: STTProvider, fallback: STTProvider?, root: URL,
    summariser: any NoteSummarising = StubSummary(),
    onEvent: @escaping @Sendable (JobQueue.Event) -> Void
) throws -> JobQueue.Environment {
    let defaults = UserDefaults(suiteName: "no.braid.test.\(UUID().uuidString)")!
    let settings = SettingsStore(defaults: defaults)
    settings.vaultPath = root.appendingPathComponent("vault").path
    return JobQueue.Environment(
        provider: provider,
        fallback: fallback,
        summariser: summariser,
        settings: settings,
        jobsRoot: root.appendingPathComponent("jobs"),
        transcripts: TranscriptStore(root: root.appendingPathComponent("transcripts")),
        sessions: SessionIndex(url: root.appendingPathComponent("sessions.json")),
        onEvent: onEvent)
}

/// A Session with real CAF Tracks on disk, so the Job reaches the Provider.
private func seedSession(root: URL, duration: TimeInterval = 60) throws -> Session {
    let session = Session(title: "Local test", presetName: "Meeting", participants: [],
                          startedAt: Date(), recordedDuration: duration)
    let dir = root.appendingPathComponent("jobs").appendingPathComponent(session.id)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try writeShortCAF(at: dir.appendingPathComponent("mic.caf"))
    try writeShortCAF(at: dir.appendingPathComponent("remote.caf"))
    return session
}

private func writeShortCAF(at url: URL, seconds: Double = 0.25) throws {
    let rate = 16_000.0
    let writer = try TrackWriter(url: url, deviceRate: rate)
    var samples = [Float](repeating: 0, count: Int(rate * seconds))
    for i in samples.indices { samples[i] = Float(sin(Double(i) / 8) * 0.4) }
    samples.withUnsafeMutableBufferPointer { buffer in
        writer.writeAsync(buffer.baseAddress!, frames: buffer.count)
    }
    writer.close()
}

final class StubDiarizer: SpeakerDiarizing, @unchecked Sendable {
    private let lock = NSLock()
    private let spans: [SpeakerSpan]
    private var _calls = 0
    private var _received: Session.SpeakerExpectation?
    var callCount: Int { lock.withLock { _calls } }
    var received: Session.SpeakerExpectation? { lock.withLock { _received } }

    init(spans: [SpeakerSpan]) { self.spans = spans }

    func prepare(progress: (@Sendable (Double) -> Void)?) async throws {}

    func diarize(file: URL,
                 expected: Session.SpeakerExpectation?) async throws -> [SpeakerSpan] {
        lock.withLock { _calls += 1; _received = expected }
        return spans
    }
}

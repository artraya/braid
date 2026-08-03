import Testing
import Foundation
@testable import BraidCore
import FluidAudio

// MARK: - Alignment
//
// These tests are where the confidence in local attribution actually lives:
// they run without a model, so they can assert exactly rather than
// approximately.

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

// MARK: - The Transcriber (R6, R22)

@Test func micTrackIsNeverDiarized() async throws {
    let engine = StubEngine(words: [
        TimedWord(text: "my", start: 0, end: 0.3),
        TimedWord(text: "turn", start: 0.3, end: 0.6),
    ])
    let diarizer = StubDiarizer(spans: [])
    let transcriber = Transcriber(engine: engine, diarizer: diarizer)

    let result = try await transcriber.transcribeMic(
        track: URL(fileURLWithPath: "/tmp/mic.caf"), keyTerms: [], wantsVoice: false)

    #expect(result.utterances.allSatisfy { $0.speaker == "Me" })
    #expect(result.utterances.map(\.text) == ["my turn"])
    #expect(diarizer.callCount == 0, "the Mic Track is one speaker structurally (ADR-0001)")
}

/// R28: the one time the Mic Track meets the diarizer, it is pinned to exactly
/// one speaker — an embedding of the owner, never a split.
@Test func learningMeAsksForExactlyOneSpeaker() async throws {
    let engine = StubEngine(words: [TimedWord(text: "mine", start: 0, end: 1)])
    let diarizer = StubDiarizer(
        spans: [SpeakerSpan(speakerId: "S0", start: 0, end: 30)],
        voices: [SpeakerVoice(speakerId: "S0", centroid: unitVector(seed: 1), seconds: 30)])
    let transcriber = Transcriber(engine: engine, diarizer: diarizer)

    let result = try await transcriber.transcribeMic(
        track: URL(fileURLWithPath: "/tmp/mic.caf"), keyTerms: [], wantsVoice: true)

    #expect(diarizer.received?.count == 1)
    #expect(diarizer.received?.strict == true, "pinned to one voice, so it cannot be split")
    #expect(result.voices.count == 1)
    #expect(result.voices.first?.speakerId == "Me")
}

@Test func engineReceivesKeyTermsAndDiarizerTheAssertedCount() async throws {
    let engine = StubEngine(words: [
        TimedWord(text: "first", start: 0.0, end: 0.5),
        TimedWord(text: "second", start: 2.0, end: 2.5),
    ])
    let diarizer = StubDiarizer(spans: [
        SpeakerSpan(speakerId: "S0", start: 0, end: 1),
        SpeakerSpan(speakerId: "S1", start: 1.8, end: 3),
    ])
    let transcriber = Transcriber(engine: engine, diarizer: diarizer)
    let expectation = Session.SpeakerExpectation(count: 2, strict: true)

    let result = try await transcriber.transcribeRemote(
        track: URL(fileURLWithPath: "/tmp/remote.caf"), keyTerms: ["Terrafix"],
        expectedSpeakers: expectation, known: nil)

    #expect(Set(result.utterances.map(\.speaker)).count == 2)
    #expect(diarizer.received?.count == 2)
    #expect(diarizer.received?.strict == true)
    #expect(engine.receivedKeyTerms == ["Terrafix"])
}

/// An engine that produces text but no timings must not have positions
/// invented for it. One honest block beats words scattered by guesswork.
@Test func pipelineFallsBackToOneBlockWithoutTimings() async throws {
    let engine = StubEngine(words: [], text: "no timings here", duration: 12)
    let transcriber = Transcriber(engine: engine, diarizer: StubDiarizer(spans: []))

    let result = try await transcriber.transcribeRemote(
        track: URL(fileURLWithPath: "/tmp/remote.caf"), keyTerms: [],
        expectedSpeakers: nil, known: nil)

    #expect(result.utterances.count == 1)
    #expect(result.utterances[0].text == "no timings here")
    #expect(result.utterances[0].end == 12)
}

// MARK: - The pipeline

/// ADR-0005's whole argument is that the 8GB constraint governs the recording
/// window and inference happens outside it. Measured peak for the models is
/// ~300MB against R4's 100MB in-call budget, so this has to actually hold.
@Test func localWorkWaitsWhileASessionIsRecording() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let disclosed = Disclosures()
    let env = try makeLocalEnvironment(root: root) { disclosed.record($0) }
    let queue = JobQueue(env: env)
    let session = try seedSession(root: root)

    await queue.setRecordingActive(true)
    await queue.enqueue(session: session, remoteSilent: false)
    try await Task.sleep(for: .milliseconds(300))

    var pending = await queue.pendingCount()
    #expect(pending == 1, "a Job must not start while a Session is recording")

    await queue.setRecordingActive(false)
    _ = try await disclosed.waitForNote()
    pending = await queue.pendingCount()
    #expect(pending == 0, "and must run as soon as recording stops")
}

/// R21: the raw material of diarization dies with its Job. Only a Voiceprint
/// the user vouched for may persist, and there is no naming in this Session.
@Test func noRawEmbeddingSurvivesACompletedJob() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let disclosed = Disclosures()
    let env = try makeLocalEnvironment(
        root: root,
        diarizer: StubDiarizer(
            spans: [SpeakerSpan(speakerId: "S0", start: 0, end: 1),
                    SpeakerSpan(speakerId: "S1", start: 1.8, end: 3)],
            voices: [SpeakerVoice(speakerId: "S0", centroid: unitVector(seed: 7), seconds: 40),
                     SpeakerVoice(speakerId: "S1", centroid: unitVector(seed: 9), seconds: 30)],
            chunks: [VoiceChunk(speakerId: "S0", start: 0, end: 1,
                                embedding: unitVector(seed: 7))])) { disclosed.record($0) }
    let queue = JobQueue(env: env)
    let session = try seedSession(root: root)

    await queue.enqueue(session: session, remoteSilent: false)
    _ = try await disclosed.waitForNote()

    // Everything the Job persisted, read back as text. The candidate centroids
    // an unnamed Speaker leaves behind live in the encrypted naming record, so
    // nothing readable on disk may mention them.
    let files = FileManager.default
        .enumerator(at: root, includingPropertiesForKeys: nil)?
        .compactMap { $0 as? URL }
        .filter { !$0.hasDirectoryPath } ?? []
    #expect(!files.isEmpty)
    for file in files {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
        #expect(!text.contains("centroid"), "\(file.lastPathComponent) mentions a centroid")
        #expect(!text.contains("embedding"), "\(file.lastPathComponent) mentions an embedding")
        #expect(!text.contains("voiceprint"), "\(file.lastPathComponent) mentions a voiceprint")
    }
    // The structural guarantee behind the above: a turn is a label and two
    // timestamps, and the aligner can see nothing else.
    #expect(MemoryLayout<SpeakerSpan>.size == MemoryLayout<(String, Double, Double)>.size)
}

/// R21: the naming record holds transcript text and candidate voiceprints, so
/// it is sealed with the same key as the database.
@Test func namingRecordsAreNotPlaintextOnDisk() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let disclosed = Disclosures()
    let env = try makeLocalEnvironment(root: root) { disclosed.record($0) }
    let queue = JobQueue(env: env)
    let session = try seedSession(root: root)
    await queue.enqueue(session: session, remoteSilent: false)
    _ = try await disclosed.waitForNote()

    let stored = try FileManager.default.contentsOfDirectory(
        at: root.appendingPathComponent("transcripts"), includingPropertiesForKeys: nil)
    #expect(!stored.isEmpty, "the Session had a voice to name, so a record exists")
    for file in stored {
        let data = try Data(contentsOf: file)
        let asText = String(data: data, encoding: .utf8) ?? ""
        #expect(!asText.contains("their line"), "transcript text is readable on disk")
        // And it round-trips through the store that owns the key.
        #expect(env.transcripts.load(session.id) != nil)
    }
}

// MARK: - Held Delivery (R26)

@Test func heldDeliveryWaitsForNaming() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let disclosed = Disclosures()
    let env = try makeLocalEnvironment(root: root, delivery: .held) { disclosed.record($0) }
    let queue = JobQueue(env: env)
    let session = try seedSession(root: root)

    await queue.enqueue(session: session, remoteSilent: false)
    try await disclosed.waitForHold()

    let held = await queue.heldJobs()
    #expect(held.count == 1)
    #expect(disclosed.note == nil, "nothing may be written before the names arrive")
    // R7/R26: the Recording is retained for the whole wait.
    let dir = root.appendingPathComponent("jobs").appendingPathComponent(session.id)
    #expect(FileManager.default.fileExists(atPath: dir.path))
    // And the record exists, undelivered, so the panel can show it.
    let record = env.transcripts.load(session.id)
    #expect(record?.isDelivered == false)
}

@Test func namingReleasesAHeldJob() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let disclosed = Disclosures()
    let env = try makeLocalEnvironment(root: root, delivery: .held) { disclosed.record($0) }
    let queue = JobQueue(env: env)
    let session = try seedSession(root: root)

    await queue.enqueue(session: session, remoteSilent: false)
    try await disclosed.waitForHold()

    let note = try await queue.applyNames(sessionID: session.id, names: ["Speaker 1": "Sarah"])
    let written = try String(contentsOf: note, encoding: .utf8)
    #expect(written.contains("engine:"))

    let transcript = try String(
        contentsOf: URL(fileURLWithPath: env.transcripts.load(session.id)!.transcriptPath),
        encoding: .utf8)
    #expect(transcript.contains("Sarah"))
    #expect(!transcript.contains("Speaker 1"))

    // The Job is finished and its Recording is gone (R7).
    let dir = root.appendingPathComponent("jobs").appendingPathComponent(session.id)
    #expect(!FileManager.default.fileExists(atPath: dir.path))
    let stillHeld = await queue.heldJobs()
    #expect(stillHeld.isEmpty)
}

/// R26: Held never waits when it has nothing to ask. A voice the database
/// already knows is named without anyone being interrupted.
@Test func heldDeliveryWithEverySpeakerMatchedDeliversImmediately() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let known = unitVector(seed: 3)
    let box = SecretBox.ephemeral()
    let voices = VoiceStore(url: root.appendingPathComponent("voices.dat"), box: box)
    await voices.enroll(SpeakerVoice(speakerId: "S0", centroid: known, seconds: 60), as: "Sarah")

    let disclosed = Disclosures()
    let env = try makeLocalEnvironment(
        root: root, delivery: .held, box: box, voices: voices,
        diarizer: StubDiarizer(
            spans: [SpeakerSpan(speakerId: "S0", start: 0, end: 3)],
            voices: [SpeakerVoice(speakerId: "S0", centroid: known, seconds: 60)])
    ) { disclosed.record($0) }
    let queue = JobQueue(env: env)
    let session = try seedSession(root: root)

    await queue.enqueue(session: session, remoteSilent: false)
    let note = try await disclosed.waitForNote()

    let transcript = try String(
        contentsOf: URL(fileURLWithPath: env.transcripts.load(session.id)!.transcriptPath),
        encoding: .utf8)
    #expect(transcript.contains("Sarah"), "a recognised voice is named without being asked")
    #expect(!transcript.contains("Speaker 1"))
    #expect(note.lastPathComponent.hasSuffix(".md"))
}

/// R25: skipping resolves Identification just as naming does — the clips go,
/// and a Held Session delivers with the labels it has.
@Test func skippingResolvesIdentificationAndDeletesClips() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let disclosed = Disclosures()
    let env = try makeLocalEnvironment(root: root, delivery: .held) { disclosed.record($0) }
    let queue = JobQueue(env: env)
    let session = try seedSession(root: root)

    await queue.enqueue(session: session, remoteSilent: false)
    try await disclosed.waitForHold()

    let note = try await queue.skipNaming(sessionID: session.id)
    #expect(note != nil, "a Held Session still gets its Note")
    #expect(env.clips.clips(for: session.id).isEmpty)
    #expect(env.transcripts.load(session.id)?.namesApplied == true)
    #expect(env.transcripts.load(session.id)?.candidates.isEmpty == true)
}

/// R24, the case that matters most: Braid named a returning voice by itself and
/// got it wrong. Correcting it must remove the Voiceprint that produced the
/// wrong match, not merely relabel the Note — otherwise the same mistake
/// arrives again next week.
@Test func correctingAnAutoNamedVoiceUnlearnsTheVoiceprintBehindIt() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let known = unitVector(seed: 3)
    let box = SecretBox.ephemeral()
    let voices = VoiceStore(url: root.appendingPathComponent("voices.dat"), box: box)
    await voices.enroll(SpeakerVoice(speakerId: "S0", centroid: known, seconds: 60), as: "Sarah")

    let disclosed = Disclosures()
    let env = try makeLocalEnvironment(
        root: root, box: box, voices: voices,
        diarizer: StubDiarizer(
            spans: [SpeakerSpan(speakerId: "S0", start: 0, end: 3)],
            voices: [SpeakerVoice(speakerId: "S0", centroid: known, seconds: 60)])
    ) { disclosed.record($0) }
    let queue = JobQueue(env: env)
    let session = try seedSession(root: root)

    await queue.enqueue(session: session, remoteSilent: false)
    _ = try await disclosed.waitForNote()

    // Auto-named, and the record knows which Person it credited — keyed by the
    // name the Transcript actually carries, which is what the naming flow sends.
    let record = try #require(env.transcripts.load(session.id))
    #expect(record.autoNamed["Sarah"] != nil)
    #expect(record.candidates["Sarah"] != nil)
    let before = await voices.database()
    #expect(before.person(named: "Sarah")?.voiceprints.count == 2,
            "being recognised contributes a fresh exemplar")

    // It was actually Tom.
    _ = try await queue.applyNames(sessionID: session.id, names: ["Sarah": "Tom"])

    let after = await voices.database()
    #expect(after.person(named: "Tom") != nil, "the right person was learned")
    #expect((after.person(named: "Sarah")?.voiceprints.count ?? 0) < 2,
            "the voiceprint that caused the wrong name is gone")
    let transcript = try String(
        contentsOf: URL(fileURLWithPath: after.persons.isEmpty ? "/dev/null"
                        : env.transcripts.load(session.id)!.transcriptPath),
        encoding: .utf8)
    #expect(transcript.contains("Tom"))
    #expect(!transcript.contains("Sarah"))
}

/// R28: the owner's voice bouncing back off the far end is folded into "Me",
/// never dropped — those words were said.
@Test func echoOfMeIsFoldedNotDeleted() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let mine = unitVector(seed: 11)
    let box = SecretBox.ephemeral()
    let voices = VoiceStore(url: root.appendingPathComponent("voices.dat"), box: box)
    await voices.enrollMe(SpeakerVoice(speakerId: "Me", centroid: mine, seconds: 90))

    let disclosed = Disclosures()
    let env = try makeLocalEnvironment(
        root: root, box: box, voices: voices,
        diarizer: StubDiarizer(
            spans: [SpeakerSpan(speakerId: "S0", start: 0, end: 3)],
            voices: [SpeakerVoice(speakerId: "S0", centroid: mine, seconds: 40)])
    ) { disclosed.record($0) }
    let queue = JobQueue(env: env)
    let session = try seedSession(root: root)

    await queue.enqueue(session: session, remoteSilent: false)
    _ = try await disclosed.waitForNote()

    let record = try #require(env.transcripts.load(session.id))
    let text = record.transcript.markdown()
    #expect(text.contains("Me (echo)"))
    #expect(text.contains("their line"), "the words survive; only the label changes")
    // Folded voices are resolved: nothing to ask, nothing to enroll.
    #expect(record.candidates["Me (echo)"] == nil)
    #expect(env.clips.clips(for: session.id).isEmpty)
}

// MARK: - Doubles

func unitVector(seed: Int) -> [Float] {
    // Deterministic, well-separated directions in a 256-dimensional space.
    var v = [Float](repeating: 0, count: 256)
    for i in v.indices {
        v[i] = Float(sin(Double((i + 1) * seed) * 0.7)) + Float(seed % 3) * 0.01
    }
    return Vector.normalised(v)
}

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

final class StubDiarizer: SpeakerDiarizing, @unchecked Sendable {
    private let lock = NSLock()
    private let spans: [SpeakerSpan]
    private let voices: [SpeakerVoice]
    private let chunks: [VoiceChunk]
    private var _calls = 0
    private var _received: Session.SpeakerExpectation?
    var callCount: Int { lock.withLock { _calls } }
    var received: Session.SpeakerExpectation? { lock.withLock { _received } }

    init(spans: [SpeakerSpan], voices: [SpeakerVoice] = [], chunks: [VoiceChunk] = []) {
        self.spans = spans
        self.voices = voices
        self.chunks = chunks
    }

    func prepare(progress: (@Sendable (Double) -> Void)?) async throws {}

    func diarize(file: URL, expected: Session.SpeakerExpectation?,
                 wantsVoiceData: Bool) async throws -> DiarizationOutput {
        lock.withLock { _calls += 1; _received = expected }
        return DiarizationOutput(spans: spans,
                                 voices: wantsVoiceData ? voices : [],
                                 chunks: wantsVoiceData ? chunks : [])
    }
}

final class StubSummary: NoteSummarising, @unchecked Sendable {
    func summarise(transcript: Transcript, session: Session,
                   preset: Preset) async throws -> SummaryOutput {
        SummaryOutput(noteBody: "# Local note")
    }
}

/// Collects the events the pipeline emitted, and lets a test wait for the one
/// it cares about rather than sleeping.
final class Disclosures: @unchecked Sendable {
    private let lock = NSLock()
    private var _note: URL?
    private var _failed = false
    private var _failure: String?
    private var _held = false
    var note: URL? { lock.withLock { _note } }
    var held: Bool { lock.withLock { _held } }
    var failure: String? { lock.withLock { _failure } }

    func record(_ event: JobQueue.Event) {
        lock.withLock {
            switch event {
            case .jobDone(_, let noteURL): _note = noteURL
            case .jobFailed(let job, let transient):
                if !transient { _failed = true; _failure = job.lastError }
            case .heldForNames: _held = true
            default: break
            }
        }
    }

    func waitForNote() async throws -> URL {
        for _ in 0..<400 {
            if let note = lock.withLock({ _note }) { return note }
            if lock.withLock({ _failed }) {
                throw TestFailure.jobFailed(lock.withLock { _failure } ?? "?")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TestFailure.timedOut
    }

    func waitForHold() async throws {
        for _ in 0..<400 {
            if lock.withLock({ _held }) { return }
            if lock.withLock({ _failed }) {
                throw TestFailure.jobFailed(lock.withLock { _failure } ?? "?")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TestFailure.timedOut
    }

    func waitForFailure() async throws {
        for _ in 0..<400 {
            if lock.withLock({ _failed }) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TestFailure.timedOut
    }
}

enum TestFailure: Error { case timedOut, jobFailed(String) }

func tempRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("local-test-\(UUID().uuidString)")
}

/// A pipeline wired entirely to doubles, with a throwaway encryption key so
/// tests exercise real encryption without touching the developer's Keychain.
func makeLocalEnvironment(
    root: URL,
    delivery: Delivery = .immediate,
    box: SecretBox = .ephemeral(),
    voices: VoiceStore? = nil,
    engine: (any TranscriberEngine)? = nil,
    diarizer: (any SpeakerDiarizing)? = nil,
    summariser: any NoteSummarising = StubSummary(),
    onEvent: @escaping @Sendable (JobQueue.Event) -> Void
) throws -> JobQueue.Environment {
    let defaults = UserDefaults(suiteName: "no.braid.test.\(UUID().uuidString)")!
    let settings = SettingsStore(defaults: defaults)
    settings.vaultPath = root.appendingPathComponent("vault").path
    settings.delivery = delivery

    let transcriber = Transcriber(
        engine: engine ?? StubEngine(words: [
            TimedWord(text: "their", start: 0.2, end: 0.6),
            TimedWord(text: "line", start: 0.6, end: 1.0),
        ]),
        diarizer: diarizer ?? StubDiarizer(
            spans: [SpeakerSpan(speakerId: "S0", start: 0, end: 3)],
            voices: [SpeakerVoice(speakerId: "S0", centroid: unitVector(seed: 5), seconds: 40)]))

    return JobQueue.Environment(
        transcriber: transcriber,
        summariser: summariser,
        settings: settings,
        voices: voices ?? VoiceStore(url: root.appendingPathComponent("voices.dat"), box: box),
        clips: VoiceClipStore(root: root.appendingPathComponent("clips")),
        jobsRoot: root.appendingPathComponent("jobs"),
        transcripts: TranscriptStore(root: root.appendingPathComponent("transcripts"), box: box),
        sessions: SessionIndex(url: root.appendingPathComponent("sessions.json")),
        onEvent: onEvent)
}

/// A Session with real CAF Tracks on disk, so the Job reaches the Engine.
func seedSession(root: URL, duration: TimeInterval = 60) throws -> Session {
    let session = Session(title: "Local test", presetName: "Meeting", participants: [],
                          startedAt: Date(), recordedDuration: duration)
    let dir = root.appendingPathComponent("jobs").appendingPathComponent(session.id)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try writeShortCAF(at: dir.appendingPathComponent("mic.caf"))
    try writeShortCAF(at: dir.appendingPathComponent("remote.caf"))
    return session
}

func writeShortCAF(at url: URL, seconds: Double = 0.25) throws {
    let rate = 16_000.0
    let writer = try TrackWriter(url: url, deviceRate: rate)
    var samples = [Float](repeating: 0, count: Int(rate * seconds))
    for i in samples.indices { samples[i] = Float(sin(Double(i) / 8) * 0.4) }
    samples.withUnsafeMutableBufferPointer { buffer in
        writer.writeAsync(buffer.baseAddress!, frames: buffer.count)
    }
    writer.close()
}

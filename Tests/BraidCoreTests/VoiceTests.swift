import Testing
import Foundation
@testable import BraidCore

// MARK: - Matching (R23)
//
// Precision first: R23 makes a wrong auto-name a hard failure rather than a
// tuning matter, so these assert the decision boundary exactly rather than
// trusting a threshold to behave.

private func database(_ people: [(String, [Float])], me: [Float]? = nil,
                      model: String = LocalDiarizer.embeddingModelVersion) -> VoiceDatabase {
    VoiceDatabase(
        embeddingModelVersion: model,
        persons: people.map { name, vector in
            Person(name: name, voiceprints: [Voiceprint(vector: vector, seconds: 60)])
        },
        me: me.map { Person(name: "Me", voiceprints: [Voiceprint(vector: $0, seconds: 60)]) })
}

@Test func aVoiceThatMatchesOnePersonWellIsNamedWithoutAsking() {
    let sarah = unitVector(seed: 3)
    let identifier = VoiceIdentifier()
    let match = identifier.match(
        SpeakerVoice(speakerId: "S0", centroid: sarah, seconds: 60),
        in: database([("Sarah", sarah)]))

    #expect(match.isConfident)
    #expect(match.name == "Sarah")
}

/// Between the two thresholds Braid offers a chip and waits. A suggestion is
/// one tap; a wrong name is a filed note that misquotes somebody.
@Test func aNearMissSuggestsRatherThanNames() {
    let config = IdentificationConfig()
    let sarah = unitVector(seed: 3)
    // Blend towards another direction until the score lands between the bars.
    let drifted = blend(sarah, unitVector(seed: 8),
                        towards: (config.autoThreshold + config.suggestThreshold) / 2)
    let identifier = VoiceIdentifier()
    let match = identifier.match(
        SpeakerVoice(speakerId: "S0", centroid: drifted, seconds: 60),
        in: database([("Sarah", sarah)]))

    guard case .suggestion(_, let name, let score) = match else {
        Issue.record("expected a suggestion, got \(match)")
        return
    }
    #expect(name == "Sarah")
    #expect(score < config.autoThreshold)
    #expect(score >= config.suggestThreshold)
}

/// R23, literally: "exactly one Person clears the auto threshold". Two people
/// who both sound like this voice is the situation where guessing produces a
/// confidently wrong name.
@Test func aTieBetweenTwoPeopleNeverAutoNames() {
    let voice = unitVector(seed: 3)
    let identifier = VoiceIdentifier()
    let match = identifier.match(
        SpeakerVoice(speakerId: "S0", centroid: voice, seconds: 60),
        in: database([("Sarah", voice), ("Sara", voice)]))

    #expect(!match.isConfident, "two plausible people is not evidence")
    #expect(match.name != nil, "but it is still worth offering as a chip")
}

@Test func anUnknownVoiceStaysUnknown() {
    let identifier = VoiceIdentifier()
    let match = identifier.match(
        SpeakerVoice(speakerId: "S0", centroid: unitVector(seed: 42), seconds: 60),
        in: database([("Sarah", unitVector(seed: 3))]))

    #expect(match == .unknown)
}

/// R30: vectors made by a different embedding model are not comparable, so
/// everything reads as unknown until people are named again.
@Test func aForgedModelVersionDisablesMatchingUntilReenrollment() async throws {
    let sarah = unitVector(seed: 3)
    let stale = database([("Sarah", sarah)], model: "some-older-model/v0")
    let identifier = VoiceIdentifier()

    #expect(stale.isStale(against: LocalDiarizer.embeddingModelVersion))
    #expect(identifier.match(SpeakerVoice(speakerId: "S0", centroid: sarah, seconds: 60),
                            in: stale) == .unknown)
    #expect(identifier.isEcho(SpeakerVoice(speakerId: "S0", centroid: sarah, seconds: 60),
                              in: database([], me: sarah, model: "some-older-model/v0")) == false)

    // Naming someone again migrates the store: the people stay, their stale
    // exemplars go, and matching works from there.
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let box = SecretBox.ephemeral()
    let store = VoiceStore(url: root.appendingPathComponent("v.dat"), box: box,
                           modelVersion: "new-model/v1")
    await store.enroll(SpeakerVoice(speakerId: "S0", centroid: sarah, seconds: 60), as: "Sarah")
    let migrated = await store.database()
    #expect(migrated.embeddingModelVersion == "new-model/v1")
    #expect(migrated.persons.count == 1)
    #expect(migrated.persons[0].voiceprints.count == 1)
}

/// R28: Me exists to catch echo and for nothing else.
@Test func meIsNeverASuggestion() {
    let mine = unitVector(seed: 11)
    let identifier = VoiceIdentifier()
    let voice = SpeakerVoice(speakerId: "S0", centroid: mine, seconds: 60)
    let db = database([], me: mine)

    #expect(identifier.isEcho(voice, in: db))
    #expect(identifier.match(voice, in: db) == .unknown,
            "the owner's own voiceprint may never name a Remote speaker")
}

// MARK: - Enrollment (R24)

private func freshStore(_ root: URL, config: IdentificationConfig = .current) -> VoiceStore {
    VoiceStore(url: root.appendingPathComponent("voices.dat"), box: .ephemeral(), config: config)
}

@Test func namingEnrollsAVoiceprint() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = freshStore(root)

    await store.enroll(SpeakerVoice(speakerId: "S0", centroid: unitVector(seed: 3), seconds: 60),
                       as: "Sarah")
    let db = await store.database()
    #expect(db.persons.count == 1)
    #expect(db.persons[0].name == "Sarah")
    #expect(db.persons[0].voiceprints.count == 1)

    // Naming the same person again adds an exemplar rather than a second person.
    await store.enroll(SpeakerVoice(speakerId: "S1", centroid: unitVector(seed: 4), seconds: 60),
                       as: "sarah")
    let again = await store.database()
    #expect(again.persons.count == 1)
    #expect(again.persons[0].voiceprints.count == 2)
}

/// A voice with barely any speech behind it teaches nothing reliable, so the
/// name applies to the Transcript but the database learns nothing.
@Test func aVoiceWithTooLittleSpeechIsNotEnrolled() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = freshStore(root)

    await store.enroll(SpeakerVoice(speakerId: "S0", centroid: unitVector(seed: 3), seconds: 2),
                       as: "Passing Voice")
    let db = await store.database()
    #expect(db.persons.count == 1, "the person exists, so their name can be suggested")
    #expect(db.persons[0].voiceprints.isEmpty, "but nothing was learned from two seconds")
}

@Test func theCapEvictsTheOldestVoiceprint() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = freshStore(root, config: IdentificationConfig(voiceprintCap: 3))

    for seed in 1...5 {
        await store.enroll(
            SpeakerVoice(speakerId: "S\(seed)", centroid: unitVector(seed: seed), seconds: 60),
            as: "Sarah")
    }
    let db = await store.database()
    #expect(db.persons[0].voiceprints.count == 3)
    // The three that survived are the three most recent.
    let survivors = db.persons[0].voiceprints.map { Vector.cosine($0.vector, unitVector(seed: 1)) }
    #expect(!survivors.contains { $0 > 0.999 }, "the first exemplar was evicted")
}

@Test func correctingAWrongNameRemovesTheOffendingVoiceprint() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = freshStore(root)

    let wrong = unitVector(seed: 3)
    await store.enroll(SpeakerVoice(speakerId: "S0", centroid: wrong, seconds: 60), as: "Sarah")
    await store.enroll(SpeakerVoice(speakerId: "S1", centroid: unitVector(seed: 20), seconds: 60),
                       as: "Sarah")
    var db = await store.database()
    let sarah = try #require(db.person(named: "Sarah"))
    #expect(sarah.voiceprints.count == 2)

    await store.removeVoiceprint(from: sarah.id,
                                 nearest: SpeakerVoice(speakerId: "S0", centroid: wrong,
                                                       seconds: 60))
    db = await store.database()
    let after = try #require(db.person(named: "Sarah"))
    #expect(after.voiceprints.count == 1)
    #expect(Vector.cosine(after.voiceprints[0].vector, wrong) < 0.99,
            "the exemplar that produced the wrong match is the one that went")
}

// MARK: - The user's controls (R29)

@Test func forgettingAPersonRemovesAllTheirVoiceprints() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = freshStore(root)

    await store.enroll(SpeakerVoice(speakerId: "S0", centroid: unitVector(seed: 3), seconds: 60),
                       as: "Sarah")
    await store.enroll(SpeakerVoice(speakerId: "S1", centroid: unitVector(seed: 9), seconds: 60),
                       as: "Tom")
    var db = await store.database()
    let sarah = try #require(db.person(named: "Sarah"))

    await store.forget(personID: sarah.id)
    db = await store.database()
    #expect(db.persons.count == 1)
    #expect(db.person(named: "Sarah") == nil)
    #expect(db.person(named: "Tom") != nil)
    // And nothing of her remains to match against.
    let identifier = VoiceIdentifier()
    #expect(identifier.match(SpeakerVoice(speakerId: "X", centroid: unitVector(seed: 3),
                                          seconds: 60), in: db) == .unknown)
}

@Test func exportThenImportRoundTrips() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = freshStore(root)
    await store.enroll(SpeakerVoice(speakerId: "S0", centroid: unitVector(seed: 3), seconds: 60),
                       as: "Sarah")

    let exported = root.appendingPathComponent("out.json")
    try await store.export(to: exported)
    // R29: an export is the deliberate readable egress, so it is plain.
    let text = try String(contentsOf: exported, encoding: .utf8)
    #expect(text.contains("Sarah"))

    let other = VoiceStore(url: root.appendingPathComponent("other.dat"), box: .ephemeral())
    try await other.importDatabase(from: exported)
    let db = await other.database()
    #expect(db.person(named: "Sarah") != nil)
    #expect(db.persons[0].voiceprints.count == 1)
}

/// R29: an export from a different embedding model is refused rather than
/// mixed in, because incomparable vectors are exactly how a wrong name happens.
@Test func importingADatabaseFromAnotherModelIsRefused() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let foreign = root.appendingPathComponent("foreign.json")
    let db = database([("Sarah", unitVector(seed: 3))], model: "another-model/v9")
    try JSONEncoder().encode(db).write(to: foreign)

    let store = freshStore(root)
    await #expect(throws: (any Error).self) {
        try await store.importDatabase(from: foreign)
    }
}

/// R21: the database on disk is unreadable without this Mac's key.
@Test func theVoiceDatabaseIsNotPlaintextOnDisk() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("voices.dat")
    let box = SecretBox.ephemeral()
    let store = VoiceStore(url: url, box: box)
    await store.enroll(SpeakerVoice(speakerId: "S0", centroid: unitVector(seed: 3), seconds: 60),
                       as: "Sarah")

    let raw = try Data(contentsOf: url)
    #expect(!raw.isEmpty)
    #expect(String(data: raw, encoding: .utf8)?.contains("Sarah") != true)

    // The right key reads it back; a different one cannot.
    let reopened = VoiceStore(url: url, box: box)
    #expect(await reopened.database().person(named: "Sarah") != nil)
    let stranger = VoiceStore(url: url, box: .ephemeral())
    #expect(await stranger.database().persons.isEmpty)
}

// MARK: - Re-attribution (R27)

@Test func reattributionMovesAContaminatedTurnToThePersonItSoundsLike() {
    let sarah = unitVector(seed: 3)
    let tom = unitVector(seed: 30)
    let db = database([("Sarah", sarah), ("Tom", tom)])
    let identifier = VoiceIdentifier()

    // The diarizer put everything in one cluster owned by Tom, but the middle
    // chunk is unmistakably Sarah.
    let spans = [
        SpeakerSpan(speakerId: "S0", start: 0, end: 10),
        SpeakerSpan(speakerId: "S0", start: 10, end: 20),
        SpeakerSpan(speakerId: "S0", start: 20, end: 30),
    ]
    let result = identifier.reattribute(
        spans: spans,
        chunks: [VoiceChunk(speakerId: "S0", start: 10, end: 20, embedding: sarah)],
        voices: [SpeakerVoice(speakerId: "S0", centroid: tom, seconds: 30)],
        resolved: ["S0": db.person(named: "Tom")!.id],
        in: db)

    #expect(result.corrections == 1)
    #expect(result.spans[0].speakerId == "S0")
    #expect(result.spans[1].speakerId != "S0", "the contaminated turn changed hands")
    #expect(result.spans[2].speakerId == "S0")
}

/// R27: never below the auto threshold. A merely plausible chunk is not
/// evidence enough to overrule the clustering.
@Test func reattributionNeverFiresBelowTheAutoThreshold() {
    let config = IdentificationConfig()
    let sarah = unitVector(seed: 3)
    let tom = unitVector(seed: 30)
    let db = database([("Sarah", sarah), ("Tom", tom)])
    let identifier = VoiceIdentifier()
    // Close enough to suggest, not close enough to move anything.
    let vague = blend(sarah, unitVector(seed: 44),
                      towards: (config.autoThreshold + config.suggestThreshold) / 2)

    let spans = [SpeakerSpan(speakerId: "S0", start: 0, end: 10)]
    let result = identifier.reattribute(
        spans: spans,
        chunks: [VoiceChunk(speakerId: "S0", start: 0, end: 10, embedding: vague)],
        voices: [SpeakerVoice(speakerId: "S0", centroid: tom, seconds: 30)],
        resolved: ["S0": db.person(named: "Tom")!.id],
        in: db)

    #expect(result.corrections == 0)
    #expect(result.spans == spans)
}

/// Nothing to compare against means nothing to correct — an empty database
/// leaves the diarizer's own answer alone.
@Test func reattributionIsANoOpWithoutKnownVoices() {
    let identifier = VoiceIdentifier()
    let spans = [SpeakerSpan(speakerId: "S0", start: 0, end: 10)]
    let result = identifier.reattribute(
        spans: spans,
        chunks: [VoiceChunk(speakerId: "S0", start: 0, end: 10, embedding: unitVector(seed: 3))],
        voices: [SpeakerVoice(speakerId: "S0", centroid: unitVector(seed: 3), seconds: 30)],
        resolved: [:],
        in: VoiceDatabase(embeddingModelVersion: LocalDiarizer.embeddingModelVersion))

    #expect(result.corrections == 0)
    #expect(result.spans == spans)
}

// MARK: - Voice Clips (R25)

@Test func clipsComeFromTheSpeakersLongestOverlapFreeTurn() {
    let store = VoiceClipStore(root: FileManager.default.temporaryDirectory)
    let spans = [
        SpeakerSpan(speakerId: "S0", start: 0, end: 3),      // short
        SpeakerSpan(speakerId: "S0", start: 10, end: 30),    // longest, but overlapped
        SpeakerSpan(speakerId: "S1", start: 12, end: 14),    // the overlap
        SpeakerSpan(speakerId: "S0", start: 40, end: 50),    // longest clean turn
    ]
    let best = store.bestTurn(for: "S0", in: spans)
    #expect(best?.start == 40)
    #expect(best?.end == 50)
}

/// A voice with nothing but one-word interjections has no clip worth playing.
@Test func aSpeakerWithOnlyFragmentsGetsNoClip() {
    let store = VoiceClipStore(root: FileManager.default.temporaryDirectory)
    let spans = [
        SpeakerSpan(speakerId: "S0", start: 0, end: 0.4),
        SpeakerSpan(speakerId: "S0", start: 5, end: 5.6),
    ]
    #expect(store.bestTurn(for: "S0", in: spans) == nil)
}

// MARK: - Vector maths

@Test func cosineIsOneForTheSameDirectionAndSafeForNonsense() {
    let v = unitVector(seed: 3)
    #expect(abs(Vector.cosine(v, v) - 1) < 0.0001)
    // A malformed embedding must read as "no evidence", never as a match.
    #expect(Vector.cosine(v, []) == 0)
    #expect(Vector.cosine([], []) == 0)
    #expect(Vector.cosine(v, [0.1, 0.2]) == 0)
    #expect(Vector.normalised([0, 0, 0]) == [0, 0, 0])
}

/// Mixes two directions until the result sits at roughly `towards` similarity
/// with the first. Used to build a voice that lands between the thresholds.
private func blend(_ a: [Float], _ b: [Float], towards target: Double) -> [Float] {
    var low: Float = 0, high: Float = 1
    var best = a
    for _ in 0..<40 {
        let mid = (low + high) / 2
        let mixed = Vector.normalised(zip(a, b).map { $0 * (1 - mid) + $1 * mid })
        let score = Vector.cosine(a, mixed)
        best = mixed
        if score > target { low = mid } else { high = mid }
    }
    return best
}

// MARK: - Reading a model's reply (ADR-0006)
//
// Apple's summariser is constrained by a generation schema; an open-weights one
// is only asked nicely, and every case here is something a 4B model actually
// did on real transcripts rather than something imagined.

@Test func aCleanJSONReplyBecomesANote() {
    let note = ModelReply.note(from: """
        {"summary": "They agreed the report needs branding.",
         "sections": [{"heading": "Key points", "bullets": ["Add the logo.", "Export to PDF."]},
                      {"heading": "Decisions", "bullets": ["Ship Thursday."]}]}
        """)
    #expect(note.hasPrefix("They agreed the report needs branding."))
    #expect(note.contains("## Key points\n- Add the logo.\n- Export to PDF."))
    #expect(note.contains("## Decisions\n- Ship Thursday."))
}

/// A reasoning model puts its scratchpad first, and small models fence their
/// JSON or open with a bold title echoing the prompt.
@Test func theWrappingAroundAReplyIsStripped() {
    let note = ModelReply.note(from: """
        <think>
        The user wants a summary. Let me identify the key points.
        </think>

        ```json
        {"summary": "A short call.", "sections": []}
        ```
        """)
    #expect(note == "A short call.")
    #expect(!note.contains("<think>"))
    #expect(!note.contains("```"))

    #expect(ModelReply.clean("**Podcast Test:**\n\nThe real summary.") == "The real summary.")
    #expect(ModelReply.clean("# Podcast Test\n\nThe real summary.") == "The real summary.")
    // A bold *sentence* is content, not a title, and must survive.
    #expect(ModelReply.clean("**They agreed. It ships Thursday.**").contains("They agreed"))
}

/// The failure that actually happened: a `bullets` array closed with `}`
/// instead of `]`, so strict decoding fails. Everything is still there, and a
/// Note full of raw JSON would be the worst possible outcome.
@Test func malformedJSONIsSalvagedRatherThanShown() {
    let note = ModelReply.note(from: """
        {"summary": "They discussed the schedule.", "sections": [\
        {"heading": "Key points", "bullets": ["Russell handles the edit.", "Ricky writes the notes."}]}
        """)
    #expect(note.hasPrefix("They discussed the schedule."))
    #expect(note.contains("## Key points"))
    #expect(note.contains("- Russell handles the edit."))
    #expect(note.contains("- Ricky writes the notes."))
    #expect(!note.contains("\"summary\""), "raw JSON must never reach a Note")
    #expect(!note.contains("{"))
}

/// A model that ignores the contract entirely still wrote usable prose.
@Test func prosePassesThroughUnchanged() {
    let note = ModelReply.note(from: "The team agreed to ship on Thursday.")
    #expect(note == "The team agreed to ship on Thursday.")
}

/// JSON that decodes but carries nothing keeps the summary rather than
/// producing an empty Note.
@Test func anEmptySectionListStillYieldsTheSummary() {
    let note = ModelReply.note(from: """
        {"summary": "Nothing was decided.", "sections": [{"heading": "Decisions", "bullets": []}]}
        """)
    #expect(note == "Nothing was decided.")
}

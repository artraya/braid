import Foundation

/// One stored exemplar of a Person's voice (CONTEXT.md: Voiceprint).
///
/// A Voiceprint is not raw diarizer output. It is the centroid of one Speaker
/// the user personally named, kept because they said who it was — which is the
/// whole basis on which ADR-0007 permits storing voice data at all.
public struct Voiceprint: Sendable, Codable, Equatable {
    /// L2-normalised speaker embedding.
    public var vector: [Float]
    public var heardAt: Date
    /// How much speech this exemplar was distilled from. More speech, more
    /// trustworthy — used to prefer the better exemplar when the cap evicts.
    public var seconds: TimeInterval

    public init(vector: [Float], heardAt: Date = Date(), seconds: TimeInterval) {
        self.vector = Vector.normalised(vector)
        self.heardAt = heardAt
        self.seconds = seconds
    }
}

/// A durable, named voice identity (CONTEXT.md: Person).
public struct Person: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var voiceprints: [Voiceprint]
    public var createdAt: Date
    public var lastHeardAt: Date?

    public init(id: String = UUID().uuidString, name: String,
                voiceprints: [Voiceprint] = [], createdAt: Date = Date(),
                lastHeardAt: Date? = nil) {
        self.id = id
        self.name = name
        self.voiceprints = voiceprints
        self.createdAt = createdAt
        self.lastHeardAt = lastHeardAt
    }
}

/// The Voice Database (CONTEXT.md), as it exists in memory.
///
/// `me` is deliberately a field of its own rather than a Person in the list.
/// R28 says the owner's Voiceprint exists only to catch echo and is never
/// offered as a suggestion for anyone else; keeping it out of `persons`
/// structurally guarantees that instead of relying on a filter someone could
/// later forget.
public struct VoiceDatabase: Sendable, Codable, Equatable {
    public static let currentSchema = 1

    public var schemaVersion: Int
    /// Which embedding model produced every vector in here (R30). Voiceprints
    /// from one model mean nothing to another, so a mismatch disables matching
    /// rather than risking a wrong name.
    public var embeddingModelVersion: String
    public var persons: [Person]
    public var me: Person?

    public init(embeddingModelVersion: String, persons: [Person] = [], me: Person? = nil) {
        self.schemaVersion = Self.currentSchema
        self.embeddingModelVersion = embeddingModelVersion
        self.persons = persons
        self.me = me
    }

    /// R30: vectors made by a different model are not comparable to today's.
    public func isStale(against model: String) -> Bool {
        embeddingModelVersion != model
    }

    public func person(id: String) -> Person? {
        persons.first { $0.id == id }
    }

    /// Case-insensitive, because "sarah" and "Sarah" are one colleague.
    public func person(named name: String) -> Person? {
        let wanted = name.trimmingCharacters(in: .whitespaces)
        return persons.first { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
    }
}

/// One Speaker's voice as the diarizer heard it: the candidate a Voiceprint is
/// made from if the user names it, and the thing matching compares against.
///
/// Lives for one Job, plus — for a Speaker still awaiting a name — as long as
/// its Voice Clip does (R21). Naming promotes it; skipping deletes it.
public struct SpeakerVoice: Sendable, Codable, Equatable {
    public var speakerId: String
    /// L2-normalised centroid of everything this Speaker said.
    public var centroid: [Float]
    /// Total speech behind the centroid.
    public var seconds: TimeInterval

    public init(speakerId: String, centroid: [Float], seconds: TimeInterval) {
        self.speakerId = speakerId
        self.centroid = Vector.normalised(centroid)
        self.seconds = seconds
    }

    public var asVoiceprint: Voiceprint {
        Voiceprint(vector: centroid, seconds: seconds)
    }
}

/// One segmentation chunk's embedding with the cluster the diarizer put it in.
///
/// Strictly in-Job (R21): this is the raw per-chunk data Re-attribution reads
/// to catch a contaminated cluster, and it is never persisted anywhere.
public struct VoiceChunk: Sendable, Equatable {
    public var speakerId: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var embedding: [Float]

    public init(speakerId: String, start: TimeInterval, end: TimeInterval,
                embedding: [Float]) {
        self.speakerId = speakerId
        self.start = start
        self.end = end
        self.embedding = Vector.normalised(embedding)
    }

    var midpoint: TimeInterval { start + (end - start) / 2 }
}

/// Everything the diarizer knows about one Track.
public struct DiarizationOutput: Sendable {
    /// Who spoke when — the only part that reaches the aligner.
    public var spans: [SpeakerSpan]
    /// One entry per distinct voice heard.
    public var voices: [SpeakerVoice]
    /// Per-chunk detail for Re-attribution. Empty when the pipeline was not
    /// asked for it, which is the normal case outside a Job.
    public var chunks: [VoiceChunk]

    public init(spans: [SpeakerSpan], voices: [SpeakerVoice] = [],
                chunks: [VoiceChunk] = []) {
        self.spans = spans
        self.voices = voices
        self.chunks = chunks
    }
}

/// The numbers Identification turns on, in one place so calibration is a single
/// edit and the measurement harness can report against them (R23).
///
/// Starting values, not measured ones: speaker-embedding cosine similarity runs
/// roughly 0.7–0.9 within a speaker and 0.1–0.4 across speakers, so 0.72 to
/// auto-name is deliberately toward the cautious end of the overlap. R23 makes
/// a wrong auto-name a hard failure, so when these move they move up first.
public struct IdentificationConfig: Sendable, Codable, Equatable {
    /// At or above this, one matching Person is named without asking.
    public var autoThreshold: Double
    /// At or above this, the naming flow offers the Person as a chip.
    public var suggestThreshold: Double
    /// How much better a rival Person must score than a Speaker's own cluster
    /// before Re-attribution moves a chunk that has no identified owner (R27).
    public var reattributionMargin: Double
    /// Voiceprints kept per Person; the oldest is evicted (R24).
    public var voiceprintCap: Int
    /// Speech a Speaker must have for its centroid to be worth enrolling. Below
    /// this a name still applies to the Transcript, it just teaches nothing.
    public var minSecondsToEnroll: TimeInterval

    public init(autoThreshold: Double = 0.72, suggestThreshold: Double = 0.55,
                reattributionMargin: Double = 0.10, voiceprintCap: Int = 10,
                minSecondsToEnroll: TimeInterval = 8) {
        self.autoThreshold = autoThreshold
        self.suggestThreshold = suggestThreshold
        self.reattributionMargin = reattributionMargin
        self.voiceprintCap = voiceprintCap
        self.minSecondsToEnroll = minSecondsToEnroll
    }

    public static let current = IdentificationConfig()
}

/// Vector arithmetic for embeddings. Small enough (256 floats, dozens of
/// Persons) that clarity beats Accelerate here.
public enum Vector {
    /// Unit length, so a dot product is a cosine. Returns the input unchanged
    /// when it has no length to normalise by.
    public static func normalised(_ v: [Float]) -> [Float] {
        var sum: Float = 0
        for x in v { sum += x * x }
        let norm = sum.squareRoot()
        guard norm > 1e-9, norm.isFinite else { return v }
        return v.map { $0 / norm }
    }

    /// Cosine similarity of two already-normalised vectors. Mismatched or empty
    /// vectors score 0 rather than trapping: a malformed embedding must read as
    /// "no evidence", never as a match.
    public static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        var dot: Float = 0
        for i in a.indices { dot += a[i] * b[i] }
        return dot.isFinite ? Double(dot) : 0
    }

    /// The mean of several embeddings, renormalised — a Speaker's centroid.
    public static func centroid(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        var sum = [Float](repeating: 0, count: first.count)
        var used = 0
        for v in vectors where v.count == first.count {
            for i in v.indices { sum[i] += v[i] }
            used += 1
        }
        guard used > 0 else { return [] }
        return normalised(sum.map { $0 / Float(used) })
    }
}

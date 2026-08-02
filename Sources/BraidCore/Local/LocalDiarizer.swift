import Foundation
import FluidAudio

/// Anything that can tell voices apart in one Track.
///
/// A seam for the same reason the Engine protocol is one: the alignment and
/// identification logic that decides who said what is worth testing exactly,
/// and it cannot be if the only way to get speaker turns is to load several
/// hundred MB of CoreML.
public protocol SpeakerDiarizing: Sendable {
    func prepare(progress: (@Sendable (Double) -> Void)?) async throws
    /// `wantsVoiceData` asks for the per-voice centroids and per-chunk
    /// embeddings Identification and Re-attribution need. Off for the plain
    /// diagnostic path, which only wants to know who spoke when.
    func diarize(file: URL, expected: Session.SpeakerExpectation?,
                 wantsVoiceData: Bool) async throws -> DiarizationOutput
}

extension SpeakerDiarizing {
    public func diarize(file: URL,
                        expected: Session.SpeakerExpectation?) async throws -> DiarizationOutput {
        try await diarize(file: file, expected: expected, wantsVoiceData: false)
    }
}

/// Offline speaker diarization: pyannote community-1 with VBx clustering,
/// via FluidAudio, on the Neural Engine.
///
/// The batch pipeline rather than either streaming one. Braid diarizes after
/// Stop, so the accurate-but-slower path is simply free — the streaming models
/// trade a lot of accuracy (31–56% DER against 10.6%) for latency this app
/// never needs.
///
/// **The ADR-0007 boundary.** This is where voice data enters Braid, and the
/// rule is no longer "none of it survives" but "only what the user vouches
/// for". `DiarizationOutput` carries per-voice centroids and per-chunk
/// embeddings because Identification and Re-attribution genuinely need them,
/// and both die with the Job unless the user puts a name to one — at which
/// point that one centroid becomes a Voiceprint (R21, R24). Nothing else is
/// kept, and FluidAudio's own speaker-database and enrollment APIs stay unused:
/// Braid's database is Braid's, encrypted, with its own rules.
///
/// The manager is built per call rather than cached. `OfflineDiarizerManager`
/// is a non-Sendable class, so holding one on an actor and awaiting its work
/// would mean sending it across isolation domains; building and consuming it in
/// one nonisolated scope keeps it in a single domain. The cost is a model load
/// (not a download — those are cached on disk) once per Job, which for a batch
/// pipeline is seconds, and the benefit is that several hundred MB of CoreML
/// model is released the moment a Job finishes instead of being held for the
/// life of the app. On an 8GB machine that is the better trade.
public struct LocalDiarizer: SpeakerDiarizing {
    /// Stamped into the Voice Database so vectors are never compared across
    /// models (R30). Bump this whenever the embedding model changes; every
    /// stored Voiceprint then goes stale and people are re-learned by being
    /// named once more.
    public static let embeddingModelVersion = "pyannote-community-1/emb256"

    /// Shortest stretch of speech that gets its own embedding, and so the
    /// shortest turn that can be attributed to anyone. FluidAudio's default is
    /// 1.0s.
    let minTurnSeconds: Double
    /// Segmentation window overlap. Finer stepping resolves turn boundaries
    /// more precisely and costs proportionally more time.
    let stepRatio: Double
    /// FluidAudio's post-pass for spans no window voted on, which it documents
    /// as otherwise "silently absorbing whole speaker turns into the
    /// surrounding speaker's segment" — the exact failure measured on real call
    /// audio (48 turns, 17 speaker changes where the reference alternates ~40).
    /// Off by default because that is the configuration every number in
    /// ADR-0005 was measured under; it is a parameter so the harness can settle
    /// whether it helps rather than the question being settled by assumption.
    let zeroVoteReembed: Bool

    /// Defaults left where they were measured.
    ///
    /// The obvious suspicion on real call audio was that short backchannels
    /// ("yeah", "sure") fall under the 1.0s floor, get no embedding, and are
    /// absorbed into whoever was talking around them — which in a meeting
    /// means an agreement attributed to the wrong person. Dropping the floor
    /// to 0.4s and halving the step on `fixture-remote.flac` produced 62
    /// diarizer turns instead of 48 but only 18 speaker changes instead of 17,
    /// left turn purity identical at 61.4%, and cost 20% more time. The extra
    /// turns were the same speaker split finer, not the missing alternations.
    /// The coarse turn resolution is the model's, not this configuration's, so
    /// paying for the finer settings buys nothing. Exposed as parameters so
    /// the next fixture can re-test the question cheaply.
    public init(minTurnSeconds: Double = 1.0, stepRatio: Double = 0.2,
                zeroVoteReembed: Bool = false) {
        self.minTurnSeconds = minTurnSeconds
        self.stepRatio = stepRatio
        self.zeroVoteReembed = zeroVoteReembed
    }

    /// Loads the models once so the first real Session does not stall on a
    /// download. Discards the manager afterwards; the on-disk cache is what
    /// makes this worthwhile.
    public func prepare(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        _ = try await Self.prepared(config: tunedConfig(wantsVoiceData: false))
        progress?(1)
    }

    func tunedConfig(wantsVoiceData: Bool) -> OfflineDiarizerConfig {
        var config = OfflineDiarizerConfig()
        config.embedding.minSegmentDurationSeconds = minTurnSeconds
        config.segmentation.stepRatio = stepRatio
        config.zeroVoteReembed.enabled = zeroVoteReembed
        config.exposeChunkEmbeddings = wantsVoiceData
        return config
    }

    /// Speaker turns in one Track, with the voice data Identification needs.
    ///
    /// `expected` is honoured only because the *user asserted it at Start*
    /// (amended R6): a count becomes a minimum, and only `strict` also caps it.
    /// Nothing is ever derived from Participants, so a late joiner can still get
    /// their own voice.
    public func diarize(file: URL, expected: Session.SpeakerExpectation?,
                        wantsVoiceData: Bool) async throws -> DiarizationOutput {
        var config = tunedConfig(wantsVoiceData: wantsVoiceData)
        if let expected {
            config.clustering.minSpeakers = max(1, expected.count)
            if expected.strict { config.clustering.maxSpeakers = max(1, expected.count) }
        }
        let manager = try await Self.prepared(config: config)
        let result: DiarizationResult
        do {
            result = try await manager.process(file)
        } catch {
            throw LocalEngineError.diarizationFailed("\(error)")
        }

        let spans = result.segments
            .map { SpeakerSpan(speakerId: $0.speakerId,
                               start: TimeInterval($0.startTimeSeconds),
                               end: TimeInterval($0.endTimeSeconds)) }
            .filter { $0.duration > 0 }
            .sorted { $0.start < $1.start }

        guard wantsVoiceData else { return DiarizationOutput(spans: spans) }

        let chunks = (result.chunkEmbeddings ?? []).map {
            VoiceChunk(speakerId: $0.speakerId,
                       start: $0.startTimeSeconds, end: $0.endTimeSeconds,
                       embedding: $0.embedding256)
        }
        return DiarizationOutput(spans: spans,
                                 voices: Self.voices(spans: spans, chunks: chunks,
                                                     database: result.speakerDatabase),
                                 chunks: chunks)
    }

    /// One centroid per voice, plus how much speech backs it.
    ///
    /// FluidAudio publishes its own per-cluster centroids, which are what the
    /// clustering actually converged on; they are preferred when present, and
    /// the per-chunk mean is the fallback. Talk time always comes from the
    /// spans, since that is what decides whether a voice is worth enrolling.
    static func voices(spans: [SpeakerSpan], chunks: [VoiceChunk],
                       database: [String: [Float]]?) -> [SpeakerVoice] {
        var seconds: [String: TimeInterval] = [:]
        for span in spans { seconds[span.speakerId, default: 0] += span.duration }

        var grouped: [String: [[Float]]] = [:]
        for chunk in chunks where !chunk.embedding.isEmpty {
            grouped[chunk.speakerId, default: []].append(chunk.embedding)
        }

        let ids = Set(seconds.keys).union(grouped.keys)
        return ids.compactMap { id in
            let centroid = database?[id].map(Vector.normalised)
                ?? Vector.centroid(grouped[id] ?? [])
            guard let centroid, !centroid.isEmpty else { return nil }
            return SpeakerVoice(speakerId: id, centroid: centroid,
                                seconds: seconds[id] ?? 0)
        }
        .sorted { $0.seconds > $1.seconds }
    }

    private static func prepared(
        config: OfflineDiarizerConfig
    ) async throws -> OfflineDiarizerManager {
        let manager = OfflineDiarizerManager(config: config)
        do {
            try await manager.prepareModels()
        } catch {
            throw LocalEngineError.modelsUnavailable("diarizer: \(error)")
        }
        return manager
    }
}

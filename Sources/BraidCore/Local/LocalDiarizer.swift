import Foundation
import FluidAudio

/// Anything that can tell voices apart in one Track.
///
/// A seam for the same reason `STTProvider` is one: the alignment logic that
/// decides who said what is worth testing exactly, and it cannot be if the only
/// way to get speaker turns is to load several hundred MB of CoreML.
public protocol SpeakerDiarizing: Sendable {
    func prepare(progress: (@Sendable (Double) -> Void)?) async throws
    func diarize(file: URL,
                 expected: Session.SpeakerExpectation?) async throws -> [SpeakerSpan]
}

/// Offline speaker diarization: pyannote community-1 with VBx clustering,
/// via FluidAudio, on the Neural Engine.
///
/// The batch pipeline rather than either streaming one. Braid diarizes after
/// Stop, so the accurate-but-slower path is simply free — the streaming models
/// trade a lot of accuracy (31–56% DER against 10.6%) for latency this app
/// never needs.
///
/// **ADR-0003 boundary.** `TimedSpeakerSegment` carries the raw voice embedding
/// the clusterer worked on, and `DiarizationResult` carries a whole speaker
/// database of them. `diarize` maps to `SpeakerSpan`, which has no embedding
/// field, and returns nothing else. That is the enforcement point: voiceprints
/// exist inside one call and are unreachable after it returns. FluidAudio's
/// speaker-enrollment APIs are deliberately not used anywhere in Braid.
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
    /// Shortest stretch of speech that gets its own embedding, and so the
    /// shortest turn that can be attributed to anyone. FluidAudio's default is
    /// 1.0s.
    let minTurnSeconds: Double
    /// Segmentation window overlap. Finer stepping resolves turn boundaries
    /// more precisely and costs proportionally more time.
    let stepRatio: Double

    /// Both left at FluidAudio's defaults, having measured the alternative.
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
    public init(minTurnSeconds: Double = 1.0, stepRatio: Double = 0.2) {
        self.minTurnSeconds = minTurnSeconds
        self.stepRatio = stepRatio
    }

    /// Loads the models once so the first real Session does not stall on a
    /// download. Discards the manager afterwards; the on-disk cache is what
    /// makes this worthwhile.
    public func prepare(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        _ = try await Self.prepared(config: tunedConfig())
        progress?(1)
    }

    func tunedConfig() -> OfflineDiarizerConfig {
        var config = OfflineDiarizerConfig()
        config.embedding.minSegmentDurationSeconds = minTurnSeconds
        config.segmentation.stepRatio = stepRatio
        return config
    }

    /// Speaker turns in one Track.
    ///
    /// `expected` is honoured the same way the cloud path honours it (amended
    /// R6): a count the *user asserted at Start* becomes a minimum, and only
    /// `strict` also caps it. Nothing is ever derived from Participants, so a
    /// late joiner can still get their own voice.
    public func diarize(file: URL,
                        expected: Session.SpeakerExpectation?) async throws -> [SpeakerSpan] {
        var config = tunedConfig()
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
        return result.segments
            .map { SpeakerSpan(speakerId: $0.speakerId,
                               start: TimeInterval($0.startTimeSeconds),
                               end: TimeInterval($0.endTimeSeconds)) }
            .filter { $0.duration > 0 }
            .sorted { $0.start < $1.start }
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

import Foundation
import os

/// Everything one Track's transcription produced.
public struct TrackTranscription: Sendable {
    public var utterances: [Utterance]
    /// Speaker turns after any Re-attribution — what Voice Clips are cut from.
    public var spans: [SpeakerSpan]
    /// One per distinct voice: the candidates a name would enroll (R24).
    public var voices: [SpeakerVoice]
    /// What the Voice Database made of each voice, keyed by its label here.
    public var matches: [String: VoiceMatch]
    /// How many spans Re-attribution moved (R27), for the per-Job log.
    public var corrections: Int

    public init(utterances: [Utterance], spans: [SpeakerSpan] = [],
                voices: [SpeakerVoice] = [], matches: [String: VoiceMatch] = [:],
                corrections: Int = 0) {
        self.utterances = utterances
        self.spans = spans
        self.voices = voices
        self.matches = matches
        self.corrections = corrections
    }

    /// The voice behind one label, when there is one.
    public func voice(for speaker: String) -> SpeakerVoice? {
        voices.first { $0.speakerId == speaker }
    }
}

/// Turning a Track into attributed text. A seam, so the Job pipeline can be
/// tested end to end without loading several hundred MB of CoreML.
public protocol TrackTranscribing: Sendable {
    /// Named in the Note's `engine` frontmatter (R10).
    var name: String { get }

    /// The Mic Track. One speaker structurally (ADR-0001), so it is never split
    /// into several. `wantsVoice` asks for a centroid of the owner's own voice,
    /// which R28 uses to recognise echo — and only that.
    func transcribeMic(track: URL, keyTerms: [String],
                       wantsVoice: Bool) async throws -> TrackTranscription

    /// The Remote Track: diarized, matched against the Voice Database, and
    /// corrected by Re-attribution where the database disagrees with the
    /// clustering. `known` is nil when there is nothing to compare against.
    func transcribeRemote(track: URL, keyTerms: [String],
                          expectedSpeakers: Session.SpeakerExpectation?,
                          known: VoiceDatabase?) async throws -> TrackTranscription
}

/// Transcription, diarization and identification entirely on this Mac
/// (ADR-0005, ADR-0006).
///
/// The split-Track design does most of the work. The Mic Track is one speaker
/// structurally, so it is plain ASR. Only the Remote Track is diarized and
/// aligned, and it contains nobody the user could be confused with — which is
/// what makes automatic naming safe enough to attempt at all.
public struct Transcriber: TrackTranscribing {
    public var name: String { engine.id.engineName }

    let engine: any TranscriberEngine
    let diarizer: any SpeakerDiarizing
    let identifier: VoiceIdentifier
    let log = Logger(subsystem: "no.braid.app", category: "pipeline")

    public init(engine: any TranscriberEngine,
                diarizer: any SpeakerDiarizing = LocalDiarizer(),
                identifier: VoiceIdentifier = VoiceIdentifier()) {
        self.engine = engine
        self.diarizer = diarizer
        self.identifier = identifier
    }

    /// The configured engine plus a shared diarizer.
    public static func make(engine id: LocalEngine) -> Transcriber {
        switch id {
        case .parakeet: Transcriber(engine: ParakeetEngine())
        case .apple: Transcriber(engine: AppleSpeechEngine())
        }
    }

    /// Downloads and loads everything needed, so the first Session does not
    /// stall on a model fetch.
    public func prepare(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        try await engine.prepare(progress: progress)
        try await diarizer.prepare(progress: progress)
    }

    /// True when a Session could be processed right now without downloading.
    public var isReady: Bool {
        get async { await engine.isReady }
    }

    // MARK: - Mic Track

    public func transcribeMic(track: URL, keyTerms: [String],
                              wantsVoice: Bool) async throws -> TrackTranscription {
        try await wrapping {
            let result = try await engine.transcribe(file: track, keyTerms: keyTerms)
            log.notice("\(name, privacy: .public): mic track, \(result.words.count) words")

            let utterances: [Utterance]
            if result.words.isEmpty {
                utterances = SpeakerAligner.wholeTrack(
                    text: result.text, duration: result.duration, speaker: "Me")
            } else {
                utterances = SpeakerAligner.utterances(words: result.words, spans: [])
                    .map { Utterance(speaker: "Me", start: $0.start, end: $0.end, text: $0.text) }
            }
            guard wantsVoice else { return TrackTranscription(utterances: utterances) }

            // R28: one embedding of the owner's own voice, for echo only.
            //
            // The Mic Track is still never *split* — the count is pinned to
            // exactly one, so the pipeline can only ever return a single
            // centroid. Run only while Braid has too few exemplars of the
            // owner, so the extra pass costs the first few Sessions and then
            // nothing.
            let me = try await diarizer.diarize(
                file: track, expected: Session.SpeakerExpectation(count: 1, strict: true),
                wantsVoiceData: true)
            let voice = me.voices.max { $0.seconds < $1.seconds }
                .map { SpeakerVoice(speakerId: "Me", centroid: $0.centroid, seconds: $0.seconds) }
            return TrackTranscription(utterances: utterances,
                                      voices: voice.map { [$0] } ?? [])
        }
    }

    // MARK: - Remote Track

    public func transcribeRemote(track: URL, keyTerms: [String],
                                 expectedSpeakers: Session.SpeakerExpectation?,
                                 known: VoiceDatabase?) async throws -> TrackTranscription {
        try await wrapping {
            // Deliberately sequential, not concurrent. Both stages are heavy
            // CoreML models and running them together would double peak memory
            // on the 8GB machine this whole project is shaped around. Batch
            // means the wall-clock cost of doing one after the other is a few
            // seconds per audio-hour, which nobody is waiting on.
            let result = try await engine.transcribe(file: track, keyTerms: keyTerms)
            let wantsVoiceData = known != nil
            var diarized = try await diarizer.diarize(file: track, expected: expectedSpeakers,
                                                      wantsVoiceData: wantsVoiceData)
            log.notice("""
                \(name, privacy: .public): remote track, \(result.words.count) words, \
                \(Set(diarized.spans.map(\.speakerId)).count) voices in \(diarized.spans.count) turns
                """)

            var matches: [String: VoiceMatch] = [:]
            var corrections = 0

            if let known {
                for voice in diarized.voices {
                    matches[voice.speakerId] = identifier.match(voice, in: known)
                }
                // Re-attribution reads the matches, so it runs after them and
                // its own introduced labels arrive already identified.
                let resolved = matches.compactMapValues { $0.isConfident ? $0.personID : nil }
                let fixed = identifier.reattribute(
                    spans: diarized.spans, chunks: diarized.chunks, voices: diarized.voices,
                    resolved: resolved, in: known)
                diarized.spans = fixed.spans
                corrections = fixed.corrections
                for (label, personID) in fixed.introduced {
                    guard let person = known.person(id: personID) else { continue }
                    matches[label] = .confident(personID: personID, name: person.name, score: 1)
                    // A label Re-attribution invented has no centroid of its
                    // own; it exists because a Person was already recognised,
                    // so there is nothing further to learn from it.
                }
                if corrections > 0 {
                    log.notice("re-attribution moved \(corrections) turn(s) using known voices")
                }
            }

            guard !result.words.isEmpty else {
                // Text but no timings: better one honest unattributed block than
                // words scattered across speakers by guesswork.
                return TrackTranscription(
                    utterances: SpeakerAligner.wholeTrack(
                        text: result.text, duration: result.duration, speaker: "Speaker"),
                    spans: diarized.spans, voices: diarized.voices, matches: matches,
                    corrections: corrections)
            }
            return TrackTranscription(
                utterances: SpeakerAligner.utterances(words: result.words, spans: diarized.spans),
                spans: diarized.spans, voices: diarized.voices, matches: matches,
                corrections: corrections)
        }
    }

    /// Local failures are the pipeline's own vocabulary by the time they leave
    /// here, and none of them auto-retry: a missing model does not improve by
    /// being asked again in thirty seconds.
    private func wrapping(
        _ work: () async throws -> TrackTranscription
    ) async throws -> TrackTranscription {
        do {
            return try await work()
        } catch let error as LocalEngineError {
            throw error.asPipelineError
        } catch let error as PipelineError {
            throw error
        } catch is CancellationError {
            throw PipelineError.cancelled
        } catch {
            throw PipelineError.permanent("local transcription: \(error)")
        }
    }
}

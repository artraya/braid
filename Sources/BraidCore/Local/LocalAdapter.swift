import Foundation
import os

/// Transcription and diarization entirely on this Mac.
///
/// Sits behind the same `STTProvider` seam as the cloud Adapter, which is what
/// the seam was built for: the Job pipeline, the merge rule, the naming flow
/// and the Note format all stay exactly as they are and never learn that
/// anything changed.
///
/// The split-Track design does most of the work here. The Mic Track is one
/// speaker structurally (ADR-0001), so it is plain ASR with no diarization at
/// all. Only the Remote Track is diarized and aligned, and it contains nobody
/// the user could be confused with.
public struct LocalAdapter: STTProvider {
    public var name: String { engine.id.providerName }
    public var prefersCompressedUpload: Bool { false }
    public var isLocal: Bool { true }

    let engine: any TranscriberEngine
    let diarizer: any SpeakerDiarizing
    let log = Logger(subsystem: "no.braid.app", category: "pipeline")

    public init(engine: any TranscriberEngine,
                diarizer: any SpeakerDiarizing = LocalDiarizer()) {
        self.engine = engine
        self.diarizer = diarizer
    }

    /// Convenience for the app: the configured engine plus a shared diarizer.
    public static func make(engine id: LocalEngine) -> LocalAdapter {
        switch id {
        case .parakeet: LocalAdapter(engine: ParakeetEngine())
        case .apple: LocalAdapter(engine: AppleSpeechEngine())
        }
    }

    /// Downloads and loads everything this Adapter needs, so the first Session
    /// after enabling local does not stall on a model fetch.
    public func prepare(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        try await engine.prepare(progress: progress)
        try await diarizer.prepare(progress: progress)
    }

    /// True when a Session could start right now without downloading anything.
    public var isReady: Bool {
        get async { await engine.isReady }
    }

    public func transcribe(track: URL, diarize: Bool, keyTerms: [String],
                           expectedSpeakers: Session.SpeakerExpectation?) async throws -> [Utterance] {
        do {
            if !diarize {
                let result = try await engine.transcribe(file: track, keyTerms: keyTerms)
                log.notice("local \(name, privacy: .public): mic track, \(result.words.count) words")
                guard !result.words.isEmpty else {
                    return SpeakerAligner.wholeTrack(text: result.text,
                                                     duration: result.duration, speaker: "Me")
                }
                // One speaker: no spans, so everything lands in one stream.
                // The caller relabels it "Me" (merge rule).
                return SpeakerAligner.utterances(words: result.words, spans: [])
                    .map { Utterance(speaker: "Me", start: $0.start, end: $0.end, text: $0.text) }
            }

            // Deliberately sequential, not concurrent. Both stages are heavy
            // CoreML models and running them together would double peak memory
            // on the 8GB machine this whole project is shaped around. Batch
            // means the wall-clock cost of doing one after the other is a few
            // seconds per audio-hour, which nobody is waiting on.
            let result = try await engine.transcribe(file: track, keyTerms: keyTerms)
            let spans = try await diarizer.diarize(file: track, expected: expectedSpeakers)
            log.notice("""
                local \(name, privacy: .public): remote track, \(result.words.count) words, \
                \(Set(spans.map(\.speakerId)).count) voices in \(spans.count) turns
                """)

            guard !result.words.isEmpty else {
                // Text but no timings: better one honest unattributed block than
                // words scattered across speakers by guesswork.
                return SpeakerAligner.wholeTrack(text: result.text,
                                                 duration: result.duration, speaker: "Speaker")
            }
            return SpeakerAligner.utterances(words: result.words, spans: spans)
        } catch let error as LocalEngineError {
            throw error.asPipelineError
        } catch let error as PipelineError {
            throw error
        } catch {
            throw PipelineError.permanent("local transcription: \(error)")
        }
    }
}

import Foundation
import FluidAudio

/// Parakeet TDT v3 on the Neural Engine, via FluidAudio.
///
/// The default local engine. Models download once (~hundreds of MB) into
/// Application Support and are reused forever after; nothing is fetched per
/// Session. An actor because the underlying `AsrManager` is one and the loaded
/// models are expensive enough that two Jobs must never load them twice.
public actor ParakeetEngine: TranscriberEngine {
    public nonisolated var id: LocalEngine { .parakeet }

    private var manager: AsrManager?
    private let version: AsrModelVersion

    /// v2 is the English-only model, and Braid is an English-only app — every
    /// request the cloud path makes is explicitly `en_au` (R6). It also has
    /// better English recall than the multilingual v3 and no precision
    /// variants to match. v3 is the seam left open if Braid ever stops being
    /// English-only.
    public init(version: AsrModelVersion = .v2) {
        self.version = version
    }

    public var isReady: Bool { manager != nil }

    public func prepare(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard manager == nil else { return }
        do {
            // Downloads on first use into FluidAudio's shared model directory
            // and loads from it every time after.
            let models = try await AsrModels.downloadAndLoad(version: version)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            self.manager = manager
            progress?(1)
        } catch {
            throw LocalEngineError.modelsUnavailable("\(error)")
        }
    }

    /// Key Terms are not used here. FluidAudio does ship a custom-vocabulary
    /// rescorer for Parakeet, but wiring it is a measurement job of its own
    /// (biasing that fires too eagerly rewrites correct words), so this cycle
    /// leaves it alone rather than half-doing it. Under Parakeet the list still
    /// reaches the Summariser; it just does not bias transcription.
    public func transcribe(file: URL, keyTerms: [String]) async throws -> EngineTranscript {
        try await prepare()
        guard let manager else {
            throw LocalEngineError.modelsUnavailable("models did not load")
        }
        do {
            var state = try TdtDecoderState()
            let result = try await manager.transcribe(file, decoderState: &state)
            return EngineTranscript(
                text: result.text,
                words: Self.words(from: result.tokenTimings),
                duration: result.duration)
        } catch let error as LocalEngineError {
            throw error
        } catch {
            throw LocalEngineError.transcriptionFailed("\(error)")
        }
    }

    /// Rebuilds words from SentencePiece sub-word tokens.
    ///
    /// The tokenizer marks a word boundary with U+2581 ("▁") or a leading
    /// space; everything between two boundaries is one word, and its span runs
    /// from the first token's start to the last token's end.
    static func words(from timings: [TokenTiming]?) -> [TimedWord] {
        guard let timings, !timings.isEmpty else { return [] }
        var out: [TimedWord] = []
        var current: (text: String, start: TimeInterval, end: TimeInterval)?

        func flush() {
            guard let c = current else { return }
            let text = c.text.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { out.append(TimedWord(text: text, start: c.start, end: c.end)) }
            current = nil
        }

        for timing in timings {
            let raw = timing.token
            let starts = raw.hasPrefix("\u{2581}") || raw.hasPrefix(" ")
            let piece = raw.replacingOccurrences(of: "\u{2581}", with: " ")
            if starts || current == nil {
                flush()
                current = (piece, timing.startTime, timing.endTime)
            } else {
                current?.text += piece
                current?.end = timing.endTime
            }
        }
        flush()
        return out
    }
}

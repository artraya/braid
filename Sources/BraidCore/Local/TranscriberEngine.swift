import Foundation

/// One on-device speech-to-text engine.
///
/// The seam is deliberately narrow: give it a file and the Key Terms, get back
/// text with timings where the engine has them. Everything provider-specific —
/// model download, locale assets, how key terms are expressed — lives behind
/// it, exactly as `STTProvider` does for the cloud.
public protocol TranscriberEngine: Sendable {
    var id: LocalEngine { get }

    /// True once this engine can run without downloading anything.
    var isReady: Bool { get async }

    /// Downloads and loads whatever the engine needs. Safe to call repeatedly;
    /// the first call may take a while and use the network, every later one
    /// returns immediately.
    func prepare(progress: (@Sendable (Double) -> Void)?) async throws

    /// Transcribes one whole Track.
    func transcribe(file: URL, keyTerms: [String]) async throws -> EngineTranscript
}

extension TranscriberEngine {
    public func prepare() async throws { try await prepare(progress: nil) }
}

/// Failures that are the local pipeline's own, kept separate from the cloud's
/// so `PipelineError` classification stays honest: a missing model is
/// permanent and must not be retried against a provider that was never asked.
public enum LocalEngineError: Error, CustomStringConvertible {
    case modelsUnavailable(String)
    case localeUnavailable(String)
    case transcriptionFailed(String)
    case diarizationFailed(String)

    public var description: String {
        switch self {
        case .modelsUnavailable(let m): "local models unavailable: \(m)"
        case .localeUnavailable(let m): "local speech locale unavailable: \(m)"
        case .transcriptionFailed(let m): "local transcription failed: \(m)"
        case .diarizationFailed(let m): "local diarization failed: \(m)"
        }
    }

    /// Local failures never retry themselves. Nothing about them improves by
    /// waiting, and a Job that keeps re-running a missing model burns battery
    /// to no end — the user either installs it or switches Provider.
    public var asPipelineError: PipelineError { .permanent(description) }
}

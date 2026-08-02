import Foundation

/// Which on-device engine transcribes a Track. Both produce an
/// `EngineTranscript`; they differ in weight and in what they can be told.
public enum LocalEngine: String, Sendable, Codable, CaseIterable {
    /// Apple's SpeechTranscriber. No download at all — the OS owns the assets,
    /// shared with every other app — and Key Terms reach it as contextual
    /// strings. Measured 9 points better on turn purity than Parakeet against
    /// the same diarizer output, which is why it is the default (ADR-0006).
    case apple
    /// Parakeet TDT via FluidAudio. A slightly lower word error rate on the
    /// disfluent, interrupted speech a meeting actually produces, at the cost
    /// of a 443MB model download and no Key Terms support.
    case parakeet

    public var label: String {
        switch self {
        case .apple: "Apple Speech"
        case .parakeet: "Parakeet"
        }
    }

    /// Named in the Note's `engine` frontmatter, so a Note always says what
    /// produced it (R10).
    public var engineName: String {
        switch self {
        case .apple: "apple-speech"
        case .parakeet: "parakeet"
        }
    }

    /// Whether choosing this engine means waiting for a download.
    public var needsDownload: Bool { self == .parakeet }
}

/// When a Session's Note is written (CONTEXT.md: Delivery).
///
/// One setting, not a mode: the only question is whether a Note may be written
/// while some voices are still unidentified. `held` is the answer for people
/// who would rather wait than fix a filed Note afterwards, and it never waits
/// when there is nothing to ask (R26).
public enum Delivery: String, Sendable, Codable, CaseIterable {
    case immediate
    case held

    public var label: String {
        switch self {
        case .immediate: "As soon as it's ready"
        case .held: "After I've named the speakers"
        }
    }
}

/// One speaker's turn, as the diarizer heard it.
///
/// Carries a label and two timestamps and nothing else. The voice data the
/// diarizer also produces travels separately, as `SpeakerVoice` and
/// `VoiceChunk`, so the aligner — the part that decides who said what — cannot
/// see it and no accidental path exists from a turn to a stored voiceprint
/// (R21, ADR-0007).
public struct SpeakerSpan: Sendable, Equatable {
    public var speakerId: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(speakerId: String, start: TimeInterval, end: TimeInterval) {
        self.speakerId = speakerId
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { max(0, end - start) }

    func contains(_ t: TimeInterval) -> Bool { t >= start && t < end }

    /// How far `t` sits outside this span, zero when inside.
    func distance(to t: TimeInterval) -> TimeInterval {
        if t < start { return start - t }
        if t >= end { return t - end }
        return 0
    }
}

/// One word with its place on the Recording clock (recorded-audio seconds, the
/// same clock every Utterance and pause marker uses).
public struct TimedWord: Sendable, Equatable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }

    var midpoint: TimeInterval { start + (end - start) / 2 }
}

/// What an engine returns for one Track.
public struct EngineTranscript: Sendable {
    public var text: String
    /// Empty when the engine reported no timings; callers fall back to the
    /// whole-Track text rather than inventing positions.
    public var words: [TimedWord]
    public var duration: TimeInterval

    public init(text: String, words: [TimedWord], duration: TimeInterval) {
        self.text = text
        self.words = words
        self.duration = duration
    }
}

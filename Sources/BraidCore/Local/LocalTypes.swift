import Foundation

/// Which on-device engine transcribes a Track. Both produce an
/// `EngineTranscript`; they differ in weight and in what they can be told.
public enum LocalEngine: String, Sendable, Codable, CaseIterable {
    /// Parakeet TDT v3 via FluidAudio. Stronger on the disfluent, interrupted
    /// speech a meeting actually produces, and gives honest token timings.
    /// Costs a model download.
    case parakeet
    /// Apple's SpeechTranscriber. No download at all — the OS owns the assets —
    /// and Key Terms reach it as contextual strings.
    case apple

    public var label: String {
        switch self {
        case .parakeet: "Parakeet"
        case .apple: "Apple Speech"
        }
    }

    /// Named in the Note's `provider` frontmatter, so a Note always says what
    /// produced it (R10 already carries the field).
    public var providerName: String {
        switch self {
        case .parakeet: "local-parakeet"
        case .apple: "local-apple"
        }
    }
}

/// Where transcription happens.
///
/// `auto` prefers local and falls back to the cloud, always disclosing it.
/// `local` never reaches the network under any failure — a Job parks as
/// `.failed` instead, because silently uploading audio the user asked to keep
/// on the machine would be the worst bug this app could have.
public enum ProviderMode: String, Sendable, Codable, CaseIterable {
    case cloud, local, auto

    public var label: String {
        switch self {
        case .cloud: "Cloud"
        case .local: "On this Mac"
        case .auto: "Automatic"
        }
    }
}

/// One speaker's turn, as the diarizer heard it.
///
/// Deliberately carries no embedding. FluidAudio's `TimedSpeakerSegment`
/// exposes the raw voice vector it clustered on; mapping into this type at the
/// boundary is where ADR-0003 is enforced, so nothing downstream can persist a
/// voiceprint even by accident. Speaker identity is an opaque within-Session
/// label and nothing more.
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

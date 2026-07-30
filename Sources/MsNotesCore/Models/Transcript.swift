import Foundation

/// One spoken segment attributed to a single speaker.
public struct Utterance: Sendable, Codable, Equatable {
    /// "Me" for the Mic Track; "Speaker 1"… for Remote speakers (numbered by
    /// first appearance), or a user-assigned name later.
    public var speaker: String
    /// Recorded-audio seconds (the clock pauses with the Recording).
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String

    public init(speaker: String, start: TimeInterval, end: TimeInterval, text: String) {
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
    }
}

/// The provider-independent, speaker-labelled, timestamped text of a Session.
public struct Transcript: Sendable, Codable, Equatable {
    public var utterances: [Utterance]
    public var pauseSpans: [PauseMarker]

    public struct PauseMarker: Sendable, Codable, Equatable {
        /// Recorded-audio seconds at which the pause occurred.
        public var atRecordedSeconds: TimeInterval
        /// Wall-clock length of the gap.
        public var wallGapSeconds: TimeInterval
        public init(atRecordedSeconds: TimeInterval, wallGapSeconds: TimeInterval) {
            self.atRecordedSeconds = atRecordedSeconds
            self.wallGapSeconds = wallGapSeconds
        }
    }

    public init(utterances: [Utterance], pauseSpans: [PauseMarker] = []) {
        self.utterances = utterances
        self.pauseSpans = pauseSpans
    }

    /// Distinct Remote speakers (everyone but "Me"), in order of first appearance.
    public var remoteSpeakers: [String] {
        var seen = [String]()
        for u in utterances where u.speaker != "Me" && !seen.contains(u.speaker) {
            seen.append(u.speaker)
        }
        return seen
    }

    /// Markdown per SPEC (Transcript format): one line per utterance,
    /// `- **HH:MM:SS Speaker:** text`, pause markers on their own line.
    public func markdown() -> String {
        struct Line { let at: TimeInterval; let order: Int; let text: String }
        var lines: [Line] = []
        for u in utterances {
            lines.append(Line(at: u.start, order: 1,
                text: "- **\(Self.timestamp(u.start)) \(u.speaker):** \(u.text)"))
        }
        for p in pauseSpans {
            lines.append(Line(at: p.atRecordedSeconds, order: 0,
                text: "\n[recording paused — \(Self.gap(p.wallGapSeconds))]\n"))
        }
        return lines
            .sorted { ($0.at, $0.order) < ($1.at, $1.order) }
            .map(\.text)
            .joined(separator: "\n")
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
    }

    public static func timestamp(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }

    /// "4m 12s" / "37s" / "1h 2m 3s"
    public static func gap(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        let (h, m, sec) = (s / 3600, (s / 60) % 60, s % 60)
        var parts: [String] = []
        if h > 0 { parts.append("\(h)h") }
        if m > 0 { parts.append("\(m)m") }
        if sec > 0 || parts.isEmpty { parts.append("\(sec)s") }
        return parts.joined(separator: " ")
    }
}

/// SPEC merge rule: both Tracks share the Recording clock; the Transcript is
/// the utterance lists of both results interleaved by start timestamp.
/// Remote speakers are renumbered "Speaker 1"… by first appearance; every Mic
/// utterance is already labelled "Me" by the Adapter.
public func mergeTranscripts(
    mic: [Utterance],
    remote: [Utterance],
    pauseSpans: [Transcript.PauseMarker]
) -> Transcript {
    var renamed: [String: String] = [:]
    var next = 1
    var remoteRelabelled: [Utterance] = []
    for u in remote.sorted(by: { $0.start < $1.start }) {
        var copy = u
        if let existing = renamed[u.speaker] {
            copy.speaker = existing
        } else {
            let label = "Speaker \(next)"
            renamed[u.speaker] = label
            copy.speaker = label
            next += 1
        }
        remoteRelabelled.append(copy)
    }
    let all = (mic.map { Utterance(speaker: "Me", start: $0.start, end: $0.end, text: $0.text) }
               + remoteRelabelled)
        .sorted { $0.start < $1.start }
    return Transcript(utterances: all, pauseSpans: pauseSpans)
}

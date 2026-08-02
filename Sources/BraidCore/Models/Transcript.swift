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

    /// What the naming sheet needs to tell one speaker from another: how much
    /// they talked and a line long enough to recognise them by.
    public struct SpeakerStat: Sendable, Codable, Equatable, Identifiable {
        public var id: String { speaker }
        public var speaker: String
        public var totalSeconds: TimeInterval
        public var utteranceCount: Int
        /// Their longest utterance, truncated. Long lines identify a person far
        /// better than first lines, which are usually "yeah" or "can you hear me".
        public var sample: String
        public var firstAt: TimeInterval
    }

    /// Remote speakers with talk time, most talkative first.
    public func remoteSpeakerStats(sampleLimit: Int = 160) -> [SpeakerStat] {
        var stats: [String: SpeakerStat] = [:]
        for u in utterances where u.speaker != "Me" {
            let spoken = max(0, u.end - u.start)
            if var existing = stats[u.speaker] {
                existing.totalSeconds += spoken
                existing.utteranceCount += 1
                if u.text.count > existing.sample.count { existing.sample = u.text }
                existing.firstAt = min(existing.firstAt, u.start)
                stats[u.speaker] = existing
            } else {
                stats[u.speaker] = SpeakerStat(
                    speaker: u.speaker, totalSeconds: spoken, utteranceCount: 1,
                    sample: u.text, firstAt: u.start)
            }
        }
        return stats.values
            .map { stat in
                var copy = stat
                if copy.sample.count > sampleLimit {
                    copy.sample = String(copy.sample.prefix(sampleLimit)) + "…"
                }
                return copy
            }
            .sorted {
                $0.totalSeconds == $1.totalSeconds
                    ? $0.firstAt < $1.firstAt
                    : $0.totalSeconds > $1.totalSeconds
            }
    }

    /// Removes Mic-Track echoes of Remote speech (echo cycle, layer 3).
    ///
    /// Speaker playback re-entering the mic puts the far end's words on both
    /// Tracks; the merge then attributes the duplicate to "Me". An echo lags
    /// its original by well under a second, so a "Me" utterance that
    /// time-overlaps a Remote utterance *and* repeats its words is a duplicate,
    /// not the user. Both conditions are required, so a genuine interruption
    /// (overlapping, different words) and a genuine echoed agreement of fewer
    /// than `minTokens` words ("yeah, exactly") always survive — conservative
    /// by design, and callers only run this on Sessions where bleed was proved.
    public func dedupingEchoes(minTokens: Int = 3,
                               minSimilarity: Double = 0.6) -> (transcript: Transcript, dropped: Int) {
        let remotes = utterances.filter { $0.speaker != "Me" }
        guard !remotes.isEmpty else { return (self, 0) }
        var dropped = 0
        var copy = self
        copy.utterances = utterances.filter { u in
            guard u.speaker == "Me" else { return true }
            let tokens = Self.tokens(u.text)
            guard tokens.count >= minTokens else { return true }
            let isEcho = remotes.contains { r in
                // Overlap against the Remote utterance widened by half a
                // second each way: provider timestamps are approximate.
                let overlap = min(u.end, r.end + 0.5) - max(u.start, r.start - 0.5)
                guard overlap >= 0.5 * max(0.1, u.end - u.start) else { return false }
                let remoteTokens = Self.tokens(r.text)
                guard !remoteTokens.isEmpty else { return false }
                // Containment, not symmetric similarity: the echo is a partial,
                // often mangled copy of the original, never a superset.
                let contained = tokens.filter(remoteTokens.contains).count
                return Double(contained) / Double(tokens.count) >= minSimilarity
            }
            if isEcho { dropped += 1 }
            return !isEcho
        }
        return (copy, dropped)
    }

    static func tokens(_ text: String) -> Set<String> {
        Set(text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty })
    }

    /// Applies user-assigned names. Keys are current labels ("Speaker 1"),
    /// values the names to use. Unmapped and blank entries are left alone, and
    /// "Me" is never renamed (R11).
    public func renamingSpeakers(_ names: [String: String]) -> Transcript {
        var copy = self
        copy.utterances = utterances.map { u in
            guard u.speaker != "Me",
                  let name = names[u.speaker]?.trimmingCharacters(in: .whitespaces),
                  !name.isEmpty else { return u }
            var renamed = u
            renamed.speaker = name
            return renamed
        }
        return copy
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

/// The merged Transcript, plus how the diarizer's labels map onto it.
///
/// Identification works in the diarizer's vocabulary ("S1", or a label
/// Re-attribution introduced) while everything downstream works in the
/// Transcript's ("Speaker 1"). The map is how a voice keeps its identity across
/// that rename — without it, a confident match would have nothing to attach to.
public struct MergedTranscript: Sendable {
    public var transcript: Transcript
    /// Diarizer label → "Speaker N".
    public var remoteLabels: [String: String]

    public init(transcript: Transcript, remoteLabels: [String: String]) {
        self.transcript = transcript
        self.remoteLabels = remoteLabels
    }
}

/// SPEC merge rule: both Tracks share the Recording clock; the Transcript is
/// the utterance lists of both results interleaved by start timestamp.
/// Remote speakers are renumbered "Speaker 1"… by first appearance; every Mic
/// utterance is already labelled "Me" by the Transcriber.
public func mergeTranscripts(
    mic: [Utterance],
    remote: [Utterance],
    pauseSpans: [Transcript.PauseMarker]
) -> MergedTranscript {
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
    return MergedTranscript(
        transcript: Transcript(utterances: all, pauseSpans: pauseSpans),
        remoteLabels: renamed)
}

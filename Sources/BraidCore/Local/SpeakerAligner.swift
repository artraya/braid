import Foundation

/// Puts words in the right speaker's mouth.
///
/// This is the step ADR-0002 called "a genuinely error-prone reconciliation"
/// and parked local diarization over. Braid's split-file design shrinks it to
/// something much smaller: only the Remote Track is ever aligned, the user's
/// own voice is on the other file and cannot be confused with anyone, and both
/// results already share one clock (ADR-0001), so this is an overlap lookup and
/// not a search for the offset between two recordings.
///
/// Kept pure and free of any model so it can be tested exactly, which is where
/// the confidence in local attribution actually comes from.
public enum SpeakerAligner {

    /// Groups timed words into Utterances by the speaker talking at each word.
    ///
    /// - Parameters:
    ///   - words: engine output, in time order.
    ///   - spans: diarizer output; may overlap and need not cover every word.
    ///   - maxGap: silence inside one speaker's turn that still reads as one
    ///     utterance. Beyond it the turn is split, so a long pause does not
    ///     glue a greeting to an answer ten minutes later.
    ///   - snapTolerance: how far outside every span a word may sit and still
    ///     be attributed to the nearest one. Diarizer boundaries land mid-word
    ///     routinely; without this, ordinary words at turn edges would be
    ///     dropped or misattributed.
    public static func utterances(words: [TimedWord],
                                  spans: [SpeakerSpan],
                                  maxGap: TimeInterval = 1.5,
                                  snapTolerance: TimeInterval = 0.75) -> [Utterance] {
        let words = words.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !words.isEmpty else { return [] }
        guard !spans.isEmpty else {
            // No diarization: one unlabelled stream. The merge rule numbers it.
            return group(words.map { (word: $0, speaker: "Speaker") }, maxGap: maxGap)
        }
        let ordered = spans.sorted { $0.start < $1.start }

        var labelled: [(word: TimedWord, speaker: String)] = []
        var previous: String?
        for word in words.sorted(by: { $0.start < $1.start }) {
            let speaker = self.speaker(at: word, spans: ordered,
                                       snapTolerance: snapTolerance) ?? previous
            // A word before the first span and with no predecessor belongs to
            // whoever speaks first; dropping it would lose real speech.
            let resolved = speaker ?? ordered[0].speakerId
            labelled.append((word, resolved))
            previous = resolved
        }
        return group(labelled, maxGap: maxGap)
    }

    /// The speaker talking at a word, or nil if none is close enough.
    ///
    /// Uses the word's midpoint rather than its start: a word straddling a turn
    /// boundary belongs to whoever was speaking for most of it.
    static func speaker(at word: TimedWord, spans: [SpeakerSpan],
                        snapTolerance: TimeInterval) -> String? {
        let t = word.midpoint
        // Overlap wins outright. Where spans overlap each other (crosstalk),
        // prefer the one covering more of this word.
        let covering = spans.filter { $0.contains(t) }
        if !covering.isEmpty {
            return covering.max { a, b in
                overlap(word, a) < overlap(word, b)
            }?.speakerId
        }
        // Otherwise snap to the nearest span, but only if it is genuinely near.
        guard let nearest = spans.min(by: { $0.distance(to: t) < $1.distance(to: t) }),
              nearest.distance(to: t) <= snapTolerance else { return nil }
        return nearest.speakerId
    }

    static func overlap(_ word: TimedWord, _ span: SpeakerSpan) -> TimeInterval {
        max(0, min(word.end, span.end) - max(word.start, span.start))
    }

    /// Runs of the same speaker become one Utterance, split on long silences.
    static func group(_ labelled: [(word: TimedWord, speaker: String)],
                      maxGap: TimeInterval) -> [Utterance] {
        var out: [Utterance] = []
        var current: (speaker: String, start: TimeInterval, end: TimeInterval, words: [String])?

        func flush() {
            guard let c = current, !c.words.isEmpty else { return }
            out.append(Utterance(speaker: c.speaker, start: c.start, end: c.end,
                                 text: c.words.joined(separator: " ")))
            current = nil
        }

        for item in labelled {
            let text = item.word.text.trimmingCharacters(in: .whitespaces)
            if var c = current, c.speaker == item.speaker, item.word.start - c.end <= maxGap {
                c.end = max(c.end, item.word.end)
                c.words.append(text)
                current = c
            } else {
                flush()
                current = (item.speaker, item.word.start, item.word.end, [text])
            }
        }
        flush()
        return out
    }

    /// Fallback when an engine gives text but no timings: one Utterance for the
    /// whole Track. Honest about what is known rather than inventing positions.
    public static func wholeTrack(text: String, duration: TimeInterval,
                                  speaker: String) -> [Utterance] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return [Utterance(speaker: speaker, start: 0, end: duration, text: trimmed)]
    }
}

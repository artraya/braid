import Foundation

/// One Start→Stop span. Produces one Recording, one Transcript, one Note.
public struct Session: Sendable, Codable, Identifiable {
    /// A speaker count the user asserted at Start (amended R6). `count` is
    /// always sent as a minimum — that fixes two voices heard as one and can
    /// never fold a late joiner. Only `strict` adds the maximum, and the Start
    /// form labels what that costs: late joiners get merged.
    public struct SpeakerExpectation: Sendable, Codable, Equatable {
        public var count: Int
        public var strict: Bool
        public init(count: Int, strict: Bool = false) {
            self.count = count
            self.strict = strict
        }
    }

    /// Heard-vs-expected disagreement, computed after transcription. `asserted`
    /// distinguishes a hard signal (the user set a count) from a soft one (they
    /// listed Participants).
    public struct SpeakerCountMismatch: Sendable, Codable, Equatable {
        public var heard: Int
        public var expected: Int
        public var asserted: Bool

        public init(heard: Int, expected: Int, asserted: Bool) {
            self.heard = heard
            self.expected = expected
            self.asserted = asserted
        }

        /// One sentence for the notification and the naming sheet. Fewer than
        /// expected is honest about the only fix: the audio is gone (R7), so
        /// the count can only help the *next* call.
        public var message: String {
            let voices = "Heard \(heard) voice\(heard == 1 ? "" : "s"); "
            let expectation = asserted
                ? "you set \(expected)."
                : "you listed \(expected) participant\(expected == 1 ? "" : "s")."
            let advice = heard < expected
                ? " If voices were merged, set the speaker count before the next call."
                : ""
            return voices + expectation + advice
        }
    }

    public var id: String
    /// Optional user title from the Start popover; defaults to the Preset name.
    public var title: String
    public var presetName: String
    /// Optional per-Session names, Summariser hints only (never sent as identities).
    public var participants: [String]
    /// Optional user-asserted speaker count for the Remote Track (amended R6).
    /// Optional so Sessions persisted before this field decode as Auto.
    public var expectedSpeakers: SpeakerExpectation?
    /// Wall-clock Start (filename uses this, local time — SPEC R9).
    public var startedAt: Date
    /// Recorded audio only, pauses excluded (SPEC R10).
    public var recordedDuration: TimeInterval
    public var pauseSpans: [Transcript.PauseMarker]

    public init(
        id: String = UUID().uuidString,
        title: String,
        presetName: String,
        participants: [String],
        expectedSpeakers: SpeakerExpectation? = nil,
        startedAt: Date,
        recordedDuration: TimeInterval = 0,
        pauseSpans: [Transcript.PauseMarker] = []
    ) {
        self.id = id
        self.title = title
        self.presetName = presetName
        self.participants = participants
        self.expectedSpeakers = expectedSpeakers
        self.startedAt = startedAt
        self.recordedDuration = recordedDuration
        self.pauseSpans = pauseSpans
    }

    /// Key Terms for both Provider requests: the global list plus this
    /// Session's Participants, so the very names R11 needs as transcript
    /// evidence arrive spelled correctly. Deduplicated case-insensitively;
    /// never a speaker count (amended R6).
    public func mergedKeyTerms(global: [String]) -> [String] {
        var terms = global
        for name in participants {
            if !terms.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                terms.append(name)
            }
        }
        return terms
    }

    /// Compares what diarization heard against what this Session expected.
    /// The asserted count wins over the Participants hint; no expectation, no
    /// warning. `heard == 0` is R16's territory (no system audio), not a
    /// diarization mismatch.
    public func speakerMismatch(heardRemoteSpeakers heard: Int) -> SpeakerCountMismatch? {
        guard heard > 0 else { return nil }
        if let expectation = expectedSpeakers {
            guard heard != expectation.count else { return nil }
            return SpeakerCountMismatch(heard: heard, expected: expectation.count,
                                        asserted: true)
        }
        guard !participants.isEmpty, heard != participants.count else { return nil }
        return SpeakerCountMismatch(heard: heard, expected: participants.count,
                                    asserted: false)
    }
}

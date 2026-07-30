import Foundation

/// One Start→Stop span. Produces one Recording, one Transcript, one Note.
public struct Session: Sendable, Codable, Identifiable {
    public var id: String
    /// Optional user title from the Start popover; defaults to the Preset name.
    public var title: String
    public var presetName: String
    /// Optional per-Session names, Summariser hints only (never sent as identities).
    public var participants: [String]
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
        startedAt: Date,
        recordedDuration: TimeInterval = 0,
        pauseSpans: [Transcript.PauseMarker] = []
    ) {
        self.id = id
        self.title = title
        self.presetName = presetName
        self.participants = participants
        self.startedAt = startedAt
        self.recordedDuration = recordedDuration
        self.pauseSpans = pauseSpans
    }
}

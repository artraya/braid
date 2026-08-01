import Foundation
import CryptoKit
import os

/// Everything needed to rename a Session's speakers after its Note has already
/// been written: the structured Transcript (the Vault only holds markdown), the
/// facts the frontmatter is built from, and where the pair landed.
///
/// The Recording is gone by the time this exists, so naming can never re-run
/// transcription — it relabels text and re-runs the Summariser.
public struct NamingRecord: Sendable, Codable, Identifiable {
    public var id: String { session.id }
    public var session: Session
    public var transcript: Transcript
    public var provider: String
    /// What the Session has cost so far, including any re-summarise.
    public var costUSD: Double
    public var notePath: String
    public var transcriptPath: String
    /// SHA-256 of the Note exactly as written. Guards against overwriting edits
    /// the user has since made in Obsidian.
    public var noteHash: String
    public var completedAt: Date
    /// Set once the user has named speakers. The record is kept afterwards so a
    /// name can be corrected, but it stops prompting.
    public var namesApplied = false
    /// Heard-vs-expected disagreement at delivery, shown in the naming sheet.
    /// Optional so records persisted before this field decode unchanged.
    public var speakerMismatch: Session.SpeakerCountMismatch?

    public init(session: Session, transcript: Transcript, provider: String,
                costUSD: Double, notePath: String, transcriptPath: String,
                noteHash: String, completedAt: Date = Date(),
                speakerMismatch: Session.SpeakerCountMismatch? = nil) {
        self.session = session
        self.transcript = transcript
        self.provider = provider
        self.costUSD = costUSD
        self.notePath = notePath
        self.transcriptPath = transcriptPath
        self.noteHash = noteHash
        self.completedAt = completedAt
        self.speakerMismatch = speakerMismatch
    }

    public static func hash(_ contents: String) -> String {
        SHA256.hash(data: Data(contents.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// Stores NamingRecords as JSON beside the Job state. A record is dropped once
/// its speakers are named, or when it ages out — an unnamed Transcript is not
/// worth keeping indefinitely, and it is the one place transcript text lingers
/// outside the Vault.
public struct TranscriptStore: Sendable {
    public static let retention: TimeInterval = 30 * 24 * 3600

    let root: URL
    let log = Logger(subsystem: "no.braid.app", category: "pipeline")

    public init(root: URL = JobQueue.appSupportURL.appendingPathComponent("transcripts")) {
        self.root = root
    }

    public func save(_ record: NamingRecord) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: url(for: record.id), options: .atomic)
    }

    public func load(_ id: String) -> NamingRecord? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        return try? JSONDecoder().decode(NamingRecord.self, from: data)
    }

    /// Pending records, newest first.
    public func all() -> [NamingRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? JSONDecoder().decode(NamingRecord.self, from: $0) }
            .sorted { $0.completedAt > $1.completedAt }
    }

    public func remove(_ id: String) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    /// Drops records past the retention window. Cheap; called at launch.
    public func purgeExpired(now: Date = Date()) {
        for record in all() where now.timeIntervalSince(record.completedAt) > Self.retention {
            log.notice("purging unnamed transcript \(record.id, privacy: .public)")
            remove(record.id)
        }
    }

    func url(for id: String) -> URL {
        root.appendingPathComponent("\(id).json")
    }
}

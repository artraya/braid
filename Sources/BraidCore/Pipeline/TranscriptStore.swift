import Foundation
import CryptoKit
import os

/// Everything needed to put names to a Session's voices: the structured
/// Transcript (the Vault only holds markdown), the facts the frontmatter is
/// built from, where the pair landed if it has been written, and the
/// enrollment candidate behind each unnamed Speaker.
///
/// The Recording is gone by the time this exists, so naming can never re-run
/// transcription — it relabels text and re-runs the Summariser.
///
/// A record with no `notePath` is a Held Session (R26): transcribed, waiting
/// for names, its Note not yet written.
public struct NamingRecord: Sendable, Codable, Identifiable {
    public var id: String { session.id }
    public var session: Session
    public var transcript: Transcript
    /// Which Engine produced it, for the Note's frontmatter (R10).
    public var engine: String
    /// Empty until the Note is written.
    public var notePath: String
    public var transcriptPath: String
    /// SHA-256 of the Note exactly as written. Guards against overwriting edits
    /// the user has since made in Obsidian.
    public var noteHash: String
    public var completedAt: Date
    /// Set once the user has named speakers. The record is kept afterwards so a
    /// name can be corrected, but it stops prompting.
    public var namesApplied = false
    /// Heard-vs-expected disagreement, shown in the naming flow.
    public var speakerMismatch: Session.SpeakerCountMismatch?

    /// The voice behind each still-unnamed Speaker, keyed by its Transcript
    /// label. Naming one promotes it to a Voiceprint (R24); skipping drops it
    /// with the record's clips (R21). This is the only audio-derived data that
    /// outlives its Job, which is why the whole store is encrypted.
    public var candidates: [String: SpeakerVoice] = [:]
    /// Names the database thought plausible but not certain, offered as chips.
    public var suggestions: [String: String] = [:]
    /// Speakers auto-named from a confident match, and the Person each became,
    /// so correcting one can remove the Voiceprint that caused it (R24).
    public var autoNamed: [String: String] = [:]

    /// True while this Session still has something to ask the user.
    public var isDelivered: Bool { !notePath.isEmpty }

    public init(session: Session, transcript: Transcript, engine: String,
                notePath: String = "", transcriptPath: String = "",
                noteHash: String = "", completedAt: Date = Date(),
                speakerMismatch: Session.SpeakerCountMismatch? = nil,
                candidates: [String: SpeakerVoice] = [:],
                suggestions: [String: String] = [:],
                autoNamed: [String: String] = [:]) {
        self.session = session
        self.transcript = transcript
        self.engine = engine
        self.notePath = notePath
        self.transcriptPath = transcriptPath
        self.noteHash = noteHash
        self.completedAt = completedAt
        self.speakerMismatch = speakerMismatch
        self.candidates = candidates
        self.suggestions = suggestions
        self.autoNamed = autoNamed
    }

    public static func hash(_ contents: String) -> String {
        SHA256.hash(data: Data(contents.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// Stores NamingRecords beside the Job state, encrypted.
///
/// It holds transcript text and enrollment candidates, so it gets the same
/// treatment as the Voice Database: sealed with the Keychain key that never
/// leaves this Mac (R21). A record is dropped once its Session's Identification
/// resolves, or when it ages out — an unnamed Transcript is not worth keeping
/// indefinitely, and it is the one place transcript text lingers outside the
/// Vault.
public struct TranscriptStore: Sendable {
    public static let retention: TimeInterval = 30 * 24 * 3600

    let root: URL
    let box: SecretBox
    let log = Logger(subsystem: "no.braid.app", category: "pipeline")

    public init(root: URL = JobQueue.appSupportURL.appendingPathComponent("transcripts"),
                box: SecretBox = SecretBox()) {
        self.root = root
        self.box = box
    }

    public func save(_ record: NamingRecord) {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let plain = try JSONEncoder().encode(record)
            try box.seal(plain).write(to: url(for: record.id), options: .atomic)
        } catch {
            log.error("could not store a naming record: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func load(_ id: String) -> NamingRecord? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        return decode(data)
    }

    /// Pending records, newest first.
    public func all() -> [NamingRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "rec" }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { decode($0) }
            .sorted { $0.completedAt > $1.completedAt }
    }

    /// Sessions whose Note is written but whose voices are still unnamed.
    public func awaitingNames() -> [NamingRecord] {
        all().filter { !$0.namesApplied }
    }

    public func remove(_ id: String) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    /// Drops records past the retention window, and any plaintext record left
    /// by a build that predates encryption. Cheap; called at launch.
    public func purgeExpired(now: Date = Date()) {
        for record in all() where now.timeIntervalSince(record.completedAt) > Self.retention {
            log.notice("purging unnamed transcript \(record.id, privacy: .public)")
            remove(record.id)
        }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        for stale in files where stale.pathExtension == "json" {
            log.notice("removing a plaintext naming record from an earlier build")
            try? FileManager.default.removeItem(at: stale)
        }
    }

    private func decode(_ data: Data) -> NamingRecord? {
        guard let plain = try? box.open(data) else { return nil }
        return try? JSONDecoder().decode(NamingRecord.self, from: plain)
    }

    func url(for id: String) -> URL {
        root.appendingPathComponent("\(id).rec")
    }
}

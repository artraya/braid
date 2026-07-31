import Foundation
import os

/// Applies user-assigned speaker names to an already-delivered Session.
///
/// The Job pipeline never waits for this. A Note is written as soon as it is
/// ready, and naming is an optional second pass: relabel the Transcript, re-run
/// the Summariser so the prose says "Sarah" rather than "Speaker 1", and rewrite
/// the pair in the Vault. It costs one more Claude call, no transcription.
public struct SpeakerNamer: Sendable {
    public struct Result: Sendable {
        public let noteURL: URL
        public let addedCostUSD: Double
        /// True when the Note in the Vault had been edited since we wrote it,
        /// so a new pair was written rather than overwriting those edits.
        public let wroteNewPair: Bool
    }

    let summariser: Summariser
    let settings: SettingsStore
    let costTable: CostTable
    let store: TranscriptStore
    let sessions: SessionIndex
    let log = Logger(subsystem: "no.msnotes.app", category: "pipeline")

    public init(summariser: Summariser, settings: SettingsStore,
                costTable: CostTable = .current, store: TranscriptStore = TranscriptStore(),
                sessions: SessionIndex = SessionIndex()) {
        self.summariser = summariser
        self.settings = settings
        self.costTable = costTable
        self.store = store
        self.sessions = sessions
    }

    /// `names` maps current labels ("Speaker 1") to what the user typed. Blank
    /// and unchanged entries are ignored.
    public func apply(names: [String: String], toSessionID id: String) async throws -> Result {
        guard let record = store.load(id) else {
            throw PipelineError.permanent("no stored transcript for session \(id)")
        }
        guard let vaultPath = settings.vaultPath else {
            throw PipelineError.permanent("no Vault path configured")
        }
        let assigned = names.compactMapValues { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard !assigned.isEmpty else {
            throw PipelineError.permanent("no names given")
        }

        let renamed = record.transcript.renamingSpeakers(assigned)

        // The named speakers become the Participants: they are now facts about
        // the Session rather than guesses typed before it started.
        var session = record.session
        let existing = Set(session.participants)
        session.participants += assigned.values.filter { !existing.contains($0) }

        guard let preset = settings.presets.first(where: { $0.name == session.presetName })
                ?? settings.presets.first else {
            throw PipelineError.permanent("no Preset named \(session.presetName)")
        }
        let summary = try await summariser.summarise(
            transcript: renamed, session: session, preset: preset)
        let addedCost = costTable.claudeCost(inputTokens: summary.inputTokens,
                                             outputTokens: summary.outputTokens)
        let totalCost = record.costUSD + addedCost

        let noteURL = URL(fileURLWithPath: record.notePath)
        let transcriptURL = URL(fileURLWithPath: record.transcriptPath)
        let writer = VaultWriter(vaultURL: URL(fileURLWithPath: vaultPath))
        let written: VaultWriter.Written
        let wroteNewPair: Bool

        if untouchedSinceWriting(noteURL, expecting: record.noteHash) {
            written = try writer.overwrite(
                noteURL: noteURL, transcriptURL: transcriptURL, session: session,
                noteBody: summary.noteBody, transcript: renamed,
                provider: record.provider, costUSD: totalCost)
            wroteNewPair = false
        } else {
            // Moved, renamed, or edited in Obsidian. Never clobber that.
            log.notice("note for \(id, privacy: .public) changed since delivery — writing a new pair")
            written = try writer.write(
                session: session, noteBody: summary.noteBody, transcript: renamed,
                provider: record.provider, costUSD: totalCost)
            wroteNewPair = true
        }

        settings.addCost(addedCost)
        if wroteNewPair {
            // Same Session id, so this replaces the entry rather than adding
            // a second one; the list should point at the note that is current.
            sessions.add(SessionRecord(session: session, costUSD: totalCost,
                                       notePath: written.noteURL.path))
        } else {
            sessions.addCost(addedCost, toSessionID: session.id)
        }

        var updated = record
        updated.session = session
        updated.transcript = renamed
        updated.costUSD = totalCost
        updated.notePath = written.noteURL.path
        updated.transcriptPath = written.transcriptURL.path
        updated.noteHash = noteHash(of: written.noteURL) ?? ""
        updated.namesApplied = true
        store.save(updated)

        log.notice("named \(assigned.count) speakers in \(id, privacy: .public), +$\(String(format: "%.4f", addedCost))")
        return Result(noteURL: written.noteURL, addedCostUSD: addedCost,
                      wroteNewPair: wroteNewPair)
    }

    func untouchedSinceWriting(_ url: URL, expecting hash: String) -> Bool {
        guard !hash.isEmpty, let current = noteHash(of: url) else { return false }
        return current == hash
    }

    func noteHash(of url: URL) -> String? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return NamingRecord.hash(contents)
    }
}

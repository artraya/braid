import Foundation

/// Writes the Note and the Transcript into the Vault. Atomic (temp file +
/// rename), filename per SPEC R9, frontmatter per R10, transcript companion
/// per Architecture ("Vault delivery").
public struct VaultWriter: Sendable {
    public let vaultURL: URL

    public init(vaultURL: URL) {
        self.vaultURL = vaultURL
    }

    public struct Written: Sendable {
        public let noteURL: URL
        public let transcriptURL: URL
    }

    /// SPEC R9: `/ \ : # ^ [ ] |` replaced by `-`.
    public static func sanitizeTitle(_ title: String) -> String {
        let bad = Set("/\\:#^[]|")
        let cleaned = String(title.map { bad.contains($0) ? "-" : $0 })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    /// `YYYY-MM-DD HHmm Title` — Session Start, local time (SPEC R9).
    public static func baseName(startedAt: Date, title: String) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_AU")
        fmt.timeZone = .current
        fmt.dateFormat = "yyyy-MM-dd HHmm"
        return "\(fmt.string(from: startedAt)) \(sanitizeTitle(title))"
    }

    /// Writes Note + Transcript. Collision: lowest free integer suffix (" 2", " 3", …),
    /// applied to the pair so Note and Transcript names always match.
    public func write(session: Session, noteBody: String, transcript: Transcript,
                      provider: String, costUSD: Double) throws -> Written {
        let fm = FileManager.default
        let transcriptsDir = vaultURL.appendingPathComponent("transcripts")
        try fm.createDirectory(at: transcriptsDir, withIntermediateDirectories: true)

        let base = Self.baseName(startedAt: session.startedAt, title: session.title)
        var candidate = base
        var n = 2
        func noteURL(_ name: String) -> URL {
            vaultURL.appendingPathComponent("\(name).md")
        }
        func transcriptURL(_ name: String) -> URL {
            transcriptsDir.appendingPathComponent("\(name) (transcript).md")
        }
        while fm.fileExists(atPath: noteURL(candidate).path)
            || fm.fileExists(atPath: transcriptURL(candidate).path) {
            candidate = "\(base) \(n)"
            n += 1
        }

        let front = frontmatter(session: session, provider: provider, costUSD: costUSD,
                                transcriptName: "\(candidate) (transcript)")
        try atomicWrite(front + "\n" + noteBody + "\n", to: noteURL(candidate))
        try atomicWrite(transcript.markdown() + "\n", to: transcriptURL(candidate))
        return Written(noteURL: noteURL(candidate), transcriptURL: transcriptURL(candidate))
    }

    /// Rewrites an existing Note/Transcript pair in place, keeping both
    /// filenames. Used when speakers are named after the fact: the title has
    /// not changed, so a new pair would just leave a stale duplicate in the
    /// Vault and break the link the user already has open.
    public func overwrite(noteURL: URL, transcriptURL: URL, session: Session,
                          noteBody: String, transcript: Transcript,
                          provider: String, costUSD: Double) throws -> Written {
        let transcriptName = transcriptURL.deletingPathExtension().lastPathComponent
        let front = frontmatter(session: session, provider: provider, costUSD: costUSD,
                                transcriptName: transcriptName)
        try atomicWrite(front + "\n" + noteBody + "\n", to: noteURL)
        try atomicWrite(transcript.markdown() + "\n", to: transcriptURL)
        return Written(noteURL: noteURL, transcriptURL: transcriptURL)
    }

    func frontmatter(session: Session, provider: String, costUSD: Double,
                     transcriptName: String) -> String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_AU")
        day.timeZone = .current
        day.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_AU")
        time.timeZone = .current
        time.dateFormat = "HH:mm"
        let participants = session.participants.isEmpty
            ? "[]"
            : "[" + session.participants.joined(separator: ", ") + "]"
        return """
        ---
        date: \(day.string(from: session.startedAt))
        start: \(time.string(from: session.startedAt))
        duration: \(Transcript.timestamp(session.recordedDuration))
        preset: \(session.presetName)
        participants: \(participants)
        provider: \(provider)
        cost: \(String(format: "%.4f", costUSD))
        transcript: "[[\(transcriptName)]]"
        ---
        """
    }

    private func atomicWrite(_ content: String, to url: URL) throws {
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}

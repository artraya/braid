import Foundation

/// What the database has to say about one Speaker.
public enum VoiceMatch: Sendable, Equatable {
    /// Nobody close enough to mention.
    case unknown
    /// Close enough to offer as a chip, not close enough to write into a Note.
    case suggestion(personID: String, name: String, score: Double)
    /// One Person, unambiguously (R23).
    case confident(personID: String, name: String, score: Double)

    public var personID: String? {
        switch self {
        case .unknown: nil
        case .suggestion(let id, _, _), .confident(let id, _, _): id
        }
    }

    public var name: String? {
        switch self {
        case .unknown: nil
        case .suggestion(_, let name, _), .confident(_, let name, _): name
        }
    }

    public var isConfident: Bool {
        if case .confident = self { return true }
        return false
    }
}

/// Resolving Speakers to Persons, and correcting the diarizer with what the
/// database already knows.
///
/// Precision-first by construction (R23): a name is written without asking only
/// when exactly one Person clears the auto bar. Two plausible Persons produce a
/// suggestion, never a guess — the cost of asking is one tap, and the cost of
/// being wrong is a filed Note that misquotes somebody.
public struct VoiceIdentifier: Sendable {
    public let config: IdentificationConfig
    /// The model that produced the vectors being compared. A database from a
    /// different one matches nothing (R30).
    public let modelVersion: String

    public init(config: IdentificationConfig = .current,
                modelVersion: String = LocalDiarizer.embeddingModelVersion) {
        self.config = config
        self.modelVersion = modelVersion
    }

    // MARK: - Matching

    /// The best a Person scores against this voice: their closest exemplar,
    /// not their average. People sound different across headsets and rooms, and
    /// averaging their exemplars would blur exactly the variety that makes a
    /// later match possible.
    func score(_ person: Person, against centroid: [Float]) -> Double {
        person.voiceprints
            .map { Vector.cosine($0.vector, centroid) }
            .max() ?? 0
    }

    public func match(_ voice: SpeakerVoice, in db: VoiceDatabase) -> VoiceMatch {
        guard !db.isStale(against: modelVersion), !voice.centroid.isEmpty else { return .unknown }

        let scored = db.persons
            .map { (person: $0, score: score($0, against: voice.centroid)) }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
        guard let best = scored.first else { return .unknown }

        // R23, literally: "exactly one Person clears the auto threshold". Two
        // people who both sound like this Speaker is precisely the situation
        // where guessing produces a confidently wrong name.
        let clearingAuto = scored.filter { $0.score >= config.autoThreshold }
        if clearingAuto.count == 1, let only = clearingAuto.first {
            return .confident(personID: only.person.id, name: only.person.name, score: only.score)
        }
        if best.score >= config.suggestThreshold {
            return .suggestion(personID: best.person.id, name: best.person.name, score: best.score)
        }
        return .unknown
    }

    /// R28: is this Remote Speaker the owner's own voice coming back through
    /// the far end? Held to the same bar as an auto-name, because folding a
    /// real participant into "Me" would lose their words from the Note.
    public func isEcho(_ voice: SpeakerVoice, in db: VoiceDatabase) -> Bool {
        guard !db.isStale(against: modelVersion), let me = db.me,
              !voice.centroid.isEmpty else { return false }
        return score(me, against: voice.centroid) >= config.autoThreshold
    }

    // MARK: - Re-attribution (R27)

    public struct Reattribution: Sendable {
        public var spans: [SpeakerSpan]
        /// How many spans changed hands, for the per-Job log.
        public var corrections: Int
        /// Labels Re-attribution introduced because a known Person was hiding
        /// inside somebody else's cluster, mapped to that Person.
        public var introduced: [String: String]
    }

    /// Moves speech the database says the diarizer misfiled.
    ///
    /// The diarizer's weakness on real calls is contamination: a short stretch
    /// of one person absorbed into another's cluster. Where a chunk's own
    /// embedding says "this is Sarah" above the auto bar and its assigned
    /// cluster does not, the database is better evidence than the clustering,
    /// and the spans inside that chunk change hands.
    ///
    /// Deliberately conservative. It never runs below the auto threshold, never
    /// invents a Person, and moves a span only when the chunk covering it
    /// disagrees with that span's *current* owner — so an unidentified cluster
    /// with nothing better to say about it stays exactly as the diarizer left
    /// it.
    public func reattribute(
        spans: [SpeakerSpan],
        chunks: [VoiceChunk],
        voices: [SpeakerVoice],
        resolved: [String: String],
        in db: VoiceDatabase
    ) -> Reattribution {
        guard !db.isStale(against: modelVersion), !chunks.isEmpty, !db.persons.isEmpty else {
            return Reattribution(spans: spans, corrections: 0, introduced: [:])
        }

        let centroids = Dictionary(uniqueKeysWithValues: voices.map { ($0.speakerId, $0.centroid) })
        // A Person already owning a cluster keeps that cluster's label, so
        // re-attributed speech joins the turns it belongs with instead of
        // becoming a second voice for the same person.
        var labelForPerson = [String: String]()
        for (speakerId, personID) in resolved { labelForPerson[personID] = speakerId }
        var introduced = [String: String]()

        var updated = spans
        var corrections = 0

        for chunk in chunks {
            guard let winner = betterOwner(for: chunk, resolved: resolved,
                                           centroids: centroids, in: db) else { continue }

            let label: String
            if let existing = labelForPerson[winner.id] {
                label = existing
            } else {
                label = "person:\(winner.id)"
                labelForPerson[winner.id] = label
                introduced[label] = winner.id
            }
            guard label != chunk.speakerId else { continue }

            for index in updated.indices {
                let span = updated[index]
                let middle = span.start + (span.end - span.start) / 2
                guard span.speakerId == chunk.speakerId,
                      middle >= chunk.start, middle < chunk.end else { continue }
                updated[index].speakerId = label
                corrections += 1
            }
        }

        // A label that ended up claiming nothing is not a speaker.
        introduced = introduced.filter { label, _ in updated.contains { $0.speakerId == label } }
        return Reattribution(spans: updated, corrections: corrections, introduced: introduced)
    }

    /// The Person this chunk belongs to, when the database is confident and the
    /// chunk's current assignment is not.
    private func betterOwner(
        for chunk: VoiceChunk,
        resolved: [String: String],
        centroids: [String: [Float]],
        in db: VoiceDatabase
    ) -> Person? {
        let scored = db.persons
            .map { (person: $0, score: score($0, against: chunk.embedding)) }
            .filter { $0.score >= config.autoThreshold }
            .sorted { $0.score > $1.score }
        // Same tie rule as naming: two candidates is not evidence.
        guard scored.count == 1, let candidate = scored.first else { return nil }

        if let ownerID = resolved[chunk.speakerId] {
            guard ownerID != candidate.person.id else { return nil }
            // The cluster has an identified owner, and this chunk does not
            // sound like them.
            guard let owner = db.person(id: ownerID),
                  score(owner, against: chunk.embedding) < config.autoThreshold else { return nil }
            return candidate.person
        }

        // No identified owner: the chunk has to beat its own cluster's centroid
        // by a margin before the database gets to overrule the clustering.
        guard let own = centroids[chunk.speakerId] else { return candidate.person }
        let ownScore = Vector.cosine(own, chunk.embedding)
        guard candidate.score - ownScore > config.reattributionMargin else { return nil }
        return candidate.person
    }
}

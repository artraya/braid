import Foundation
import os

/// The Voice Database on disk: one encrypted file, read once and written on
/// every change (R21, ADR-0007).
///
/// An actor because the Job pipeline enrolls while the Settings panel is
/// listing and forgetting. It is kilobytes of data — dozens of Persons at ten
/// 256-float exemplars each — so the whole thing lives in memory and every
/// write is a full rewrite. No database engine, nothing to migrate, and
/// "delete everything" is one `removeItem`.
public actor VoiceStore {
    public static let defaultURL = JobQueue.appSupportURL
        .appendingPathComponent("voices.dat")

    let url: URL
    let box: SecretBox
    let config: IdentificationConfig
    /// Which embedding model this app build produces vectors with (R30).
    let modelVersion: String
    let log = Logger(subsystem: "no.braid.app", category: "voices")

    var db: VoiceDatabase

    public init(url: URL = VoiceStore.defaultURL,
                box: SecretBox = SecretBox(),
                config: IdentificationConfig = .current,
                modelVersion: String = LocalDiarizer.embeddingModelVersion) {
        self.url = url
        self.box = box
        self.config = config
        self.modelVersion = modelVersion
        self.db = VoiceDatabase(embeddingModelVersion: modelVersion)

        guard let data = try? Data(contentsOf: url) else { return }
        do {
            let plain = try box.open(data)
            self.db = try JSONDecoder().decode(VoiceDatabase.self, from: plain)
        } catch {
            // The file exists but this Mac's key cannot read it — a restored
            // backup from another machine, or a destroyed key. There is nothing
            // to recover, and quietly pretending the database was empty would
            // be the wrong kind of quiet, so say so and start fresh.
            log.error("voice database present but unreadable (\(error.localizedDescription, privacy: .public)); starting empty")
        }
    }

    // MARK: - Reading

    public func database() -> VoiceDatabase { db }
    public func persons() -> [Person] { db.persons.sorted { $0.name < $1.name } }
    public func isEmpty() -> Bool { db.persons.isEmpty }
    /// R30: true when stored vectors came from a different embedding model, so
    /// nothing may be matched until people are named again.
    public func isStale() -> Bool { db.isStale(against: modelVersion) }

    /// Recently heard Persons, newest first — the naming flow's fallback chips
    /// when no voice matched.
    public func recentlyHeard(limit: Int = 6) -> [Person] {
        db.persons
            .filter { $0.lastHeardAt != nil }
            .sorted { ($0.lastHeardAt ?? .distantPast) > ($1.lastHeardAt ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Enrollment (R24)

    /// Naming is teaching: the confirmed Speaker's centroid becomes a
    /// Voiceprint of the Person with that name, creating them if this is the
    /// first time. Returns the Person so the caller can bind the label.
    ///
    /// A Speaker who barely spoke teaches nothing reliable, so its centroid is
    /// not enrolled — the name still applies to the Transcript, it just does
    /// not go into the database as evidence.
    @discardableResult
    public func enroll(_ voice: SpeakerVoice?, as name: String) -> Person? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        migrateIfStale()

        var person = db.person(named: trimmed) ?? Person(name: trimmed)
        person.lastHeardAt = Date()
        if let voice, voice.seconds >= config.minSecondsToEnroll, !voice.centroid.isEmpty {
            person.voiceprints.append(voice.asVoiceprint)
            // Oldest out. Recent exemplars track how someone sounds now —
            // this headset, this room — better than their first ever.
            if person.voiceprints.count > config.voiceprintCap {
                person.voiceprints.sort { $0.heardAt < $1.heardAt }
                person.voiceprints.removeFirst(person.voiceprints.count - config.voiceprintCap)
            }
        }
        upsert(person)
        save()
        log.notice("enrolled \(person.voiceprints.count) voiceprint(s) for a person")
        return person
    }

    /// R28: the owner's own voice, learned from the Mic Track, which is one
    /// speaker structurally and therefore the only voice Braid knows without
    /// being told. Used solely to recognise echo.
    public func enrollMe(_ voice: SpeakerVoice) {
        guard voice.seconds >= config.minSecondsToEnroll, !voice.centroid.isEmpty else { return }
        migrateIfStale()
        var me = db.me ?? Person(name: "Me")
        me.voiceprints.append(voice.asVoiceprint)
        me.lastHeardAt = Date()
        if me.voiceprints.count > config.voiceprintCap {
            me.voiceprints.sort { $0.heardAt < $1.heardAt }
            me.voiceprints.removeFirst(me.voiceprints.count - config.voiceprintCap)
        }
        db.me = me
        save()
    }

    /// Undoes what a wrong suggestion taught. The Voiceprint that scored the
    /// bad match is the one closest to the Speaker that was misnamed, so that
    /// is the one that goes.
    public func removeVoiceprint(from personID: String, nearest voice: SpeakerVoice) {
        guard var person = db.person(id: personID), !person.voiceprints.isEmpty else { return }
        let scored = person.voiceprints.enumerated()
            .max { Vector.cosine($0.element.vector, voice.centroid)
                 < Vector.cosine($1.element.vector, voice.centroid) }
        guard let worst = scored?.offset else { return }
        person.voiceprints.remove(at: worst)
        upsert(person)
        save()
        log.notice("removed the voiceprint behind a corrected name")
    }

    public func markHeard(_ personIDs: [String]) {
        guard !personIDs.isEmpty else { return }
        let now = Date()
        for id in personIDs {
            guard var person = db.person(id: id) else { continue }
            person.lastHeardAt = now
            upsert(person)
        }
        save()
    }

    // MARK: - The user's controls (R29)

    public func rename(personID: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, var person = db.person(id: personID) else { return }
        person.name = trimmed
        upsert(person)
        save()
    }

    /// Forgets a Person entirely, Voiceprints and all. Notes already written
    /// keep their names — this is about what Braid may recognise next time.
    public func forget(personID: String) {
        db.persons.removeAll { $0.id == personID }
        save()
        log.notice("forgot a person and every voiceprint of them")
    }

    /// Deletes the database and the key that reads it. Nothing recoverable.
    public func deleteEverything() {
        db = VoiceDatabase(embeddingModelVersion: modelVersion)
        try? FileManager.default.removeItem(at: url)
        box.destroyKey()
        log.notice("voice database deleted at the user's request")
    }

    /// The deliberate readable egress (R29): plain JSON, written only when the
    /// user asks, to wherever they choose.
    public func export(to destination: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(db).write(to: destination, options: .atomic)
        log.notice("voice database exported at the user's request")
    }

    /// Restores an export, replacing what is here. Rejects a file from a
    /// different embedding model rather than mixing incomparable vectors.
    public func importDatabase(from source: URL) throws {
        let data = try Data(contentsOf: source)
        let incoming = try JSONDecoder().decode(VoiceDatabase.self, from: data)
        guard !incoming.isStale(against: modelVersion) else {
            throw SecretBox.Failure.unreadable
        }
        db = incoming
        save()
        log.notice("voice database imported, \(self.db.persons.count) people")
    }

    // MARK: - Internals

    /// R30: vectors from a superseded embedding model are not comparable to
    /// today's, so the first write under a new model keeps the people and drops
    /// their exemplars. Names survive as suggestion chips; matching restarts
    /// from nothing, which is exactly what "re-enroll through ordinary naming"
    /// means.
    private func migrateIfStale() {
        guard db.isStale(against: modelVersion) else { return }
        log.notice("embedding model changed; dropping stale voiceprints, keeping names")
        db.persons = db.persons.map {
            var person = $0
            person.voiceprints = []
            return person
        }
        db.me = nil
        db.embeddingModelVersion = modelVersion
    }

    private func upsert(_ person: Person) {
        if let index = db.persons.firstIndex(where: { $0.id == person.id }) {
            db.persons[index] = person
        } else {
            db.persons.append(person)
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let plain = try JSONEncoder().encode(db)
            try box.seal(plain).write(to: url, options: .atomic)
        } catch {
            log.error("could not write the voice database: \(error.localizedDescription, privacy: .public)")
        }
    }
}

import Foundation
import Testing
@testable import MsNotesCore

// MARK: - Merge rule (SPEC Architecture)

@Test func mergeInterleavesByStartAndRelabelsSpeakers() {
    let mic = [
        Utterance(speaker: "A", start: 0.0, end: 2.0, text: "Hello from me"),
        Utterance(speaker: "A", start: 10.0, end: 12.0, text: "Me again"),
    ]
    let remote = [
        Utterance(speaker: "B", start: 3.0, end: 5.0, text: "First remote"),
        Utterance(speaker: "A", start: 6.0, end: 8.0, text: "Second remote"),
        Utterance(speaker: "B", start: 13.0, end: 14.0, text: "First remote again"),
    ]
    let t = mergeTranscripts(mic: mic, remote: remote, pauseSpans: [])
    #expect(t.utterances.map(\.speaker) == ["Me", "Speaker 1", "Speaker 2", "Me", "Speaker 1"])
    #expect(t.utterances.map(\.text) == [
        "Hello from me", "First remote", "Second remote", "Me again", "First remote again"])
    #expect(t.remoteSpeakers == ["Speaker 1", "Speaker 2"])
}

@Test func mergeNumbersRemoteSpeakersByFirstAppearance() {
    // Provider labels arrive as B-first; canonical numbering follows time.
    let remote = [
        Utterance(speaker: "B", start: 1, end: 2, text: "early"),
        Utterance(speaker: "A", start: 5, end: 6, text: "late"),
    ]
    let t = mergeTranscripts(mic: [], remote: remote, pauseSpans: [])
    #expect(t.utterances[0].speaker == "Speaker 1")
    #expect(t.utterances[1].speaker == "Speaker 2")
}

// MARK: - Transcript markdown (SPEC Transcript format, R3)

@Test func markdownFormatsUtterancesAndPauseMarker() {
    let t = Transcript(
        utterances: [
            Utterance(speaker: "Me", start: 0, end: 2, text: "Hi"),
            Utterance(speaker: "Speaker 1", start: 65, end: 70, text: "Hello"),
        ],
        pauseSpans: [.init(atRecordedSeconds: 30, wallGapSeconds: 252)])
    let md = t.markdown()
    #expect(md.contains("- **00:00:00 Me:** Hi"))
    #expect(md.contains("- **00:01:05 Speaker 1:** Hello"))
    #expect(md.contains("[recording paused — 4m 12s]"))
    // Marker sits between the utterances (position 30s).
    let lines = md.components(separatedBy: "\n").filter { !$0.isEmpty }
    #expect(lines[1].contains("recording paused"))
}

@Test func gapFormatting() {
    #expect(Transcript.gap(37) == "37s")
    #expect(Transcript.gap(252) == "4m 12s")
    #expect(Transcript.gap(3723) == "1h 2m 3s")
    #expect(Transcript.gap(0) == "0s")
}

// MARK: - Note filename (R9)

@Test func titleSanitisation() {
    #expect(VaultWriter.sanitizeTitle("a/b\\c:d#e^f[g]h|i") == "a-b-c-d-e-f-g-h-i")
    #expect(VaultWriter.sanitizeTitle("  ") == "Untitled")
    #expect(VaultWriter.sanitizeTitle("Project Sync") == "Project Sync")
}

@Test func baseNameUsesSessionStartLocalTime() {
    var comps = DateComponents()
    comps.year = 2026; comps.month = 7; comps.day = 31; comps.hour = 14; comps.minute = 30
    let date = Calendar.current.date(from: comps)!
    #expect(VaultWriter.baseName(startedAt: date, title: "Project Sync")
            == "2026-07-31 1430 Project Sync")
}

@Test func collisionAppendsLowestFreeInteger() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("vault-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let writer = VaultWriter(vaultURL: dir)
    let session = Session(title: "Sync", presetName: "Meeting", participants: [],
                          startedAt: Date(timeIntervalSince1970: 1_790_000_000),
                          recordedDuration: 60)
    let t = Transcript(utterances: [Utterance(speaker: "Me", start: 0, end: 1, text: "x")])
    let first = try writer.write(session: session, noteBody: "# A", transcript: t,
                                 provider: "assemblyai", costUSD: 0.1)
    let second = try writer.write(session: session, noteBody: "# B", transcript: t,
                                  provider: "assemblyai", costUSD: 0.1)
    let third = try writer.write(session: session, noteBody: "# C", transcript: t,
                                 provider: "assemblyai", costUSD: 0.1)
    let base = first.noteURL.deletingPathExtension().lastPathComponent
    #expect(second.noteURL.deletingPathExtension().lastPathComponent == "\(base) 2")
    #expect(third.noteURL.deletingPathExtension().lastPathComponent == "\(base) 3")
    // Transcript names track the Note's suffix.
    #expect(third.transcriptURL.lastPathComponent == "\(base) 3 (transcript).md")
}

// MARK: - Frontmatter (R10)

@Test func frontmatterCarriesAllRequiredKeys() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("vault-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let writer = VaultWriter(vaultURL: dir)
    let session = Session(title: "Sync", presetName: "Meeting",
                          participants: ["Sarah", "Tom"],
                          startedAt: Date(), recordedDuration: 2832)
    let t = Transcript(utterances: [Utterance(speaker: "Me", start: 0, end: 1, text: "x")])
    let written = try writer.write(session: session, noteBody: "# Note", transcript: t,
                                   provider: "assemblyai", costUSD: 0.1234)
    let note = try String(contentsOf: written.noteURL, encoding: .utf8)
    for key in ["date:", "start:", "duration: 00:47:12", "preset: Meeting",
                "participants: [Sarah, Tom]", "provider: assemblyai",
                "cost: 0.1234", "transcript: \"[["] {
        #expect(note.contains(key), "missing \(key)")
    }
    #expect(note.contains("(transcript)]]\""))
}

// MARK: - Presets (R11, R12)

@Test func allFourPresetsShipAndEmbedTheNamingRule() {
    #expect(Preset.defaults.map(\.name) == ["Meeting", "Lecture", "Interview", "Training"])
    for preset in Preset.defaults {
        #expect(preset.prompt.contains(Preset.namingRule), "\(preset.name) missing R11 rule")
    }
}

// MARK: - Cost (R14)

@Test func costMatchesRateTable() {
    let table = CostTable.current
    // 1h Session = 1h plain Mic Track + 1h diarized Remote Track, keyterms on both.
    let stt = table.sttCost(trackHours: 1, diarized: false, keyterms: true)
        + table.sttCost(trackHours: 1, diarized: true, keyterms: true)
    #expect(abs(stt - (0.26 + 0.28)) < 0.0001)
    let claude = table.claudeCost(inputTokens: 10_000, outputTokens: 2_000)
    #expect(abs(claude - (0.05 + 0.05)) < 0.0001)
}

// MARK: - AssemblyAI response mapping

@Test func adapterMapsDiarizedUtterances() {
    let json: [String: Any] = [
        "status": "completed",
        "utterances": [
            ["speaker": "B", "start": 32.0, "end": 5082.0, "text": "Hi there"],
            ["speaker": "A", "start": 5082.0, "end": 6610.0, "text": "Hello"],
        ],
    ]
    let utterances = AssemblyAIAdapter.utterances(from: json)
    #expect(utterances.count == 2)
    #expect(utterances[0].speaker == "B")
    #expect(abs(utterances[0].start - 0.032) < 0.001)
    #expect(utterances[1].text == "Hello")
}

@Test func adapterFallsBackToPlainText() {
    let json: [String: Any] = ["status": "completed", "text": "just words",
                               "audio_duration": 5.0]
    let utterances = AssemblyAIAdapter.utterances(from: json)
    #expect(utterances.count == 1)
    #expect(utterances[0].text == "just words")
}

// MARK: - Error taxonomy (Journey step 8)

@Test func errorClassification() {
    #expect(PipelineError.classify(status: 500, body: "", context: "x").isTransient)
    #expect(PipelineError.classify(status: 429, body: "", context: "x").isTransient)
    #expect(!PipelineError.classify(status: 401, body: "", context: "x").isTransient)
    #expect(!PipelineError.classify(status: 400, body: "", context: "x").isTransient)
    let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
    #expect(PipelineError.classify(transport: offline, context: "x").isTransient)
}

// MARK: - Provider request parameters (R6)

@Test func remoteTrackRequestCarriesLanguageAndKeyterms() {
    let body = AssemblyAIAdapter.requestBody(
        audioURL: "https://example/x", diarize: true,
        keyTerms: ["Acme Geo", "SlopeWatch"])
    #expect(body["language_code"] as? String == "en_au")
    #expect(body["speech_models"] as? [String] == ["universal-3-5-pro"])
    #expect(body["speaker_labels"] as? Bool == true)
    #expect(body["keyterms_prompt"] as? [String] == ["Acme Geo", "SlopeWatch"])
}

@Test func micTrackRequestIsUndiarized() {
    let body = AssemblyAIAdapter.requestBody(
        audioURL: "https://example/x", diarize: false, keyTerms: [])
    #expect(body["language_code"] as? String == "en_au")
    #expect(body["speaker_labels"] as? Bool == false)
    #expect(body["keyterms_prompt"] == nil)
}

/// R6: no request may cap the speaker count. Capping it at Participants+1 meant
/// a late joiner was folded into an existing speaker.
@Test func noRequestEverConstrainsTheSpeakerCount() {
    for diarize in [true, false] {
        let body = AssemblyAIAdapter.requestBody(
            audioURL: "https://example/x", diarize: diarize, keyTerms: ["Acme Geo"])
        #expect(body["speaker_options"] == nil)
        #expect(body["speakers_expected"] == nil)
    }
}

// MARK: - Speaker stats and renaming

@Test func speakerStatsRankByTalkTimeAndSampleTheLongestLine() {
    let t = Transcript(utterances: [
        Utterance(speaker: "Me", start: 0, end: 30, text: "my long opening"),
        Utterance(speaker: "Speaker 1", start: 30, end: 32, text: "yeah"),
        Utterance(speaker: "Speaker 2", start: 32, end: 52, text: "a considered point"),
        Utterance(speaker: "Speaker 1", start: 52, end: 55, text: "quick follow up"),
    ])
    let stats = t.remoteSpeakerStats()
    // "Me" is never offered for naming.
    #expect(stats.map(\.speaker) == ["Speaker 2", "Speaker 1"])
    #expect(abs(stats[0].totalSeconds - 20) < 0.001)
    #expect(stats[1].utteranceCount == 2)
    // Longest utterance, not the first, identifies a voice best.
    #expect(stats[1].sample == "quick follow up")
    #expect(abs(stats[1].firstAt - 30) < 0.001)
}

@Test func speakerStatsTruncateLongSamples() {
    let t = Transcript(utterances: [
        Utterance(speaker: "Speaker 1", start: 0, end: 5, text: String(repeating: "a", count: 300)),
    ])
    let sample = t.remoteSpeakerStats(sampleLimit: 20)[0].sample
    #expect(sample.count == 21)
    #expect(sample.hasSuffix("…"))
}

@Test func renamingAppliesNamesButNeverTouchesMe() {
    let t = Transcript(utterances: [
        Utterance(speaker: "Me", start: 0, end: 1, text: "a"),
        Utterance(speaker: "Speaker 1", start: 1, end: 2, text: "b"),
        Utterance(speaker: "Speaker 2", start: 2, end: 3, text: "c"),
        Utterance(speaker: "Speaker 3", start: 3, end: 4, text: "d"),
    ])
    let renamed = t.renamingSpeakers([
        "Speaker 1": "Sarah",
        "Speaker 2": "   ",     // blank: left alone
        "Me": "Someone Else",   // R11: ignored
    ])
    #expect(renamed.utterances.map(\.speaker) == ["Me", "Sarah", "Speaker 2", "Speaker 3"])
}

// MARK: - Auto-end detection

/// Feeds a detector a sequence of (secondsFromStart, callAppHoldingMic) and
/// returns the offsets at which it judged the call to have ended.
private func firings(_ detector: inout CallEndDetector,
                     _ samples: [(TimeInterval, Bool)]) -> [TimeInterval] {
    let start = Date(timeIntervalSince1970: 1_790_000_000)
    var fired: [TimeInterval] = []
    for (offset, holding) in samples {
        if detector.update(callAppHoldingMic: holding,
                           now: start.addingTimeInterval(offset)) {
            fired.append(offset)
        }
    }
    return fired
}

@Test func autoEndNeverFiresWithoutACallAppFirst() {
    // Dictating into a quiet room: no call app ever takes the mic.
    var detector = CallEndDetector(grace: 15)
    let samples = stride(from: 0.0, through: 600, by: 2).map { ($0, false) }
    #expect(firings(&detector, samples).isEmpty)
    #expect(!detector.armed)
}

@Test func autoEndFiresOnceAfterTheGracePeriod() {
    var detector = CallEndDetector(grace: 15)
    var samples: [(TimeInterval, Bool)] = stride(from: 0.0, to: 60, by: 2).map { ($0, true) }
    samples += stride(from: 60.0, through: 120, by: 2).map { ($0, false) }
    let fired = firings(&detector, samples)
    // Released at 60, so it fires on the first sample at or past 75.
    #expect(fired == [76])
    #expect(!detector.armed)
}

@Test func autoEndRidesOutAReconnect() {
    var detector = CallEndDetector(grace: 15)
    var samples: [(TimeInterval, Bool)] = [(0, true), (2, true)]
    // Teams drops for 8 seconds and comes back: shorter than the grace period.
    samples += [(4, false), (6, false), (8, false), (10, false), (12, true), (14, true)]
    #expect(firings(&detector, samples).isEmpty)
    #expect(detector.armed)
}

@Test func keepRecordingDisarmsUntilTheNextCall() {
    var detector = CallEndDetector(grace: 15)
    _ = firings(&detector, [(0, true), (2, true)])

    // The user says keep recording while the app is still off the mic.
    detector.reset()
    #expect(firings(&detector, stride(from: 4.0, through: 300, by: 2).map { ($0, false) }).isEmpty)

    // A fresh call arms it again, and ending that one does fire.
    var samples: [(TimeInterval, Bool)] = [(302, true), (304, true)]
    samples += stride(from: 306.0, through: 340, by: 2).map { ($0, false) }
    #expect(firings(&detector, samples) == [322])
}

@Test func callAppMatchingCoversHelpersAndVersionedBundles() {
    // Browsers and Electron apps open the mic from a helper process.
    #expect(CallWatcher.matches("com.google.Chrome.helper", watched: "com.google.Chrome"))
    #expect(CallWatcher.matches("com.microsoft.edgemac.helper", watched: "com.microsoft.edgemac"))
    #expect(CallWatcher.matches("com.microsoft.teams", watched: "com.microsoft.teams"))
    // The current Teams client is "teams2".
    #expect(CallWatcher.matches("com.microsoft.teams2", watched: "com.microsoft.teams"))
    // A prefix must not swallow an unrelated app.
    #expect(!CallWatcher.matches("com.google.ChromeRemoteDesktop", watched: "com.google.Chrome"))
    #expect(!CallWatcher.matches("us.zoom.xos", watched: "com.apple.Safari"))
}

// MARK: - Display formatting

@Test func durationAndClockFormatting() {
    #expect(Format.duration(252) == "4:12")
    #expect(Format.duration(1720) == "28:40")
    #expect(Format.duration(3063) == "51:03")
    #expect(Format.duration(3723) == "1:02:03")
    #expect(Format.duration(0) == "0:00")
    // The HUD clock is fixed width so it does not jitter as it counts.
    #expect(Format.clock(0) == "00:00:00")
    #expect(Format.clock(736) == "00:12:16")
    #expect(Format.clock(3723) == "01:02:03")
    #expect(Format.clock(-5) == "00:00:00")
}

@Test func relativeDayFormatting() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Australia/Perth")!
    func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }
    let now = at(2026, 7, 31, 14, 0)   // a Friday
    #expect(Format.when(at(2026, 7, 31, 9, 14), now: now, calendar: calendar) == "Today 09:14")
    #expect(Format.when(at(2026, 7, 30, 8, 47), now: now, calendar: calendar) == "Yesterday 08:47")
    #expect(Format.when(at(2026, 7, 29, 10, 0), now: now, calendar: calendar) == "Wed")
    // Past a week, a weekday name stops telling you which week it was.
    #expect(Format.when(at(2026, 7, 3, 10, 0), now: now, calendar: calendar) == "3 Jul")
}

@Test func moneyFormatting() {
    #expect(Format.money(4.823) == "$4.82")
    #expect(Format.money(0) == "$0.00")
}

// MARK: - Waveform levels

@Test func levelMeterBucketsPeaksIntoBarsOldestFirst() {
    let meter = LevelMeter()
    meter.configure(sampleRate: 1000)   // 50 ms bars -> 50 frames per bar

    // Nothing recorded yet: silence, not garbage.
    #expect(meter.recent(4) == [0, 0, 0, 0])

    // One bar's worth in two callbacks keeps the louder of the two.
    meter.push(peak: 0.2, frames: 25)
    #expect(meter.recent(4) == [0, 0, 0, 0])   // bar not closed yet
    meter.push(peak: 0.8, frames: 25)
    #expect(meter.recent(4) == [0, 0, 0, 0.8])

    meter.push(peak: 0.4, frames: 50)
    #expect(meter.recent(4) == [0, 0, 0.8, 0.4])
    // The window resets, so a quiet bar reads quiet rather than holding the peak.
    meter.push(peak: 0.1, frames: 50)
    #expect(meter.recent(2) == [0.4, 0.1])
}

@Test func levelMeterWrapsAndResets() {
    let meter = LevelMeter()
    meter.configure(sampleRate: 1000)
    for i in 0..<(LevelMeter.capacity + 10) {
        meter.push(peak: Float(i % 10) / 10, frames: 50)
    }
    let recent = meter.recent(3)
    #expect(recent.count == 3)
    // Newest bar is the last one pushed.
    let last = Float((LevelMeter.capacity + 9) % 10) / 10
    #expect(abs(recent[2] - last) < 0.0001)

    meter.reset()
    #expect(meter.recent(8).allSatisfy { $0 == 0 })
}

// MARK: - Session history and usage

private func makeIndex() -> (SessionIndex, URL) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sessions-test-\(UUID().uuidString)")
        .appendingPathComponent("sessions.json")
    return (SessionIndex(url: url), url.deletingLastPathComponent())
}

private func record(_ title: String, at date: Date, minutes: Double,
                    cost: Double = 0) -> SessionRecord {
    SessionRecord(id: UUID().uuidString, title: title, presetName: "Meeting",
                  startedAt: date, recordedDuration: minutes * 60, costUSD: cost,
                  notePath: "/tmp/\(title).md")
}

@Test func sessionIndexKeepsNewestFirstAndTrimsTheTail() throws {
    let (index, dir) = makeIndex()
    defer { try? FileManager.default.removeItem(at: dir) }

    let now = Date()
    index.add(record("older", at: now.addingTimeInterval(-3600), minutes: 10))
    index.add(record("newer", at: now, minutes: 5))
    #expect(index.all().map(\.title) == ["newer", "older"])

    for i in 0..<SessionIndex.limit {
        index.add(record("bulk \(i)", at: now, minutes: 1))
    }
    #expect(index.all().count == SessionIndex.limit)
    #expect(index.all().first?.title == "bulk \(SessionIndex.limit - 1)")
}

@Test func usageCountsThisMonthOnly() throws {
    let (index, dir) = makeIndex()
    defer { try? FileManager.default.removeItem(at: dir) }

    let calendar = Calendar.current
    let now = Date()
    let lastMonth = calendar.date(byAdding: .month, value: -1, to: now)!
    index.add(record("this month", at: now, minutes: 90, cost: 1.20))
    index.add(record("also this month", at: now, minutes: 30, cost: 0.40))
    index.add(record("last month", at: lastMonth, minutes: 500, cost: 9.99))

    let usage = index.usage(minuteCap: 600, now: now)
    #expect(abs(usage.minutesUsed - 120) < 0.001)
    #expect(abs(usage.costUSD - 1.60) < 0.001)
    #expect(abs(usage.fraction - 0.2) < 0.001)
    #expect(!usage.isNearCap)
    #expect(!usage.isOverCap)
}

@Test func usageFlagsTheCapWithoutEverBlocking() {
    let near = Usage(minutesUsed: 480, minuteCap: 600, costUSD: 5, daysLeftInMonth: 3)
    #expect(near.isNearCap)
    #expect(!near.isOverCap)

    let over = Usage(minutesUsed: 700, minuteCap: 600, costUSD: 8, daysLeftInMonth: 1)
    #expect(over.isOverCap)
    // The bar saturates rather than overflowing.
    #expect(over.fraction == 1)

    // A cap of zero means no cap; never divide by it.
    let uncapped = Usage(minutesUsed: 100, minuteCap: 0, costUSD: 1, daysLeftInMonth: 5)
    #expect(uncapped.fraction == 0)
    #expect(!uncapped.isOverCap)
}

@Test func daysLeftCountsTodayAndResetsOnTheFirst() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Australia/Perth")!
    func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }
    // July has 31 days.
    #expect(SessionIndex.daysLeftInMonth(now: day(2026, 7, 1), calendar: calendar) == 31)
    #expect(SessionIndex.daysLeftInMonth(now: day(2026, 7, 13), calendar: calendar) == 19)
    #expect(SessionIndex.daysLeftInMonth(now: day(2026, 7, 31), calendar: calendar) == 1)
    // February 2028 is a leap year.
    #expect(SessionIndex.daysLeftInMonth(now: day(2028, 2, 1), calendar: calendar) == 29)
}

@Test func namingAddsToASessionsCostWithoutDuplicatingIt() throws {
    let (index, dir) = makeIndex()
    defer { try? FileManager.default.removeItem(at: dir) }

    let entry = record("Client call", at: Date(), minutes: 30, cost: 0.54)
    index.add(entry)
    index.addCost(0.10, toSessionID: entry.id)

    #expect(index.all().count == 1)
    #expect(abs((index.all().first?.costUSD ?? 0) - 0.64) < 0.001)

    // An unknown id is ignored rather than creating a phantom entry.
    index.addCost(5, toSessionID: "nope")
    #expect(index.all().count == 1)
    #expect(abs((index.all().first?.costUSD ?? 0) - 0.64) < 0.001)
}

// MARK: - Naming records

@Test func transcriptStoreRoundTripsAndPurges() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("transcripts-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TranscriptStore(root: dir)

    let session = Session(title: "Sync", presetName: "Meeting", participants: [],
                          startedAt: Date(), recordedDuration: 60)
    let t = Transcript(utterances: [Utterance(speaker: "Speaker 1", start: 0, end: 1, text: "x")])
    let record = NamingRecord(session: session, transcript: t, provider: "assemblyai",
                              costUSD: 0.5, notePath: "/tmp/n.md",
                              transcriptPath: "/tmp/t.md", noteHash: "abc")
    store.save(record)

    let loaded = try #require(store.load(session.id))
    #expect(loaded.transcript == t)
    #expect(loaded.namesApplied == false)
    #expect(store.all().count == 1)

    // Inside the window it survives; past it, it goes.
    store.purgeExpired(now: record.completedAt.addingTimeInterval(TranscriptStore.retention - 60))
    #expect(store.all().count == 1)
    store.purgeExpired(now: record.completedAt.addingTimeInterval(TranscriptStore.retention + 60))
    #expect(store.all().isEmpty)
}

@Test func overwriteKeepsBothFilenamesAndRelinksTranscript() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("vault-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let writer = VaultWriter(vaultURL: dir)
    var session = Session(title: "Sync", presetName: "Meeting", participants: [],
                          startedAt: Date(timeIntervalSince1970: 1_790_000_000),
                          recordedDuration: 60)
    let before = Transcript(utterances: [
        Utterance(speaker: "Speaker 1", start: 0, end: 1, text: "hello"),
    ])
    let first = try writer.write(session: session, noteBody: "# Before", transcript: before,
                                 provider: "assemblyai", costUSD: 0.1)

    session.participants = ["Sarah"]
    let after = before.renamingSpeakers(["Speaker 1": "Sarah"])
    let second = try writer.overwrite(
        noteURL: first.noteURL, transcriptURL: first.transcriptURL, session: session,
        noteBody: "# After", transcript: after, provider: "assemblyai", costUSD: 0.2)

    #expect(second.noteURL == first.noteURL)
    // No stray duplicate left behind.
    let notes = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "md" }
    #expect(notes.count == 1)

    let note = try String(contentsOf: second.noteURL, encoding: .utf8)
    #expect(note.contains("# After"))
    #expect(note.contains("participants: [Sarah]"))
    #expect(note.contains("cost: 0.2000"))
    // The wikilink still points at the transcript that was actually rewritten.
    let transcriptName = first.transcriptURL.deletingPathExtension().lastPathComponent
    #expect(note.contains("transcript: \"[[\(transcriptName)]]\""))
    let body = try String(contentsOf: second.transcriptURL, encoding: .utf8)
    #expect(body.contains("Sarah:** hello"))
}

import Foundation
import BraidCore
import BraidMLX

func eprintLine(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

// Headless verification modes (used by R-checks; see SPEC.md Requirements).
// Returns true when a CLI mode ran (the SwiftUI shell must not launch).
func runCLI() -> Bool {
    let args = CommandLine.arguments

if args.contains("--ui-preview") {
    // Layout check for the panel; invents its own data, touches nothing.
    let directory = args.firstIndex(of: "--snapshot").flatMap { i in
        args.count > i + 1 ? args[i + 1] : nil
    }
    MainActor.assumeIsolated { UIPreview.run(snapshotDirectory: directory) }
}

if let i = args.firstIndex(of: "--local-check") {
    // --local-check <audio> [--reference <json>] [--engine apple|parakeet]
    //               [--min-turn N] [--step N] [--zero-vote]
    guard args.count > i + 1 else {
        eprintLine("usage: --local-check <audio> [--reference <json>] [--engine apple|parakeet] [--min-turn N] [--step N] [--zero-vote]")
        exit(2)
    }
    let audio = URL(fileURLWithPath: args[i + 1])
    let reference = args.firstIndex(of: "--reference").flatMap { r in
        args.count > r + 1 ? URL(fileURLWithPath: args[r + 1]) : nil
    }
    let engine = args.firstIndex(of: "--engine")
        .flatMap { e in args.count > e + 1 ? LocalEngine(rawValue: args[e + 1]) : nil } ?? .apple
    // Defaults track LocalDiarizer's, so an unflagged run measures what
    // actually ships rather than a configuration nobody uses.
    let minTurn = args.firstIndex(of: "--min-turn")
        .flatMap { m in args.count > m + 1 ? Double(args[m + 1]) : nil } ?? 0.4
    let step = args.firstIndex(of: "--step")
        .flatMap { s in args.count > s + 1 ? Double(args[s + 1]) : nil } ?? 0.1
    let zeroVote = args.contains("--zero-vote")
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var code: Int32 = 1
    Task {
        code = await LocalCheck.run(audio: audio, reference: reference, engine: engine,
                                    minTurn: minTurn, step: step, zeroVoteReembed: zeroVote)
        semaphore.signal()
    }
    semaphore.wait()
    exit(code)
}

if let i = args.firstIndex(of: "--summary-check") {
    // --summary-check <text-file>  runs one plain-text transcript through the
    // Summariser. Exists because the on-device model's safety filters decline
    // whole sessions over ordinary conversation, and the only way to know
    // whether a given recording will summarise is to ask it.
    guard args.count > i + 1,
          let text = try? String(contentsOfFile: args[i + 1], encoding: .utf8) else {
        eprintLine("usage: --summary-check <text-file>")
        exit(2)
    }
    if let problem = AppleSummariser.availability {
        eprintLine(problem)
        exit(1)
    }
    AppleSummariser.verbose = true
    MLXSummariser.verbose = true
    let probing = args.contains("--probe")
    // --mlx [model-id] summarises with the open-weights model instead, which is
    // the whole point of it existing: a session Apple refuses on subject should
    // come out normally here.
    let mlxModel: MLXSummariser.Model? = args.firstIndex(of: "--mlx").map { i in
        (args.count > i + 1 ? MLXSummariser.Model(rawValue: args[i + 1]) : nil) ?? .qwen3_4b
    }
    let utterances = text.split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .enumerated()
        .map { index, line in
            Utterance(speaker: index.isMultiple(of: 2) ? "Speaker 1" : "Me",
                      start: Double(index) * 10, end: Double(index) * 10 + 9, text: line)
        }
    let startedAt = Date()
    let session = Session(title: Session.placeholderTitle(at: startedAt),
                          presetName: "Meeting",
                          participants: [], startedAt: startedAt,
                          recordedDuration: Double(utterances.count) * 10,
                          autoTitled: true)
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var code: Int32 = 1
    Task {
        if probing {
            print("probing which shapes this text will summarise in:")
            for line in await AppleSummariser.probe(
                transcript: Transcript(utterances: utterances), preset: Preset.defaults[0]) {
                print(line)
            }
            code = 0
            semaphore.signal()
            return
        }
        do {
            let summariser: any NoteSummarising = mlxModel.map { MLXSummariser(model: $0) }
                ?? AppleSummariser()
            if let mlxModel {
                print("engine: \(mlxModel.label) (~\(mlxModel.approximateGB)GB), first run downloads it")
            }
            let output = try await summariser.summarise(
                transcript: Transcript(utterances: utterances), session: session,
                preset: Preset.defaults[0])
            let declined = output.noteBody == AppleSummariser.declinedBody
            print(declined ? "DECLINED — the model refused this content"
                           : "SUMMARISED")
            // The title is what the Note gets filed as (R9a), so a diagnostic
            // run has to show it — and show when there wasn't one, since that
            // is the case where the filename falls back to the time of day.
            print("title: " + (output.title.map { "\"\($0)\"" }
                               ?? "none — the note keeps \"\(session.title)\""))
            print("")
            print(output.noteBody)
            code = declined ? 1 : 0
        } catch {
            print("FAILED: \(error)")
        }
        semaphore.signal()
    }
    semaphore.wait()
    exit(code)
}

if args.contains("--voices") {
    // What Braid can recognise, and nothing it could not already tell you —
    // names and exemplar counts, never the vectors themselves.
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        let store = VoiceStore()
        let database = await store.database()
        print("model:  \(database.embeddingModelVersion)"
              + (database.isStale(against: LocalDiarizer.embeddingModelVersion)
                 ? "  STALE — matching disabled until people are named again (R30)" : ""))
        print("me:     \(database.me?.voiceprints.count ?? 0) voiceprint(s), echo detection only")
        print("people: \(database.persons.count)")
        for person in await store.persons() {
            let heard = person.lastHeardAt.map {
                DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short)
            } ?? "never"
            print("  \(person.name) — \(person.voiceprints.count) voiceprint(s), last heard \(heard)")
        }
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

if let i = args.firstIndex(of: "--record-test") {
    // --record-test <dir> <seconds> [--pause <at> <for>]
    guard args.count > i + 2, let seconds = Double(args[i + 2]) else {
        eprintLine("usage: --record-test <dir> <seconds> [--pause <at> <for>]")
        exit(2)
    }
    let dir = URL(fileURLWithPath: args[i + 1])
    var pauseAt: Double? = nil, pauseFor: Double? = nil
    if let p = args.firstIndex(of: "--pause"), args.count > p + 2 {
        pauseAt = Double(args[p + 1]); pauseFor = Double(args[p + 2])
    }

    let engine = CaptureEngine()
    do {
        try engine.start(into: dir)
        print("recording \(seconds)s into \(dir.path)")
        if let at = pauseAt, let dur = pauseFor {
            Thread.sleep(forTimeInterval: at)
            try engine.pause()
            print("paused for \(dur)s")
            Thread.sleep(forTimeInterval: dur)
            try engine.resume()
            print("resumed")
            Thread.sleep(forTimeInterval: max(0, seconds - at))
        } else {
            Thread.sleep(forTimeInterval: seconds)
        }
        let result = try engine.stop()
        print("recordedDuration: \(result.recordedDuration)")
        print("micPeak: \(result.micPeak)")
        print("remotePeak: \(result.remotePeak)")
        for span in result.pauseSpans {
            print("pause: at=\(span.atRecordedSeconds) gap=\(span.wallGapSeconds)")
        }
        print("RECORD-TEST-OK")
        exit(0)
    } catch {
        eprintLine("RECORD-TEST-FAIL: \(error)")
        exit(1)
    }
}

if let i = args.firstIndex(of: "--process-test") {
    setbuf(stdout, nil)
    // --process-test <mic.caf> <remote.caf> <vault-dir> [--title T] [--held]
    guard args.count > i + 3 else {
        eprintLine("usage: --process-test <mic.caf> <remote.caf> <vault-dir> [--title T] [--held]")
        exit(2)
    }
    let micSrc = URL(fileURLWithPath: args[i + 1])
    let remoteSrc = URL(fileURLWithPath: args[i + 2])
    let vault = args[i + 3]
    // No `--title` means the summariser names the Note, which is what the app
    // now does for every Session (R9a); passing one pins it, for a run where
    // the filename needs to be predictable.
    let title = args.firstIndex(of: "--title").flatMap { t in
        args.count > t + 1 ? args[t + 1] : nil
    }

    let settings = SettingsStore()
    settings.vaultPath = vault
    settings.delivery = args.contains("--held") ? .held : .immediate
    let jobsRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("braid-jobs-\(UUID().uuidString)")

    let remoteSilent = args.contains("--remote-silent")

    let startedAt = Date()
    let session = Session(title: title ?? Session.placeholderTitle(at: startedAt),
                          presetName: settings.defaultPresetName,
                          participants: ["Alex", "Jordan"], startedAt: startedAt,
                          recordedDuration: 246,
                          pauseSpans: [.init(atRecordedSeconds: 120, wallGapSeconds: 35)],
                          autoTitled: title == nil)
    let jobDir = jobsRoot.appendingPathComponent(session.id)
    try! FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)
    try! FileManager.default.copyItem(at: micSrc, to: jobDir.appendingPathComponent("mic.caf"))
    try! FileManager.default.copyItem(at: remoteSrc, to: jobDir.appendingPathComponent("remote.caf"))

    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var exitCode: Int32 = 1
    let env = JobQueue.Environment(
        transcriber: Transcriber.make(engine: settings.localEngine),
        summariser: AppleSummariser(),
        settings: settings,
        jobsRoot: jobsRoot,
        onEvent: { event in
            switch event {
            case .jobStarted(let job):
                print("job started: \(job.id)")
            case .jobDone(_, let noteURL):
                print("job done -> \(noteURL.path)")
                print("PROCESS-TEST-OK")
                exitCode = 0
                semaphore.signal()
            case .jobFailed(let job, let transient):
                print("job failed (transient=\(transient)): \(job.lastError ?? "?")")
                if !transient { semaphore.signal() }
            case .remoteSilentWarning:
                print("WARNING: remote track silent (R16)")
            case .echoBleedWarning:
                print("WARNING: speaker bleed confirmed — echoes will be cleaned")
            case .jobCancelled(let job):
                print("job cancelled: \(job.id)")
            case .speakersDetected(_, let stats, let mismatch):
                let described = stats
                    .map { "\($0.speaker) (\(Int($0.totalSeconds))s)" }
                    .joined(separator: ", ")
                print("voices to name: \(described)")
                if let mismatch { print("WARNING: speaker mismatch — \(mismatch.message)") }
            case .heldForNames(_, let stats, _):
                // R26: this is a success, not a stall — the Note is waiting on
                // names by design.
                print("held for naming: \(stats.count) voice(s)")
                print("PROCESS-TEST-HELD")
                exitCode = 0
                semaphore.signal()
            }
        })
    let queue = JobQueue(env: env)
    // Detached: the semaphore below blocks this thread — an inherited-context
    // Task would never start.
    Task.detached {
        await queue.enqueue(session: session, remoteSilent: remoteSilent)
    }
    _ = semaphore.wait(timeout: .now() + 1800)
    exit(exitCode)
}

if args.firstIndex(of: "--retry-test") != nil {
    // R7 choreography: unwritable Vault -> permanent failure, Recording kept,
    // no auto-retry; restore -> user Retry -> success, Recording deleted.
    setbuf(stdout, nil)
    let fm = FileManager.default
    let vault = fm.temporaryDirectory.appendingPathComponent("r7-vault-\(UUID().uuidString)")
    try! fm.createDirectory(at: vault, withIntermediateDirectories: true)
    let settings = SettingsStore()
    settings.vaultPath = vault.path
    settings.delivery = .immediate
    let jobsRoot = fm.temporaryDirectory
        .appendingPathComponent("braid-jobs-\(UUID().uuidString)")

    let session = Session(title: "R7 Retry Test", presetName: "Meeting",
                          participants: [], startedAt: Date(), recordedDuration: 246)
    let jobDir = jobsRoot.appendingPathComponent(session.id)
    try! fm.createDirectory(at: jobDir, withIntermediateDirectories: true)
    try! fm.copyItem(at: URL(fileURLWithPath: "/tmp/e2e-mic.caf"),
                     to: jobDir.appendingPathComponent("mic.caf"))
    try! fm.copyItem(at: URL(fileURLWithPath: "/tmp/e2e-remote.caf"),
                     to: jobDir.appendingPathComponent("remote.caf"))

    // Make the Vault unwritable.
    try! fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: vault.path)

    let failedOnce = DispatchSemaphore(value: 0)
    let doneSem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var queueRef: JobQueue?
    let env = JobQueue.Environment(
        transcriber: Transcriber.make(engine: settings.localEngine),
        summariser: AppleSummariser(),
        settings: settings,
        jobsRoot: jobsRoot,
        onEvent: { event in
            switch event {
            case .jobStarted(let job):
                print("job started (attempt \(job.attempts))")
            case .jobFailed(_, let transient):
                print("failed as expected (transient=\(transient))")
                if !transient { failedOnce.signal() }
            case .jobDone(_, let noteURL):
                print("retry succeeded -> \(noteURL.lastPathComponent)")
                doneSem.signal()
            default: break
            }
        })
    let queue = JobQueue(env: env)
    queueRef = queue
    print("enqueueing R7 job (vault locked at \(vault.path))")
    Task.detached { await queue.enqueue(session: session, remoteSilent: false) }

    guard failedOnce.wait(timeout: .now() + 1800) == .success else {
        eprintLine("R7-FAIL: no permanent failure observed"); exit(1)
    }
    // Recording must survive the failure.
    guard fm.fileExists(atPath: jobDir.appendingPathComponent("mic.caf").path) else {
        eprintLine("R7-FAIL: recording deleted after failure"); exit(1)
    }
    print("recording retained after failure ✓")
    // No auto-retry for permanent failures: wait 10s, still failed.
    Thread.sleep(forTimeInterval: 10)
    guard fm.fileExists(atPath: jobDir.appendingPathComponent("mic.caf").path) else {
        eprintLine("R7-FAIL: auto-retry happened for permanent failure"); exit(1)
    }
    print("no automatic retry for permanent failure ✓")
    // Restore and user-Retry.
    try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: vault.path)
    Task.detached { await queueRef?.retry(id: session.id) }
    guard doneSem.wait(timeout: .now() + 1800) == .success else {
        eprintLine("R7-FAIL: retry did not complete"); exit(1)
    }
    guard !fm.fileExists(atPath: jobDir.path) else {
        eprintLine("R7-FAIL: recording not deleted after success"); exit(1)
    }
    print("recording deleted only after confirmed success ✓")
    print("R7-TEST-OK")
    exit(0)
}

if args.contains("--version") {
    print("Braid \(Braid.version)")
    return true
}

return false
}

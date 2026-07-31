import Foundation
import MsNotesCore

func eprintLine(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Test-mode key source. The app itself only ever stores keys in the Keychain
/// (R13); these env vars exist so the verification harness can run against
/// freshly-built binaries, whose changed code signature invalidates the
/// Keychain ACL and would otherwise block on a GUI consent prompt.
func testKeys() -> (stt: String, claude: String)? {
    let env = ProcessInfo.processInfo.environment
    let keychain = KeychainStore()
    guard let stt = env["MSNOTES_ASSEMBLYAI_KEY"] ?? keychain.get(.assemblyAI),
          let claude = env["MSNOTES_ANTHROPIC_KEY"] ?? keychain.get(.anthropic) else { return nil }
    return (stt, claude)
}

// Headless verification modes (used by R-checks; see SPEC.md Requirements).
// Returns true when a CLI mode ran (the SwiftUI shell must not launch).
func runCLI() -> Bool {
    let args = CommandLine.arguments

if let i = args.firstIndex(of: "--record-test") {
    // --record-test <dir> <seconds> [--pause <at> <for>]
    guard args.count > i + 2, let seconds = Double(args[i + 2]) else {
        FileHandle.standardError.write(Data("usage: --record-test <dir> <seconds> [--pause <at> <for>]\n".utf8))
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
        FileHandle.standardError.write(Data("RECORD-TEST-FAIL: \(error)\n".utf8))
        exit(1)
    }
}

if let i = args.firstIndex(of: "--import-keys") {
    // --import-keys [file]  reads a .env file (KEY=value) and moves the keys
    // into the Keychain, which is the only place the app reads them from.
    let path = args.count > i + 1 && !args[i + 1].hasPrefix("--") ? args[i + 1] : ".env"
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
        eprintLine("cannot read \(path) — copy .env.example to .env and add your keys")
        exit(2)
    }
    let keychain = KeychainStore()
    var imported = 0
    for rawLine in content.split(separator: "\n") {
        var line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("#") else { continue }
        if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
        let parts = line.split(separator: "=", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count == 2 else { continue }
        // Tolerate quoted values.
        var value = parts[1]
        for quote in ["\"", "'"] where value.hasPrefix(quote) && value.hasSuffix(quote) {
            value = String(value.dropFirst().dropLast())
        }
        guard !value.isEmpty else { continue }
        switch parts[0].uppercased() {
        case "MSNOTES_ASSEMBLYAI_KEY": try? keychain.set(value, for: .assemblyAI); imported += 1
        case "MSNOTES_ANTHROPIC_KEY": try? keychain.set(value, for: .anthropic); imported += 1
        default: continue
        }
    }
    guard imported > 0 else {
        eprintLine("no keys found in \(path) — expected MSNOTES_ASSEMBLYAI_KEY and MSNOTES_ANTHROPIC_KEY")
        exit(1)
    }
    print("imported \(imported) key(s) into the Keychain")
    exit(0)
}

if args.contains("--check-keys") {
    // Reads both keys from the Keychain and reports, without printing them.
    // If this returns instantly, this binary owns the Keychain items and will
    // never raise a consent prompt.
    let keychain = KeychainStore()
    let stt = keychain.get(.assemblyAI)
    let claude = keychain.get(.anthropic)
    print("assemblyAI: \(stt.map { "present (\($0.count) chars)" } ?? "MISSING")")
    print("anthropic: \(claude.map { "present (\($0.count) chars)" } ?? "MISSING")")
    exit(stt != nil && claude != nil ? 0 : 1)
}

if let i = args.firstIndex(of: "--process-test") {
    setbuf(stdout, nil)
    // --process-test <mic.caf> <remote.caf> <vault-dir> [--title T]
    guard args.count > i + 3 else {
        FileHandle.standardError.write(Data("usage: --process-test <mic.caf> <remote.caf> <vault-dir>\n".utf8))
        exit(2)
    }
    let micSrc = URL(fileURLWithPath: args[i + 1])
    let remoteSrc = URL(fileURLWithPath: args[i + 2])
    let vault = args[i + 3]
    let title = args.firstIndex(of: "--title").flatMap { t in
        args.count > t + 1 ? args[t + 1] : nil
    } ?? "Process Test"

    guard let (sttKey, claudeKey) = testKeys() else {
        eprintLine("keys missing — run --import-keys or set MSNOTES_*_KEY")
        exit(1)
    }

    let settings = SettingsStore()
    settings.vaultPath = vault
    let jobsRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("msnotes-jobs-\(UUID().uuidString)")

    let remoteSilent = args.contains("--remote-silent")
    let costBefore = settings.costTotalUSD

    let session = Session(title: title, presetName: "Meeting",
                          participants: ["Alex", "Jordan"], startedAt: Date(),
                          recordedDuration: 246,
                          pauseSpans: [.init(atRecordedSeconds: 120, wallGapSeconds: 35)])
    let jobDir = jobsRoot.appendingPathComponent(session.id)
    try! FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)
    try! FileManager.default.copyItem(at: micSrc, to: jobDir.appendingPathComponent("mic.caf"))
    try! FileManager.default.copyItem(at: remoteSrc, to: jobDir.appendingPathComponent("remote.caf"))

    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var exitCode: Int32 = 1
    let env = JobQueue.Environment(
        provider: AssemblyAIAdapter(apiKey: sttKey),
        summariser: Summariser(apiKey: claudeKey),
        settings: settings,
        jobsRoot: jobsRoot,
        onEvent: { event in
            switch event {
            case .jobStarted(let job):
                print("job started: \(job.id)")
            case .jobDone(_, let noteURL):
                print("job done -> \(noteURL.path)")
                print(String(format: "cost delta: %.4f", settings.costTotalUSD - costBefore))
                print("PROCESS-TEST-OK")
                exitCode = 0
                semaphore.signal()
            case .jobFailed(let job, let transient):
                print("job failed (transient=\(transient)): \(job.lastError ?? "?")")
                if !transient { semaphore.signal() }
            case .remoteSilentWarning:
                print("WARNING: remote track silent (R16)")
            case .speakersDetected(_, let stats):
                let described = stats
                    .map { "\($0.speaker) (\(Int($0.totalSeconds))s)" }
                    .joined(separator: ", ")
                print("speakers detected: \(described)")
            }
        })
    let queue = JobQueue(env: env)
    // Detached: the semaphore below blocks this thread — an inherited-context
    // Task would never start.
    Task.detached {
        await queue.enqueue(session: session, remoteSilent: remoteSilent)
    }
    _ = semaphore.wait(timeout: .now() + 900)
    exit(exitCode)
}

if args.firstIndex(of: "--retry-test") != nil {
    // R7 choreography: unwritable Vault -> permanent failure, Recording kept,
    // no auto-retry; restore -> user Retry -> success, Recording deleted.
    setbuf(stdout, nil)
    guard let (sttKey, claudeKey) = testKeys() else {
        eprintLine("keys missing — run --import-keys or set MSNOTES_*_KEY"); exit(1)
    }
    let fm = FileManager.default
    let vault = fm.temporaryDirectory.appendingPathComponent("r7-vault-\(UUID().uuidString)")
    try! fm.createDirectory(at: vault, withIntermediateDirectories: true)
    let settings = SettingsStore()
    settings.vaultPath = vault.path
    let jobsRoot = fm.temporaryDirectory
        .appendingPathComponent("msnotes-jobs-\(UUID().uuidString)")

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
        provider: AssemblyAIAdapter(apiKey: sttKey),
        summariser: Summariser(apiKey: claudeKey),
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

    guard failedOnce.wait(timeout: .now() + 600) == .success else {
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
    guard doneSem.wait(timeout: .now() + 600) == .success else {
        eprintLine("R7-FAIL: retry did not complete"); exit(1)
    }
    guard !fm.fileExists(atPath: jobDir.path) else {
        eprintLine("R7-FAIL: recording not deleted after success"); exit(1)
    }
    print("recording deleted only after confirmed success ✓")
    print("R7-TEST-OK")
    exit(0)
}

if args.firstIndex(of: "--offline-test") != nil {
    // R8: unreachable Provider -> transient failure -> job stays queued with
    // Recording intact (the backoff loop owns the eventual completion).
    setbuf(stdout, nil)
    let fm = FileManager.default
    let vault = fm.temporaryDirectory.appendingPathComponent("r8-vault-\(UUID().uuidString)")
    try! fm.createDirectory(at: vault, withIntermediateDirectories: true)
    let settings = SettingsStore()
    settings.vaultPath = vault.path
    let jobsRoot = fm.temporaryDirectory
        .appendingPathComponent("msnotes-jobs-\(UUID().uuidString)")
    let session = Session(title: "R8 Offline Test", presetName: "Meeting",
                          participants: [], startedAt: Date(), recordedDuration: 246)
    let jobDir = jobsRoot.appendingPathComponent(session.id)
    try! fm.createDirectory(at: jobDir, withIntermediateDirectories: true)
    try! fm.copyItem(at: URL(fileURLWithPath: "/tmp/e2e-mic.caf"),
                     to: jobDir.appendingPathComponent("mic.caf"))
    try! fm.copyItem(at: URL(fileURLWithPath: "/tmp/e2e-remote.caf"),
                     to: jobDir.appendingPathComponent("remote.caf"))

    let sem = DispatchSemaphore(value: 0)
    let env = JobQueue.Environment(
        provider: AssemblyAIAdapter(apiKey: "irrelevant",
                                    baseURL: URL(string: "https://127.0.0.1:9")!),
        summariser: Summariser(apiKey: "irrelevant"),
        settings: settings,
        jobsRoot: jobsRoot,
        onEvent: { event in
            if case .jobFailed(let job, let transient) = event {
                print("offline failure observed: transient=\(transient), status=\(job.status.rawValue)")
                if transient { sem.signal() }
            }
        })
    let queue = JobQueue(env: env)
    Task.detached { await queue.enqueue(session: session, remoteSilent: false) }
    guard sem.wait(timeout: .now() + 120) == .success else {
        eprintLine("R8-FAIL: no transient failure observed"); exit(1)
    }
    guard fm.fileExists(atPath: jobDir.appendingPathComponent("mic.caf").path) else {
        eprintLine("R8-FAIL: recording lost on offline failure"); exit(1)
    }
    print("job re-queued with recording intact; backoff loop owns completion ✓")
    print("R8-TEST-OK")
    exit(0)
}

if args.contains("--version") {
    print("ms-notes \(MsNotes.version)")
    return true
}

return false
}

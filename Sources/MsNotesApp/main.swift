import Foundation
import MsNotesCore

// Headless verification modes (used by R-checks; see SPEC.md Requirements).
// The SwiftUI shell takes over when launched with no arguments (Phase 3).
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
    // --import-keys <file>   (lines: "assemblyAI: <key>" / "claude: <key>")
    guard args.count > i + 1,
          let content = try? String(contentsOfFile: args[i + 1], encoding: .utf8) else {
        FileHandle.standardError.write(Data("usage: --import-keys <file>\n".utf8))
        exit(2)
    }
    let keychain = KeychainStore()
    var imported = 0
    for line in content.split(separator: "\n") {
        let parts = line.split(separator: ":", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard parts.count == 2 else { continue }
        switch parts[0].lowercased() {
        case "assemblyai": try! keychain.set(parts[1], for: .assemblyAI); imported += 1
        case "claude", "anthropic": try! keychain.set(parts[1], for: .anthropic); imported += 1
        default: continue
        }
    }
    print("imported \(imported) keys into the Keychain")
    exit(imported > 0 ? 0 : 1)
}

func eprint(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
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

    let keychain = KeychainStore()
    guard let sttKey = keychain.get(.assemblyAI), let claudeKey = keychain.get(.anthropic) else {
        FileHandle.standardError.write(Data("keys missing — run --import-keys first\n".utf8))
        exit(1)
    }

    let settings = SettingsStore()
    settings.vaultPath = vault
    let jobsRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("msnotes-jobs-\(UUID().uuidString)")

    let session = Session(title: title, presetName: "Meeting",
                          participants: ["Alex", "Tayet"], startedAt: Date(),
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
                print("PROCESS-TEST-OK")
                exitCode = 0
                semaphore.signal()
            case .jobFailed(let job, let transient):
                print("job failed (transient=\(transient)): \(job.lastError ?? "?")")
                if !transient { semaphore.signal() }
            case .remoteSilentWarning:
                print("WARNING: remote track silent (R16)")
            }
        })
    let queue = JobQueue(env: env)
    eprint("enqueueing job \(session.id) (jobs root: \(jobsRoot.path))")
    // Detached: top-level code is MainActor-isolated and the semaphore below
    // blocks the main thread — an inherited-context Task would never start.
    Task.detached {
        eprint("detached task running")
        await queue.enqueue(session: session, remoteSilent: false)
        eprint("enqueue returned")
    }
    _ = semaphore.wait(timeout: .now() + 900)
    exit(exitCode)
}

print("ms-notes \(MsNotes.version)")

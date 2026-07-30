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

print("ms-notes \(MsNotes.version)")

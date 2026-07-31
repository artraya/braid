import Foundation
import CoreAudio
import AudioToolbox
import os

/// Decides when a call has ended, from one repeated observation: is a call app
/// holding the microphone right now?
///
/// Kept separate from the Core Audio polling so the rule can actually be
/// tested. Two properties matter and both are about not cutting a recording
/// short. It arms only once a watched app has genuinely held the mic during
/// this Session, so dictating into a quiet room never trips it. And it wants
/// the mic released continuously for a grace period, so Teams dropping and
/// rejoining, or a device switching, does not read as the end of the call.
public struct CallEndDetector: Sendable {
    /// How long a watched app must stay off the mic before the call counts as
    /// over. Long enough to ride out a reconnect, short enough to be useful.
    public var grace: TimeInterval

    public private(set) var armed = false
    private var releasedAt: Date?

    public init(grace: TimeInterval = 15) {
        self.grace = grace
    }

    /// Feed the current observation. Returns true exactly once, on the update
    /// where the call is judged to have ended.
    public mutating func update(callAppHoldingMic: Bool, now: Date) -> Bool {
        if callAppHoldingMic {
            armed = true
            releasedAt = nil
            return false
        }
        guard armed else { return false }
        guard let releasedAt else {
            self.releasedAt = now
            return false
        }
        guard now.timeIntervalSince(releasedAt) >= grace else { return false }
        // Fire once, then require a fresh call before firing again.
        self.armed = false
        self.releasedAt = nil
        return true
    }

    /// After the user says to keep recording. Disarms, so it takes a new call
    /// on the mic before this can fire again.
    public mutating func reset() {
        armed = false
        releasedAt = nil
    }
}

/// Watches whether any known call app is using the microphone, by polling Core
/// Audio's per-process state. This needs no permission and no Accessibility
/// access, and it does not care what the app's windows are doing.
public final class CallWatcher: @unchecked Sendable {
    /// Matched as a prefix, because browsers and Electron apps open the mic
    /// from a helper process: "com.microsoft.edgemac" also catches
    /// "com.microsoft.edgemac.helper".
    public static let defaultBundleIDs = [
        "com.microsoft.teams",          // also teams2, the current client
        "us.zoom.xos",
        "com.tinyspeck.slackmacgap",
        "com.webex.meetingmanager",
        "Cisco-Systems.Spark",
        "com.apple.FaceTime",
        "com.google.Chrome",
        "com.apple.Safari",
        "com.microsoft.edgemac",
    ]

    /// Never watch ourselves: Braid holds the mic for the whole Session, so
    /// counting it would mean the call never ends.
    public static let ownBundleID = "no.braid.app"

    private let bundleIDs: [String]
    private let pollInterval: TimeInterval
    private let onCallEnded: @Sendable () -> Void
    private let log = Logger(subsystem: "no.braid.app", category: "capture")

    private let lock = NSLock()
    private var detector: CallEndDetector
    private var timer: DispatchSourceTimer?

    public init(bundleIDs: [String] = CallWatcher.defaultBundleIDs,
                pollInterval: TimeInterval = 2,
                grace: TimeInterval = 15,
                onCallEnded: @escaping @Sendable () -> Void) {
        self.bundleIDs = bundleIDs
        self.pollInterval = pollInterval
        self.detector = CallEndDetector(grace: grace)
        self.onCallEnded = onCallEnded
    }

    /// True once a call app has been seen on the mic, so the UI can say whether
    /// it is actually watching anything.
    public var isArmed: Bool { lock.withLock { detector.armed } }

    public func start() {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        timer.setEventHandler { [weak self] in self?.poll() }
        lock.withLock {
            detector.reset()
            self.timer = timer
        }
        timer.resume()
        log.notice("call watcher started for \(self.bundleIDs.joined(separator: ", "), privacy: .public)")
    }

    public func stop() {
        let existing = lock.withLock { () -> DispatchSourceTimer? in
            let t = timer
            timer = nil
            detector.reset()
            return t
        }
        existing?.cancel()
    }

    /// The user chose to keep recording: disarm until a call starts again.
    public func keepRecording() {
        lock.withLock { detector.reset() }
    }

    private func poll() {
        let holding = Self.callAppIsUsingMicrophone(bundleIDs: bundleIDs)
        let ended = lock.withLock { detector.update(callAppHoldingMic: holding, now: Date()) }
        if ended {
            log.notice("call app released the microphone — auto-end")
            onCallEnded()
        }
    }

    // MARK: - Core Audio

    public static func callAppIsUsingMicrophone(bundleIDs: [String]) -> Bool {
        for process in audioProcesses() {
            guard let bundle = bundleID(of: process), !bundle.isEmpty,
                  bundle != ownBundleID,
                  bundleIDs.contains(where: { matches(bundle, watched: $0) }),
                  isRunningInput(process)
            else { continue }
            return true
        }
        return false
    }

    /// Exact match, or a child process of the watched app.
    static func matches(_ bundle: String, watched: String) -> Bool {
        bundle == watched || bundle.hasPrefix(watched + ".")
            // "com.microsoft.teams" should also catch "com.microsoft.teams2".
            || (bundle.hasPrefix(watched) && bundle.dropFirst(watched.count).allSatisfy(\.isNumber))
    }

    private static func audioProcesses() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func bundleID(of process: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr
        else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func isRunningInput(_ process: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &running) == noErr
        else { return false }
        return running != 0
    }
}

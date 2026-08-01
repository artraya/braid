import Foundation
import CoreAudio
import AudioToolbox
import os

/// Records a Session: system-audio process tap + default mic combined in one
/// aggregate device (shared clock, drift compensation — ADR-0001), written as
/// two mono CAF Tracks. Pause discards frames without stopping the device, so
/// both Tracks stay on the shared recorded-audio clock.
public final class CaptureEngine: @unchecked Sendable {

    public struct PauseSpan: Sendable, Codable, Equatable {
        /// Position in recorded-audio seconds where the pause occurred.
        public let atRecordedSeconds: TimeInterval
        /// Wall-clock length of the gap.
        public let wallGapSeconds: TimeInterval
    }

    public struct Result: Sendable {
        public let micURL: URL
        public let remoteURL: URL
        public let recordedDuration: TimeInterval
        public let pauseSpans: [PauseSpan]
        /// Peak absolute sample observed on the Remote Track (for R16).
        public let remotePeak: Float
        public let micPeak: Float
        /// Correlation-confirmed speaker bleed (echo cycle): the far end
        /// audibly re-entered the mic during this Session.
        public let bleedDetected: Bool
    }

    public enum State: String, Sendable { case idle, recording, paused }

    private let log = Logger(subsystem: "no.braid.app", category: "capture")
    private let stateLock = NSLock()
    private var _state: State = .idle
    public var state: State { stateLock.withLock { _state } }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var micWriter: TrackWriter?
    private var remoteWriter: TrackWriter?
    private let keepAlive = SilenceKeepAlive()
    private var micURL: URL?
    private var remoteURL: URL?
    /// Live peaks for the recording HUD's waveform.
    public let levels = LevelMeter()
    /// Correlation proof of speaker bleed; the panel reads its verdict live.
    public let bleedDetector = EchoBleedDetector()
    /// Device prior: the default output is the built-in speaker (not proof —
    /// AirPods and a HomePod both read as Bluetooth — but a strong hint).
    public var speakerOutputLikely: Bool { stateLock.withLock { _speakerOutputLikely } }
    private var _speakerOutputLikely = false
    private var outputListener: AudioObjectPropertyListenerBlock?

    // Written only inside the IOProc / state transitions.
    private var paused = false  // read by IOProc (word-sized read; transitions hold no lock in the RT path)
    private var pauseSpans: [PauseSpan] = []
    private var pauseBeganWall: Date?
    private var remotePeak: Float = 0
    private var micPeak: Float = 0

    // Scratch buffers for mono mixdown (allocated once, reused per callback).
    private var micScratch = [Float](repeating: 0, count: 16_384)
    private var remoteScratch = [Float](repeating: 0, count: 16_384)

    public init() {}

    // MARK: - Lifecycle

    /// Starts recording into `directory` as `mic.caf` + `remote.caf`.
    public func start(into directory: URL) throws {
        try stateLock.withLock {
            guard _state == .idle else { throw CaptureError.invalidState("start while \(_state)") }
            _state = .recording
        }
        do { try startCapture(into: directory) }
        catch {
            stateLock.withLock { _state = .idle }
            teardownCoreAudio()
            throw error
        }
        log.info("recording started into \(directory.path, privacy: .public)")
    }

    public func pause() throws {
        try stateLock.withLock {
            guard _state == .recording else { throw CaptureError.invalidState("pause while \(_state)") }
            _state = .paused
        }
        pauseBeganWall = Date()
        paused = true
        log.info("paused at \(self.micWriter?.duration ?? 0)s recorded")
    }

    public func resume() throws {
        try stateLock.withLock {
            guard _state == .paused else { throw CaptureError.invalidState("resume while \(_state)") }
            _state = .recording
        }
        if let began = pauseBeganWall, let writer = micWriter {
            pauseSpans.append(PauseSpan(
                atRecordedSeconds: writer.duration,
                wallGapSeconds: Date().timeIntervalSince(began)))
        }
        pauseBeganWall = nil
        paused = false
        log.info("resumed")
    }

    /// Stops, finalises both CAF files, and returns the Recording facts.
    public func stop() throws -> Result {
        try stateLock.withLock {
            guard _state == .recording || _state == .paused else {
                throw CaptureError.invalidState("stop while \(_state)")
            }
            _state = .idle
        }
        // A Session stopped while paused closes its open gap first.
        if let began = pauseBeganWall, let writer = micWriter {
            pauseSpans.append(PauseSpan(
                atRecordedSeconds: writer.duration,
                wallGapSeconds: Date().timeIntervalSince(began)))
            pauseBeganWall = nil
        }
        teardownCoreAudio()
        let duration = micWriter?.duration ?? 0
        micWriter?.close()
        remoteWriter?.close()
        defer { micWriter = nil; remoteWriter = nil; pauseSpans = []; remotePeak = 0; micPeak = 0 }
        log.info("stopped after \(duration)s recorded")
        return Result(
            micURL: micURL!, remoteURL: remoteURL!,
            recordedDuration: duration,
            pauseSpans: pauseSpans,
            remotePeak: remotePeak, micPeak: micPeak,
            bleedDetected: bleedDetector.verdict.confirmed)
    }

    // MARK: - Core Audio setup

    private func startCapture(into directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let mic = try Self.defaultInputDevice()

        // Global tap over all system audio output (audio-only TCC permission).
        let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDesc.muteBehavior = .unmuted
        tapDesc.name = "Braid tap"
        tapDesc.isPrivate = true
        try checkOS(AudioHardwareCreateProcessTap(tapDesc, &tapID), "create process tap")

        let aggDict: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Braid aggregate",
            kAudioAggregateDeviceUIDKey as String: "no.braid.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            // The mic must be the clock master: a global tap produces no
            // timeline while no system audio renders, and an aggregate
            // clocked by the tap stalls entirely (zero callbacks on all
            // streams) until something plays. Discovered empirically.
            kAudioAggregateDeviceMainSubDeviceKey as String: mic.uid,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: mic.uid]
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [kAudioSubTapUIDKey as String: tapDesc.uuid.uuidString,
                 kAudioSubTapDriftCompensationKey as String: true]
            ],
        ]
        try checkOS(AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &aggregateID),
                    "create aggregate device")

        let rate = try Self.nominalSampleRate(of: aggregateID)
        levels.configure(sampleRate: rate)
        bleedDetector.configure(sampleRate: rate)
        refreshOutputRoute()
        startOutputListener()
        let micURL = directory.appendingPathComponent("mic.caf")
        let remoteURL = directory.appendingPathComponent("remote.caf")
        self.micURL = micURL
        self.remoteURL = remoteURL
        micWriter = try TrackWriter(url: micURL, deviceRate: rate)
        remoteWriter = try TrackWriter(url: remoteURL, deviceRate: rate)

        try checkOS(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) {
            [weak self] _, inData, _, _, _ in
            self?.handleIO(inData)
        }, "create IOProc")
        try keepAlive.start()
        try checkOS(AudioDeviceStart(aggregateID, procID), "start aggregate device")
    }

    /// Real-time callback: buffer 0 is the mic sub-device, the rest is the tap.
    /// Mixes each side to mono, tracks peaks, hands frames to the async writers.
    private func handleIO(_ inData: UnsafePointer<AudioBufferList>) {
        if paused { return }
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        guard abl.count >= 1 else { return }

        // Loudest of either side this callback, so the waveform answers to both
        // the user and the far end.
        var callbackPeak: Float = 0
        var callbackFrames = 0
        var remoteFrames = 0

        for (index, buffer) in abl.enumerated() {
            guard let data = buffer.mData else { continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            let totalSamples = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let frames = totalSamples / channels
            guard frames > 0 else { continue }
            let samples = data.bindMemory(to: Float.self, capacity: totalSamples)

            let isMic = index == 0
            var scratch = isMic ? micScratch : remoteScratch
            let n = min(frames, scratch.count)
            var peak: Float = 0
            scratch.withUnsafeMutableBufferPointer { dst in
                for f in 0..<n {
                    var acc: Float = 0
                    for c in 0..<channels { acc += samples[f * channels + c] }
                    let v = acc / Float(channels)
                    dst[f] = v
                    let a = abs(v)
                    if a > peak { peak = a }
                }
                if isMic {
                    if peak > micPeak { micPeak = peak }
                    micWriter?.writeAsync(dst.baseAddress!, frames: n)
                } else {
                    if peak > remotePeak { remotePeak = peak }
                    remoteWriter?.writeAsync(dst.baseAddress!, frames: n)
                }
            }
            if isMic { micScratch = scratch } else { remoteScratch = scratch }
            if peak > callbackPeak { callbackPeak = peak }
            if isMic { callbackFrames = n } else { remoteFrames = max(remoteFrames, n) }
        }
        if callbackFrames > 0 {
            levels.push(peak: callbackPeak, frames: callbackFrames)
        }
        // Feed the bleed detector matched mono frames; it decimates, copies
        // and returns, and analyses on its own utility queue.
        if callbackFrames > 0, remoteFrames > 0 {
            let n = min(callbackFrames, remoteFrames)
            micScratch.withUnsafeBufferPointer { mic in
                remoteScratch.withUnsafeBufferPointer { remote in
                    bleedDetector.pushAsync(mic: mic.baseAddress!,
                                            remote: remote.baseAddress!, frames: n)
                }
            }
        }
    }

    // MARK: - Output route (speaker prior)

    /// True when the default output is the built-in speaker — the one case
    /// the hardware states outright. Headphone jack, USB, HDMI and Bluetooth
    /// all clear it; Bluetooth stays ambiguous by design (research note), and
    /// the correlation carries the proof there.
    static func defaultOutputIsBuiltInSpeaker() -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr,
            deviceID != kAudioObjectUnknown else { return false }

        addr.mSelector = kAudioDevicePropertyTransportType
        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &transport) == noErr,
              transport == kAudioDeviceTransportTypeBuiltIn else { return false }

        // Built-in output: the data source says speaker ('ispk') or headphone
        // jack ('hdpn'). Unreadable defaults to speaker — the safe warning.
        addr.mSelector = kAudioDevicePropertyDataSource
        addr.mScope = kAudioObjectPropertyScopeOutput
        var source: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &source) == noErr else {
            return true
        }
        return source != 0x6864_706E   // 'hdpn'
    }

    private func refreshOutputRoute() {
        let speaker = Self.defaultOutputIsBuiltInSpeaker()
        stateLock.withLock { _speakerOutputLikely = speaker }
        if speaker {
            log.notice("default output is the built-in speaker — bleed likely without headphones")
        }
    }

    /// Re-evaluates the prior when the default output changes mid-Session —
    /// the realistic failure is AirPods dying forty minutes in.
    private func startOutputListener() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshOutputRoute()
        }
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, nil, block) == noErr {
            outputListener = block
        }
    }

    private func stopOutputListener() {
        guard let block = outputListener else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, nil, block)
        outputListener = nil
    }

    private func teardownCoreAudio() {
        stopOutputListener()
        keepAlive.stop()
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: - Device helpers

    private static func defaultInputDevice() throws -> (id: AudioObjectID, uid: String) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try checkOS(AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID),
            "get default input device")
        addr.mSelector = kAudioDevicePropertyDeviceUID
        var uidRef: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        try checkOS(AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &uidRef),
                    "get mic UID")
        return (deviceID, uidRef as String)
    }

    private static func nominalSampleRate(of device: AudioObjectID) throws -> Float64 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        try checkOS(AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &rate),
                    "get sample rate")
        return rate
    }
}

extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}

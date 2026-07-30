// Spike A: prove Core Audio process-tap + aggregate-device capture works on macOS 27.
// Creates a global system-audio tap, combines it with the default mic in one
// aggregate device with drift compensation, runs an IOProc for ~10s, and reports
// per-stream peak levels. Triggers the Microphone and System Audio Recording
// TCC prompts on first run.
import Foundation
import CoreAudio
import AudioToolbox

func check(_ err: OSStatus, _ what: String) {
    guard err == noErr else {
        print("FAIL: \(what) -> OSStatus \(err)")
        exit(1)
    }
}

// Default input device UID (the mic)
var addr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultInputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
var micID = AudioObjectID(kAudioObjectUnknown)
var size = UInt32(MemoryLayout<AudioObjectID>.size)
check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &micID), "get default input device")

addr.mSelector = kAudioDevicePropertyDeviceUID
var micUIDRef: CFString = "" as CFString
size = UInt32(MemoryLayout<CFString>.size)
check(AudioObjectGetPropertyData(micID, &addr, 0, nil, &size, &micUIDRef), "get mic UID")
let micUID = micUIDRef as String
print("mic device: \(micUID)")

// Global process tap (all system audio output) — triggers System Audio Recording TCC
let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
tapDesc.muteBehavior = .unmuted
tapDesc.name = "ms-notes-spike-tap"
tapDesc.isPrivate = true
var tapID = AudioObjectID(kAudioObjectUnknown)
check(AudioHardwareCreateProcessTap(tapDesc, &tapID), "create process tap")
print("tap created: \(tapID)")

// Aggregate device: mic sub-device + tap, drift compensation on
let aggDict: [String: Any] = [
    kAudioAggregateDeviceNameKey as String: "ms-notes-spike-agg",
    kAudioAggregateDeviceUIDKey as String: "ms-notes-spike-\(UUID().uuidString)",
    kAudioAggregateDeviceIsPrivateKey as String: true,
    kAudioAggregateDeviceIsStackedKey as String: false,
    kAudioAggregateDeviceTapAutoStartKey as String: true,
    kAudioAggregateDeviceSubDeviceListKey as String: [
        [kAudioSubDeviceUIDKey as String: micUID]
    ],
    kAudioAggregateDeviceTapListKey as String: [
        [kAudioSubTapUIDKey as String: tapDesc.uuid.uuidString,
         kAudioSubTapDriftCompensationKey as String: true]
    ],
]
var aggID = AudioObjectID(kAudioObjectUnknown)
check(AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &aggID), "create aggregate device")
print("aggregate device: \(aggID)")

// IOProc: track peak per input stream buffer
final class Peaks: @unchecked Sendable {
    var values = [Float](repeating: 0, count: 8)
    var callbacks = 0
}
let peaks = Peaks()

var procID: AudioDeviceIOProcID?
check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { _, inData, _, _, _ in
    let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
    peaks.callbacks += 1
    for (i, buf) in abl.enumerated() where i < 8 {
        guard let ptr = buf.mData else { continue }
        let n = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
        let samples = ptr.bindMemory(to: Float.self, capacity: n)
        for s in 0..<n {
            let v = abs(samples[s])
            if v > peaks.values[i] { peaks.values[i] = v }
        }
    }
}, "create IOProc")

check(AudioDeviceStart(aggID, procID), "start device")
print("capturing 10s... (mic + system audio)")
Thread.sleep(forTimeInterval: 10)
check(AudioDeviceStop(aggID, procID), "stop device")

AudioDeviceDestroyIOProcID(aggID, procID!)
AudioHardwareDestroyAggregateDevice(aggID)
AudioHardwareDestroyProcessTap(tapID)

print("callbacks: \(peaks.callbacks)")
for (i, p) in peaks.values.enumerated() where p > 0 {
    print(String(format: "stream %d peak: %.4f", i, p))
}
let live = peaks.values.filter { $0 > 0.0001 }.count
print(live >= 2 ? "SPIKE PASS: \(live) live streams (mic + tap)" :
      live == 1 ? "SPIKE PARTIAL: only 1 live stream — check which permission is missing" :
      "SPIKE FAIL: no signal — permissions likely denied")

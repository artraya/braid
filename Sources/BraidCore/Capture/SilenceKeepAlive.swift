import Foundation
import CoreAudio

/// Renders continuous silence to the default output device while a Session
/// records. A global process tap produces no timeline when no process renders
/// audio, which stalls the whole tap-containing aggregate (zero callbacks on
/// every stream, discovered empirically). Keeping one zero-filled output
/// stream alive guarantees the tap always ticks — silence adds nothing to the
/// recorded mix and costs ~0% CPU.
final class SilenceKeepAlive: @unchecked Sendable {
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    func start() throws {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try checkOS(AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID),
            "get default output device")
        try checkOS(AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil) {
            _, _, _, outData, _ in
            // Output buffers arrive pre-zeroed; nothing to do — the render
            // itself is what keeps the tap's clock alive.
            _ = outData
        }, "create keep-alive IOProc")
        try checkOS(AudioDeviceStart(deviceID, procID), "start keep-alive output")
    }

    func stop() {
        if let procID, deviceID != kAudioObjectUnknown {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        procID = nil
        deviceID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }
}

import Foundation
import Synchronization

/// Recent audio peaks for the recording waveform.
///
/// Written from the Core Audio IOProc, so it allocates nothing and takes no
/// locks: a fixed ring of floats plus an atomic cursor. The cursor is published
/// with release ordering after each sample is stored, so a reader that acquires
/// it sees the float writes that preceded it.
///
/// Peaks are bucketed into fixed time slices rather than stored per callback,
/// because callback size varies with the device and the bars would otherwise
/// scroll at a different speed on different hardware.
public final class LevelMeter: @unchecked Sendable {
    public static let capacity = 256
    /// One bar per 50 ms: 20 bars a second, and the full ring is about 12
    /// seconds of history.
    public static let barSeconds = 0.05

    private let buffer: UnsafeMutablePointer<Float>
    private let cursor = Atomic<UInt64>(0)

    // Audio thread only.
    private var windowPeak: Float = 0
    private var windowFrames = 0
    private var framesPerBar = 2205

    public init() {
        buffer = .allocate(capacity: Self.capacity)
        buffer.initialize(repeating: 0, count: Self.capacity)
    }

    deinit {
        buffer.deinitialize(count: Self.capacity)
        buffer.deallocate()
    }

    /// Called before recording starts, never from the audio thread.
    public func configure(sampleRate: Double) {
        framesPerBar = max(1, Int(sampleRate * Self.barSeconds))
        reset()
    }

    public func reset() {
        buffer.update(repeating: 0, count: Self.capacity)
        cursor.store(0, ordering: .releasing)
        windowPeak = 0
        windowFrames = 0
    }

    /// Audio thread. `peak` is the loudest sample in this callback's `frames`.
    public func push(peak: Float, frames: Int) {
        if peak > windowPeak { windowPeak = peak }
        windowFrames += frames
        guard windowFrames >= framesPerBar else { return }
        let index = cursor.load(ordering: .relaxed)
        buffer[Int(index % UInt64(Self.capacity))] = windowPeak
        cursor.store(index &+ 1, ordering: .releasing)
        windowPeak = 0
        windowFrames = 0
    }

    /// Oldest to newest, padded with silence before recording has filled the
    /// ring. Safe to call from the main thread at display rate.
    public func recent(_ count: Int) -> [Float] {
        let wanted = min(count, Self.capacity)
        let written = cursor.load(ordering: .acquiring)
        var out = [Float](repeating: 0, count: wanted)
        guard written > 0 else { return out }
        for offset in 0..<wanted {
            // offset 0 is the oldest bar we are showing.
            let age = UInt64(wanted - offset)
            guard written >= age else { continue }
            let index = (written - age) % UInt64(Self.capacity)
            out[offset] = buffer[Int(index)]
        }
        return out
    }
}

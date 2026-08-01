import Foundation
import Accelerate
import os

/// Detects the far end leaking from the speakers back into the microphone.
///
/// Both Tracks share one clock (ADR-0001), so genuine bleed shows up as a
/// strong correlation between the Mic and Remote streams at one small,
/// constant, positive lag — the acoustic flight time plus buffering. That
/// makes cross-correlation *proof*, where the output-device check is only a
/// prior. Windows are decimated to ~4 kHz (speech energy is ample there) and
/// analysed off the real-time thread; confirmation needs two windows agreeing
/// on the lag, and once confirmed it stays confirmed for the Session.
public final class EchoBleedDetector: @unchecked Sendable {

    public struct Verdict: Sendable, Equatable {
        public var confirmed: Bool
        /// The echo path delay, once confirmed.
        public var lagMilliseconds: Double?
    }

    /// ~4 kHz analysis rate: enough bandwidth for speech correlation, cheap
    /// enough that a window is ~1.6M multiplies.
    static let analysisRate = 4_000.0
    /// One analysis window: 1 s at the analysis rate.
    static let windowSize = 4_096
    /// Longest echo path entertained: 100 ms (acoustic + buffering).
    static let maxLagSamples = 400
    /// Normalised correlation a window must reach. Speech through a room at
    /// speaker volume comfortably exceeds this; incidental correlation of
    /// independent signals does not.
    static let threshold: Float = 0.25
    /// Windows must agree on the lag within this tolerance to confirm.
    static let lagToleranceMs = 5.0

    private let queue = DispatchQueue(label: "no.braid.bleed", qos: .utility)
    private let log = Logger(subsystem: "no.braid.app", category: "capture")
    private var stride = 1
    private var micBuffer: [Float] = []
    private var remoteBuffer: [Float] = []
    private var lastPeakLagMs: Double?
    private var agreeingWindows = 0

    private let lock = NSLock()
    private var _verdict = Verdict(confirmed: false, lagMilliseconds: nil)
    public var verdict: Verdict { lock.withLock { _verdict } }

    public init() {}

    /// Ready for a new Session at the device's rate.
    public func configure(sampleRate: Double) {
        queue.sync {
            stride = max(1, Int(sampleRate / Self.analysisRate))
            micBuffer.removeAll(keepingCapacity: true)
            remoteBuffer.removeAll(keepingCapacity: true)
            lastPeakLagMs = nil
            agreeingWindows = 0
        }
        lock.withLock { _verdict = Verdict(confirmed: false, lagMilliseconds: nil) }
    }

    /// Called from the IO path with matched mono frames. Copies the decimated
    /// samples and returns; analysis happens on the utility queue. Mirrors
    /// TrackWriter's contract: the pointers are only valid during the call.
    public func pushAsync(mic: UnsafePointer<Float>, remote: UnsafePointer<Float>,
                          frames: Int) {
        guard !verdict.confirmed, frames > 0 else { return }
        let localStride = stride
        var micDecimated = [Float]()
        var remoteDecimated = [Float]()
        micDecimated.reserveCapacity(frames / localStride + 1)
        remoteDecimated.reserveCapacity(frames / localStride + 1)
        var i = 0
        while i < frames {
            micDecimated.append(mic[i])
            remoteDecimated.append(remote[i])
            i += localStride
        }
        queue.async { [self] in
            append(mic: micDecimated, remote: remoteDecimated)
        }
    }

    /// Tests (and only tests) need analysis to have run before asserting.
    public func waitForPendingAnalysis() {
        queue.sync {}
    }

    // MARK: - Analysis (on `queue`)

    private func append(mic: [Float], remote: [Float]) {
        guard !verdict.confirmed else { return }
        micBuffer.append(contentsOf: mic)
        remoteBuffer.append(contentsOf: remote)
        let needed = Self.windowSize + Self.maxLagSamples
        while micBuffer.count >= needed {
            analyseWindow()
            // Slide by a full window; the lag margin carries over.
            micBuffer.removeFirst(Self.windowSize)
            remoteBuffer.removeFirst(Self.windowSize)
        }
    }

    /// One window: mic[t] against remote[t - lag] for lag 0...maxLag. The mic
    /// is read `maxLag` samples into the buffer so every lag has history. Both
    /// sides are mean-removed first: a shared DC offset or slow drift would
    /// otherwise correlate at every lag and read as bleed.
    private func analyseWindow() {
        let n = Self.windowSize
        let maxLag = Self.maxLagSamples

        var mic = [Float](repeating: 0, count: n)
        var remote = [Float](repeating: 0, count: n + maxLag)
        micBuffer.withUnsafeBufferPointer { src in
            var mean: Float = 0
            vDSP_meanv(src.baseAddress! + maxLag, 1, &mean, vDSP_Length(n))
            var negMean = -mean
            vDSP_vsadd(src.baseAddress! + maxLag, 1, &negMean, &mic, 1, vDSP_Length(n))
        }
        remoteBuffer.withUnsafeBufferPointer { src in
            var mean: Float = 0
            vDSP_meanv(src.baseAddress!, 1, &mean, vDSP_Length(n + maxLag))
            var negMean = -mean
            vDSP_vsadd(src.baseAddress!, 1, &negMean, &remote, 1, vDSP_Length(n + maxLag))
        }

        var micEnergy: Float = 0
        var remoteEnergy: Float = 0
        vDSP_dotpr(mic, 1, mic, 1, &micEnergy, vDSP_Length(n))
        vDSP_dotpr(remote, 1, remote, 1, &remoteEnergy, vDSP_Length(n + maxLag))
        // Both sides must actually contain signal: a silent far end (nothing
        // to leak) or a dead mic proves nothing either way.
        let floorEnergy = Float(n) * 1e-6
        guard micEnergy > floorEnergy, remoteEnergy > floorEnergy else {
            agreeingWindows = 0
            return
        }

        var bestCorr: Float = 0
        var bestLag = 0
        mic.withUnsafeBufferPointer { micPtr in
            remote.withUnsafeBufferPointer { remotePtr in
                for lag in 0...maxLag {
                    var dot: Float = 0
                    vDSP_dotpr(micPtr.baseAddress!, 1,
                               remotePtr.baseAddress! + (maxLag - lag), 1,
                               &dot, vDSP_Length(n))
                    if dot > bestCorr {
                        bestCorr = dot
                        bestLag = lag
                    }
                }
            }
        }
        let normalised = bestCorr
            / (micEnergy.squareRoot() * (remoteEnergy * Float(n) / Float(n + maxLag)).squareRoot())
        let lagMs = Double(bestLag) / Self.analysisRate * 1000

        guard normalised >= Self.threshold, bestLag > 0 else {
            agreeingWindows = 0
            lastPeakLagMs = nil
            return
        }
        if let last = lastPeakLagMs, abs(last - lagMs) <= Self.lagToleranceMs {
            agreeingWindows += 1
        } else {
            agreeingWindows = 1
        }
        lastPeakLagMs = lagMs
        if agreeingWindows >= 2 {
            lock.withLock { _verdict = Verdict(confirmed: true, lagMilliseconds: lagMs) }
            log.warning("speaker bleed confirmed: lag \(String(format: "%.1f", lagMs))ms, correlation \(String(format: "%.2f", normalised))")
        }
    }
}

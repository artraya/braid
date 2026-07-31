import Foundation

/// SPEC Architecture (Cost): rates live in one repo config, USD, maintained by
/// hand. Cost per Job = audio hours × STT rates per submitted Track + Claude
/// token usage × token rates.
public struct CostTable: Sendable, Codable {
    /// AssemblyAI universal-3-5-pro, USD per audio-hour, per submitted Track.
    public var sttBasePerHour: Double
    public var sttDiarizationPerHour: Double
    public var sttKeytermsPerHour: Double
    /// Claude claude-opus-5, USD per million tokens.
    public var claudeInputPerMTok: Double
    public var claudeOutputPerMTok: Double

    /// Current published pricing, retrieved 2026-07-30 (see IDEA.md evidence).
    public static let current = CostTable(
        sttBasePerHour: 0.21,
        sttDiarizationPerHour: 0.02,
        sttKeytermsPerHour: 0.05,
        claudeInputPerMTok: 5.00,
        claudeOutputPerMTok: 25.00)

    public func sttCost(trackHours: Double, diarized: Bool, keyterms: Bool) -> Double {
        var rate = sttBasePerHour
        if diarized { rate += sttDiarizationPerHour }
        if keyterms { rate += sttKeytermsPerHour }
        return trackHours * rate
    }

    public func claudeCost(inputTokens: Int, outputTokens: Int) -> Double {
        Double(inputTokens) / 1_000_000 * claudeInputPerMTok
            + Double(outputTokens) / 1_000_000 * claudeOutputPerMTok
    }
}

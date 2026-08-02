import Foundation
import BraidCore

/// `--local-check <audio> [--reference <assemblyai.json>] [--engine parakeet|apple]`
///
/// Runs one Track through the local Adapter exactly as a Job would, and scores
/// it against a trusted AssemblyAI response when one is given. This is the
/// measurement the cycle asked for before local is trusted: not a leaderboard
/// number on clean read speech, but this machine, on real call audio.
///
/// Prints only aggregate numbers and short excerpts — the fixtures are real
/// meetings, so nothing here writes a transcript to disk.
enum LocalCheck {

    static func run(audio: URL, reference: URL?, engine engineID: LocalEngine,
                    minTurn: Double = 1.0, step: Double = 0.2) async -> Int32 {
        let engine: any TranscriberEngine = engineID == .apple
            ? AppleSpeechEngine() : ParakeetEngine()
        let adapter = LocalAdapter(
            engine: engine,
            diarizer: LocalDiarizer(minTurnSeconds: minTurn, stepRatio: step))

        print("engine:   \(engineID.label) (\(engineID.providerName))")
        print("diarizer: minTurn \(minTurn)s, stepRatio \(step)")
        print("audio:    \(audio.lastPathComponent)")

        let loadStart = Date()
        do {
            try await adapter.prepare()
        } catch {
            print("FAILED to prepare models: \(error)")
            return 1
        }
        print(String(format: "models:   ready in %.1fs", Date().timeIntervalSince(loadStart)))

        let start = Date()
        let utterances: [Utterance]
        do {
            utterances = try await adapter.transcribe(
                track: audio, diarize: true, keyTerms: [], expectedSpeakers: nil)
        } catch {
            print("FAILED to transcribe: \(error)")
            return 1
        }
        let elapsed = Date().timeIntervalSince(start)

        let speakers = Set(utterances.map(\.speaker))
        let audioSeconds = utterances.map(\.end).max() ?? 0
        print(String(format: "time:     %.1fs for %.0fs of audio (%.0fx realtime)",
                     elapsed, audioSeconds, audioSeconds / max(elapsed, 0.001)))
        print("peak RSS: \(peakMemoryMB()) MB")
        print("output:   \(utterances.count) utterances, \(speakers.count) voices")

        // Diagnostic: the diarizer's own view, before alignment touches it.
        // Tells us whether a bad attribution is the diarizer under-segmenting
        // or the aligner putting words in the wrong turn — different fixes.
        if let spans = try? await LocalDiarizer(minTurnSeconds: minTurn, stepRatio: step)
            .diarize(file: audio, expected: nil) {
            let distinct = Set(spans.map(\.speakerId))
            let switches = zip(spans, spans.dropFirst()).filter { $0.speakerId != $1.speakerId }.count
            print("diarizer: \(spans.count) turns, \(distinct.count) voices, \(switches) speaker changes")
            let median = spans.map(\.duration).sorted()[max(0, spans.count / 2)]
            print(String(format: "          median turn %.1fs, shortest %.1fs",
                         median, spans.map(\.duration).min() ?? 0))
        }

        guard let reference else { return 0 }
        guard let data = try? Data(contentsOf: reference),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("could not read reference \(reference.lastPathComponent)")
            return 1
        }
        return score(utterances: utterances, reference: json)
    }

    /// Compares against the Provider Braid already trusts. Not ground truth —
    /// a reference — so the numbers are a deviation, not an error rate.
    private static func score(utterances: [Utterance], reference: [String: Any]) -> Int32 {
        let referenceUtterances = parseReference(reference)
        let referenceSpeakers = Set(referenceUtterances.map(\.speaker))
        let localText = utterances.map(\.text).joined(separator: " ")
        let referenceText = (reference["text"] as? String) ?? ""

        print("")
        print("--- against the AssemblyAI reference ---")
        print("voices:   \(Set(utterances.map(\.speaker)).count) local vs \(referenceSpeakers.count) reference")

        let wer = wordErrorRate(hypothesis: localText, reference: referenceText)
        print(String(format: "WER:      %.1f%% (%d reference words)",
                     wer * 100, words(referenceText).count))

        // Two separate failures, reported separately, because conflating them
        // hides which one is actually happening. Coverage: does the local
        // transcript have anything at all where the reference heard speech?
        // Purity: where it does, is that window one speaker or several?
        // Speaker labels are arbitrary between systems, so comparing them
        // directly would measure nothing.
        var covered = 0, pure = 0
        for r in referenceUtterances {
            let overlapping = utterances.filter { $0.start < r.end && $0.end > r.start }
            guard !overlapping.isEmpty else { continue }
            covered += 1
            if Set(overlapping.map(\.speaker)).count == 1 { pure += 1 }
        }
        let total = referenceUtterances.count
        print(String(format: "coverage: %.1f%% — %d of %d reference turns have local speech",
                     Double(covered) / Double(max(total, 1)) * 100, covered, total))
        print(String(format: "purity:   %.1f%% — %d of those %d map to a single local speaker",
                     Double(pure) / Double(max(covered, 1)) * 100, pure, covered))
        print(String(format: "grouping: %d local utterances vs %d reference turns",
                     utterances.count, total))

        print("")
        print("first three local utterances:")
        for u in utterances.prefix(3) {
            print("  [\(Transcript.timestamp(u.start))] \(u.speaker): \(u.text.prefix(70))")
        }
        print("first three reference utterances:")
        for u in referenceUtterances.prefix(3) {
            print("  [\(Transcript.timestamp(u.start))] \(u.speaker): \(u.text.prefix(70))")
        }
        print(String(format: "reference: median turn %.1fs",
                     referenceUtterances.map { $0.end - $0.start }.sorted()[
                        max(0, referenceUtterances.count / 2)]))
        return 0
    }

    /// The reference response's utterances. Parsed here rather than through
    /// the Adapter's own mapper, which is internal to BraidCore — a
    /// measurement tool should not widen the library's API.
    private static func parseReference(_ json: [String: Any]) -> [Utterance] {
        guard let raw = json["utterances"] as? [[String: Any]] else { return [] }
        return raw.compactMap { u in
            guard let text = u["text"] as? String,
                  let start = u["start"] as? Double,
                  let end = u["end"] as? Double else { return nil }
            return Utterance(speaker: u["speaker"] as? String ?? "A",
                             start: start / 1000, end: end / 1000, text: text)
        }
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Standard Levenshtein over word tokens.
    private static func wordErrorRate(hypothesis: String, reference: String) -> Double {
        let h = words(hypothesis), r = words(reference)
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        var previous = Array(0...h.count)
        var current = [Int](repeating: 0, count: h.count + 1)
        for i in 1...r.count {
            current[0] = i
            for j in 1...h.count {
                let cost = r[i - 1] == h[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return Double(previous[h.count]) / Double(r.count)
    }

    private static func peakMemoryMB() -> Int {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        // Darwin reports ru_maxrss in bytes.
        return Int(usage.ru_maxrss) / 1_048_576
    }
}

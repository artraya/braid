import Foundation
import BraidCore
import MLXLLM
import MLXLMCommon
import os

/// Summarisation on an open-weights model running in-process through MLX.
///
/// Exists because Apple's on-device model refuses subjects, not just unsafe
/// content: it declined an entire recorded discussion of a news story about
/// named public figures, and no guardrail setting, use case or instruction
/// reached that decision (measured 2026-08-02, ADR-0006). Open weights carry no
/// such training, so a session Apple will not touch summarises normally here.
///
/// The trade is weight. This loads a couple of gigabytes into a machine with
/// eight, which is only survivable because summarisation happens after Stop,
/// strictly after ASR and diarization have finished and released theirs, and
/// because the model is dropped the moment the Job ends.
///
/// **All MLX API contact is confined to `generate(system:user:)`.** Everything
/// else here — prompting, chunking, parsing — is plain Swift. mlx-swift-examples
/// moves quickly and its generation API has changed shape several times; keeping
/// the blast radius to one function means a version bump is a small edit rather
/// than a rewrite.
public struct MLXSummariser: Sendable, NoteSummarising {
    /// Models worth offering on an 8GB machine, all 4-bit. Qwen3 is the default
    /// for instruction-following; Gemma writes more naturally but is heavier.
    public enum Model: String, Sendable, Codable, CaseIterable {
        case qwen3_4b = "mlx-community/Qwen3-4B-4bit"
        case qwen25_3b = "mlx-community/Qwen2.5-3B-Instruct-4bit"
        case gemma3_4b = "mlx-community/gemma-3-4b-it-4bit"

        public var label: String {
            switch self {
            case .qwen3_4b: "Qwen3 4B"
            case .qwen25_3b: "Qwen2.5 3B (lightest)"
            case .gemma3_4b: "Gemma 3 4B"
            }
        }

        /// Rough download size, so Settings can warn before it starts.
        public var approximateGB: Double {
            switch self {
            case .qwen3_4b: 2.3
            case .qwen25_3b: 1.7
            case .gemma3_4b: 2.5
            }
        }

        /// Characters of transcript to send in one pass. These models carry
        /// 32k-token context, so an hour of meeting fits without map-reduce —
        /// which is the other reason to prefer them: no summary-of-summaries
        /// step, so nothing is lost between passes.
        public var singlePassLimit: Int { 40_000 }

        /// Qwen3 reasons before answering unless told not to. Summarising a
        /// transcript is extraction, not a puzzle, and the thinking competes
        /// with the answer for the same token budget.
        public var suppressesThinking: Bool { self == .qwen3_4b }
    }

    let model: Model
    let log = Logger(subsystem: "no.braid.app", category: "pipeline")

    /// Set by `--summary-check` so a diagnostic run can show what the model
    /// actually replied, rather than only what survived parsing.
    public nonisolated(unsafe) static var verbose = false

    public init(model: Model = .qwen3_4b) {
        self.model = model
    }

    // MARK: - Summarising

    public func summarise(transcript: Transcript, session: Session,
                          preset: Preset) async throws -> SummaryOutput {
        let body = transcript.markdown()
        guard !body.isEmpty else {
            throw PipelineError.permanent("summariser: nothing was transcribed")
        }

        // Long enough to need cutting is rare at 32k context, but an all-day
        // recording is still possible. Same shape as the Apple path: digest the
        // parts, then shape the digest.
        let source: String
        let condensed: Bool
        if body.count <= model.singlePassLimit {
            source = body
            condensed = false
        } else {
            source = try await digest(transcript: transcript)
            condensed = true
            log.notice("mlx summarise: \(body.count) chars condensed to \(source.count)")
        }

        var prompt = ""
        if !session.participants.isEmpty {
            prompt += "Participant name hints: \(session.participants.joined(separator: ", "))\n\n"
        }
        prompt += condensed
            ? "Notes taken across the whole session, in order:\n\n\(source)"
            : "Transcript:\n\n\(source)"
        // The output contract goes last, in the user turn. In the system turn,
        // after the Preset's "you write notes" framing, it was ignored three
        // times running — a 4B model weights the most recent instruction far
        // more heavily than a distant one. No title is sent in: the Note's
        // title now comes back out of this reply (R9a), and a model handed one
        // echoes it as a heading rather than improving on it.
        prompt += "\n\n" + Self.outputContract(headings: Self.headings(in: preset))
            + (model.suppressesThinking ? "\n\n/no_think" : "")

        let raw = try await generate(system: preset.prompt, user: prompt)
        if Self.verbose {
            print("--- raw model reply (\(raw.count) chars) ---\n\(raw)\n--- end ---")
        }
        let reply = ModelReply.parse(raw)
        guard !reply.body.isEmpty else {
            throw PipelineError.permanent("summariser: the model returned nothing usable")
        }
        return SummaryOutput(noteBody: reply.body, title: reply.title)
    }

    /// Cuts a very long Session into parts, summarises each, and returns the
    /// joined result for a final shaping pass.
    private func digest(transcript: Transcript) async throws -> String {
        var parts: [String] = []
        var current = ""
        for utterance in transcript.utterances {
            let line = "- **\(Transcript.timestamp(utterance.start)) \(utterance.speaker):** \(utterance.text)"
            if !current.isEmpty, current.count + line.count > model.singlePassLimit / 2 {
                parts.append(current)
                current = line
            } else {
                current += current.isEmpty ? line : "\n" + line
            }
        }
        if !current.isEmpty { parts.append(current) }

        var digested: [String] = []
        for (index, part) in parts.enumerated() {
            let text = try await generate(
                system: """
                    You compress meeting transcripts without losing specifics. Never invent \
                    content, and never attribute anything to a speaker the transcript does \
                    not attribute it to. Reply with a plain markdown bullet list and nothing else.
                    """,
                user: """
                    This is part \(index + 1) of \(parts.count) of a meeting transcript. \
                    List everything of substance that happens in it.

                    \(part)
                    """)
            digested.append(ModelReply.clean(text))
        }
        return digested.joined(separator: "\n")
    }

    // MARK: - Prompting and parsing

    /// The Preset supplies the headings; this supplies the output contract.
    ///
    /// Apple's path gets its structure enforced by a generation schema. There is
    /// no constrained decoding here, so the shape has to be asked for in words
    /// and then normalised on the way out — which is why `clean` exists and is
    /// forgiving.
    /// Apple's path has its structure enforced by a generation schema. Here
    /// there is no constrained decoding, so the shape has to be asked for —
    /// and JSON is what these models are actually drilled on, far more than
    /// "produce a `## Heading` for each item". It also lets both engines render
    /// through the same code, so a Note looks the same whichever wrote it.
    static func outputContract(headings: String?) -> String {
        // The headings are repeated here, beside the instruction, because
        // listing them only in the system turn got the model inventing its own
        // ("Personal Struggles and Loss" instead of "Key points"). They read
        // better in isolation and are useless in a vault: R12 says the Preset
        // decides the sections, and a note is searchable because every meeting
        // files things under the same headings.
        let list = headings.map {
            "The headings, to use exactly as written and in this order: \($0)\n\n"
        } ?? ""
        return """
        \(list)Now reply with a single JSON object and nothing else — no markdown, no \
        code fence, no commentary before or after it. Use exactly this shape:

        {"title": "four to eight words naming what this session was about",
         "summary": "two to four sentences of plain prose about the session",
         "sections": [{"heading": "a heading copied exactly from the list above",
                       "bullets": ["one point", "another point"]}]}

        The title becomes the note's filename, so write it the way a person would \
        name a file: no date, no time, no quotation marks, no trailing full stop. \
        Use the given headings verbatim — do not invent your own, reword them, or \
        merge them. Nearly every session has something for the first heading, so fill \
        it; omit a later heading only when the transcript truly contains nothing of \
        that kind. Keep names, numbers, dates and commitments exactly as the transcript \
        states them.
        """
    }

    /// The heading list out of a Preset, which states it as
    /// `Headings: Key points, Decisions, ...`. Returns nil for a Preset the
    /// user has rewritten without that line, in which case the contract falls
    /// back to referring to the headings generically.
    static func headings(in preset: Preset) -> String? {
        guard let range = preset.prompt.range(of: "Headings:") else { return nil }
        // Everything after the marker: the shipped Presets put the list last,
        // and it wraps across lines, so this is a tail rather than a line.
        let cleaned = preset.prompt[range.upperBound...]
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    // Parsing lives in BraidCore as `ModelReply`, where the fast test loop can
    // reach it: `swift build` cannot compile MLX's Metal shaders, so anything
    // in this target is untestable by `swift test`. It is also not really MLX's
    // business — it is about what small models do to JSON.

    // MARK: - The only MLX-specific code

    /// Loads the model, generates once, and lets it go.
    ///
    /// Deliberately not cached across calls. Holding two gigabytes resident
    /// between meetings on an 8GB machine would undo the deferral rule that the
    /// whole local pipeline rests on (R4, ADR-0005); a Job pays the load each
    /// time, which is seconds against a summary that takes longer than that
    /// anyway.
    private func generate(system: String, user: String) async throws -> String {
        do {
            let container = try await MLXLMCommon.loadModelContainer(
                configuration: ModelConfiguration(id: model.rawValue))
            // A low temperature because this is extraction, not composition:
            // the summary should follow the transcript rather than write around
            // it. `maxTokens` is a stop, not a target — a note that long has
            // already gone wrong, and without it a small model can loop.
            let session = ChatSession(
                container,
                instructions: system,
                generateParameters: GenerateParameters(maxTokens: 4_096, temperature: 0.3))
            return try await session.respond(to: user)
        } catch {
            throw PipelineError.permanent("summariser (mlx): \(error.localizedDescription)")
        }
    }

    /// Fetches the weights so the first Session after switching does not stall
    /// on a multi-gigabyte download.
    public func prepare(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        do {
            _ = try await MLXLMCommon.loadModelContainer(
                configuration: ModelConfiguration(id: model.rawValue)
            ) { fetched in
                progress?(fetched.fractionCompleted)
            }
        } catch {
            throw PipelineError.permanent("could not fetch \(model.label): \(error.localizedDescription)")
        }
    }
}

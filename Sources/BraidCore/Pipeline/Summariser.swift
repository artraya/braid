import Foundation
import FoundationModels
import os

/// The Note body a Summariser produced. No token counts: nothing is metered
/// any more (R14, retired with the cloud).
public struct SummaryOutput: Sendable {
    public let noteBody: String

    public init(noteBody: String) {
        self.noteBody = noteBody
    }
}

/// What the pipeline needs from a summariser. Exists so tests can drive a Job
/// to completion without loading a model, and so a better on-device engine can
/// replace this one on evidence rather than on a rewrite (ADR-0006).
public protocol NoteSummarising: Sendable {
    func summarise(transcript: Transcript, session: Session,
                   preset: Preset) async throws -> SummaryOutput
}

/// Summarisation on Apple's on-device foundation model (ADR-0006).
///
/// The model's context window is a few thousand tokens and an hour of meeting
/// is far more than that, so anything long is summarised map-reduce: each slice
/// of the Transcript is compressed to bullets, and the Preset then shapes those
/// bullets into the Note. That is why R11 requires a Note to reference both the
/// first and last ten minutes of a long Session — a single-pass summariser
/// silently truncated to the window would pass every other check while quietly
/// losing the back half of every long call.
///
/// **Schemas are built by hand, not with `@Generable`.** The macro lives in a
/// compiler plugin that ships with Xcode, and ADR-0004 builds this app with
/// Command Line Tools alone; `DynamicGenerationSchema` is the same guided
/// generation without the macro, so the toolchain decision stands and the cost
/// is the `schema` and `parse` sections below.
public struct AppleSummariser: Sendable, NoteSummarising {
    /// Transcript characters that comfortably fit one pass alongside the
    /// instructions and the model's own output. Roughly 3.5 characters to a
    /// token, against a few thousand tokens of window, kept well clear of the
    /// edge because exceeding it costs a whole retry.
    static let singlePassLimit = 6_000
    /// Slice size for the map stage, smaller again so each slice leaves room
    /// for its own bullets.
    static let sliceLimit = 3_500

    let log = Logger(subsystem: "no.braid.app", category: "pipeline")

    public init() {}

    /// Whether the model is usable right now. Surfaced in Settings so a Mac
    /// with Apple Intelligence switched off says so before a Session rather
    /// than after one.
    public static var availability: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is switched off — turn it on in System Settings so Braid can write Notes."
        case .unavailable(.modelNotReady):
            return "The on-device model is still downloading. Notes will be written once it is ready."
        case .unavailable(.deviceNotEligible):
            return "This Mac cannot run the on-device model."
        case .unavailable:
            return "The on-device model is unavailable."
        }
    }

    public func summarise(transcript: Transcript, session: Session,
                          preset: Preset) async throws -> SummaryOutput {
        if let problem = Self.availability {
            throw PipelineError.permanent("summariser: \(problem)")
        }

        let body = transcript.markdown()
        let source: String
        let condensed: Bool
        if body.count <= Self.singlePassLimit {
            source = body
            condensed = false
        } else {
            source = try await condense(transcript: transcript)
            condensed = true
            log.notice("summarise: \(body.count) chars condensed to \(source.count) before the Note pass")
        }
        return SummaryOutput(noteBody: try await write(preset: preset, session: session,
                                                       source: source, condensed: condensed))
    }

    // MARK: - Schemas

    private static func string() -> DynamicGenerationSchema {
        DynamicGenerationSchema(type: String.self)
    }

    private static func stringList(min: Int) -> DynamicGenerationSchema {
        DynamicGenerationSchema(arrayOf: string(), minimumElements: min)
    }

    /// The Note, as a structure rather than as prose the app has to parse.
    ///
    /// Guided generation is what makes a small on-device model usable here: it
    /// fills fields instead of being trusted to remember a markdown convention,
    /// and a malformed answer is a decoding error rather than a Note with a
    /// missing heading. The shape is deliberately generic — headings come from
    /// the Preset — so all four shipped Presets and any the user writes work
    /// through one schema (R11, R12).
    static func noteSchema() throws -> GenerationSchema {
        let section = DynamicGenerationSchema(
            name: "Section",
            description: "One section of the note.",
            properties: [
                .init(name: "heading",
                      description: "The section heading, worded exactly as the instructions name it.",
                      schema: string()),
                .init(name: "bullets",
                      description: "One bullet per point, each a complete sentence. Keep names, numbers, dates and commitments exactly as the transcript states them.",
                      schema: stringList(min: 1)),
            ])
        let note = DynamicGenerationSchema(
            name: "Note",
            description: "A structured summary of one recorded session.",
            properties: [
                .init(name: "summary",
                      description: "Two to four sentences on what this session was about and what came out of it. Plain prose, no bullet points, no heading.",
                      schema: string()),
                .init(name: "sections",
                      description: "The sections named in the instructions, in the order given. Omit a section entirely when the transcript holds nothing for it rather than inventing filler.",
                      schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(referenceTo: "Section"))),
            ])
        return try GenerationSchema(root: note, dependencies: [section])
    }

    /// One slice of a long Session, compressed but not yet shaped into a Note.
    static func digestSchema() throws -> GenerationSchema {
        let digest = DynamicGenerationSchema(
            name: "Digest",
            description: "The substance of one part of a conversation.",
            properties: [
                .init(name: "bullets",
                      description: "Everything of substance in this part of the conversation, one bullet per point, in the order it happened. Preserve speaker names, numbers, dates, decisions and commitments verbatim. Do not summarise away specifics.",
                      schema: stringList(min: 1)),
            ])
        return try GenerationSchema(root: digest, dependencies: [])
    }

    // MARK: - Map: condense a long Session

    /// Compresses the Transcript until it fits one pass.
    ///
    /// Loops rather than recurses: a very long Session may need its digests
    /// digested. Each round must actually shrink the text, so a round that
    /// fails to make progress stops instead of spinning.
    private func condense(transcript: Transcript) async throws -> String {
        let schema = try Self.digestSchema()
        var parts = slices(of: transcript)
        var round = 0

        while true {
            var digested: [String] = []
            for (index, slice) in parts.enumerated() {
                let session = LanguageModelSession(instructions: """
                    You compress meeting transcripts without losing specifics. You never \
                    invent content, and you never attribute anything to a speaker the \
                    transcript does not attribute it to.
                    """)
                let content = try await respond(session, schema: schema, prompt: """
                    This is part \(index + 1) of \(parts.count) of a meeting transcript. \
                    List everything of substance that happens in it.

                    \(slice)
                    """)
                let bullets = (try? content.value([String].self, forProperty: "bullets")) ?? []
                digested.append(bullets.map { "- \($0)" }.joined(separator: "\n"))
            }

            let joined = digested.joined(separator: "\n")
            if joined.count <= Self.singlePassLimit { return joined }

            round += 1
            let regrouped = regroup(joined)
            // No progress, or too many rounds: take the front of what we have
            // rather than looping forever. Truncation is a real loss, so it is
            // logged rather than hidden.
            guard regrouped.count < parts.count, round < 3 else {
                log.warning("transcript still \(joined.count) chars after \(round) condensing round(s); truncating")
                return String(joined.prefix(Self.singlePassLimit))
            }
            parts = regrouped
        }
    }

    /// Splits the Transcript on utterance boundaries, never mid-sentence, so a
    /// slice always reads as conversation.
    func slices(of transcript: Transcript) -> [String] {
        var out: [String] = []
        var current = ""
        for utterance in transcript.utterances {
            let line = "- **\(Transcript.timestamp(utterance.start)) \(utterance.speaker):** \(utterance.text)"
            if !current.isEmpty, current.count + line.count > Self.sliceLimit {
                out.append(current)
                current = line
            } else {
                current += current.isEmpty ? line : "\n" + line
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private func regroup(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if !current.isEmpty, current.count + line.count > Self.sliceLimit {
                out.append(current)
                current = String(line)
            } else {
                current += current.isEmpty ? String(line) : "\n" + line
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    // MARK: - Reduce: shape the Note

    private func write(preset: Preset, session: Session,
                       source: String, condensed: Bool) async throws -> String {
        var prompt = "Title: \(session.title)\n"
        if !session.participants.isEmpty {
            prompt += "Participant name hints: \(session.participants.joined(separator: ", "))\n"
        }
        prompt += condensed
            ? "\nNotes taken across the whole session, in order:\n\n\(source)"
            : "\nTranscript:\n\n\(source)"

        let modelSession = LanguageModelSession(instructions: preset.prompt)
        let content = try await respond(modelSession, schema: try Self.noteSchema(), prompt: prompt)
        return Self.render(content)
    }

    /// One model call, with the framework's failures translated into the
    /// pipeline's vocabulary.
    ///
    /// Only a timeout is worth retrying: a context overflow needs smaller
    /// input and a guardrail refusal needs a human, and neither gets better by
    /// being run again in thirty seconds.
    private func respond(_ session: LanguageModelSession, schema: GenerationSchema,
                         prompt: String) async throws -> GeneratedContent {
        do {
            return try await session.respond(to: prompt, schema: schema).content
        } catch let error as LanguageModelError {
            switch error {
            case .contextSizeExceeded:
                throw PipelineError.permanent("summariser: too much text for one pass")
            case .guardrailViolation, .refusal:
                throw PipelineError.permanent(
                    "summariser: the on-device model declined to summarise this session")
            case .timeout, .rateLimited:
                throw PipelineError.transient("summariser: \(error.localizedDescription)")
            default:
                throw PipelineError.permanent("summariser: \(error.localizedDescription)")
            }
        } catch let error as PipelineError {
            throw error
        } catch {
            throw PipelineError.permanent("summariser: \(error.localizedDescription)")
        }
    }

    // MARK: - Rendering

    /// Markdown, assembled here rather than by the model. Whatever the model
    /// does with formatting, the Note's shape is ours.
    ///
    /// Every field is read defensively: a section the model returned without
    /// bullets is dropped, not fatal. A Note missing one heading is worth
    /// delivering; failing the whole Job over it is not.
    static func render(_ content: GeneratedContent) -> String {
        var out = ((try? content.value(String.self, forProperty: "summary")) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let sections = (try? content.value([GeneratedContent].self, forProperty: "sections")) ?? []
        for section in sections {
            let heading = ((try? section.value(String.self, forProperty: "heading")) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let bullets = ((try? section.value([String].self, forProperty: "bullets")) ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !heading.isEmpty, !bullets.isEmpty else { continue }
            out += "\n\n## \(heading)\n"
            out += bullets.map { "- \($0)" }.joined(separator: "\n")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

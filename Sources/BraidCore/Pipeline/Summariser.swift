import Foundation
import FoundationModels
import os

/// The Note body a Summariser produced. No token counts: nothing is metered
/// any more (R14, retired with the cloud).
public struct SummaryOutput: Sendable {
    public let noteBody: String
    /// What the model thinks this session should be called (R9a), already
    /// vetted by `Session.cleanTitle`. Nil when it offered nothing usable, or
    /// when the note came from a salvage path that never got to ask.
    public let title: String?
    /// What the call consumed, when the Engine meters anything. Nil for every
    /// on-device Engine, because nothing they do costs money (R14).
    public let usage: SummaryUsage?

    public init(noteBody: String, title: String? = nil, usage: SummaryUsage? = nil) {
        self.noteBody = noteBody
        self.title = title
        self.usage = usage
    }
}

/// Tokens one metered summarising call consumed, and what they cost.
public struct SummaryUsage: Sendable, Equatable, Codable {
    public var promptTokens: Int
    public var replyTokens: Int
    /// Dollars, already converted at the model's rate by whoever made the call:
    /// the rate belongs to the Engine, not to the pipeline that stores this.
    public var costUSD: Double

    public init(promptTokens: Int = 0, replyTokens: Int = 0, costUSD: Double = 0) {
        self.promptTokens = promptTokens
        self.replyTokens = replyTokens
        self.costUSD = costUSD
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
    /// Slice size when recovering from a refusal. Roughly one speaking turn, so
    /// a passage the model will not touch costs that passage and nothing else.
    static let salvageSliceLimit = 400

    let log = Logger(subsystem: "no.braid.app", category: "pipeline")

    public init() {}

    /// The model refused. Kept separate from `PipelineError` because it must
    /// never park a Job: a guardrail decision is deterministic, so retrying it
    /// in thirty seconds or thirty days gives the same answer.
    struct Declined: Error {
        /// Which of the model's two refusal modes fired, and what it said.
        /// Carried because they mean different things: a guardrail is a safety
        /// filter on the text, a refusal is the model itself declining, and only
        /// the first is affected by the guardrails setting.
        var reason: String
    }

    /// Set by `--summary-check` so a diagnostic run can say precisely which
    /// pass refused and why, without putting model chatter in the pipeline log.
    public nonisolated(unsafe) static var verbose = false

    /// Guardrails set to `permissiveContentTransformations`, which is what
    /// Apple provides for apps that *transform* content the user already has
    /// rather than generate new content. Braid summarises a recording its owner
    /// made of their own meeting; the default guardrails treat that text as if
    /// the app had prompted for it, and refuse whole sessions over ordinary
    /// conversation — one real call was declined over a passing remark about a
    /// babysitter. The model still refuses genuinely unacceptable content, and
    /// `Declined` handles that without costing the user their meeting.
    private var model: SystemLanguageModel {
        SystemLanguageModel(guardrails: .permissiveContentTransformations)
    }

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

        // The straightforward path: short enough for one pass, and the model
        // is willing.
        if body.count <= Self.singlePassLimit,
           let note = try await attemptNote(preset: preset, session: session,
                                            source: body, condensed: false) {
            return SummaryOutput(noteBody: note.body, title: note.title)
        }

        // Either it is a long Session, or the model refused the whole thing.
        //
        // A refusal is not a filter Braid can configure away — it is the model
        // declining a topic, and measurement showed it refuses the *whole*
        // transcript over one or two passages while summarising every other
        // line quite happily. So the recovery is the same machinery long
        // meetings already use: cut the Transcript up, summarise what the model
        // will take, and mark what it would not. Half a meeting summarised is
        // worth far more than none.
        let fine = body.count > Self.singlePassLimit ? Self.sliceLimit : Self.salvageSliceLimit
        let digested = await digest(transcript: transcript, sliceLimit: fine)

        if digested.kept > 0,
           let note = try await attemptNote(preset: preset, session: session,
                                            source: digested.text, condensed: true) {
            return SummaryOutput(noteBody: digested.refused == 0
                                 ? note.body
                                 : note.body + "\n\n" + Self.gapNotice(digested),
                                 title: note.title)
        }

        // The note pass refused even the model's own paraphrase. The digest
        // bullets are still real notes, so hand those over rather than nothing.
        if digested.kept > 0 {
            log.warning("the note pass was declined; delivering the salvaged digest")
            return SummaryOutput(noteBody: Self.salvagedBody(digested))
        }

        log.warning("the on-device model declined every part of this session")
        return SummaryOutput(noteBody: Self.declinedBody)
    }

    /// A shaped Note: the body, and the title the model gave it.
    struct Note {
        var title: String?
        var body: String
    }

    /// One attempt at the shaped Note. `nil` means the model declined, which is
    /// a routing decision here rather than an error.
    private func attemptNote(preset: Preset, session: Session,
                             source: String, condensed: Bool) async throws -> Note? {
        do {
            return try await write(preset: preset, session: session,
                                   source: source, condensed: condensed)
        } catch let declined as Declined {
            if Self.verbose { print("DECLINED at the note pass: \(declined.reason)") }
            log.notice("note pass declined (\(declined.reason, privacy: .public))")
            return nil
        }
    }

    static func gapNotice(_ digest: Digest) -> String {
        """
        > Apple's on-device model declined to summarise \(digest.refused) of \
        \(digest.refused + digest.kept) parts of this session, so anything said in \
        those parts is missing from the summary above. The transcript is complete.
        """
    }

    static func salvagedBody(_ digest: Digest) -> String {
        """
        Apple's on-device model would not shape this session into a note, but it did \
        summarise \(digest.kept) of \(digest.refused + digest.kept) parts of it. Those \
        notes are below, in the order they were said. The transcript linked above is \
        complete and unaffected.

        ## Notes
        \(digest.text)
        """
    }

    public static let declinedBody = """
        Apple's on-device model would not summarise any part of this session, so this \
        note has no summary. Nothing else was lost: the full transcript is linked above \
        and is exactly as recorded.

        This is the model declining a subject, not a transcription problem. It is a \
        judgement built into the model itself rather than a setting Braid can change, \
        and it will decide the same way every time, so retrying will not help. Braid \
        tried the whole session, then each part of it separately, and this one was \
        refused throughout.
        """

    // MARK: - Diagnosing a refusal

    /// Tries the same text several ways and reports which the model will
    /// accept. Exists because "the model declined" is not one thing: a
    /// guardrail violation is a configurable safety filter, while a refusal is
    /// the model's own training, and only experiment distinguishes what a given
    /// recording is hitting.
    public static func probe(transcript: Transcript, preset: Preset) async -> [String] {
        var findings: [String] = []
        let body = transcript.markdown()

        func attempt(_ label: String, _ work: () async throws -> String) async {
            do {
                let text = try await work()
                let preview = text.replacingOccurrences(of: "\n", with: " ").prefix(90)
                findings.append("  OK        \(label) — \(preview)…")
            } catch let declined as Declined {
                findings.append("  DECLINED  \(label) — \(declined.reason)")
            } catch {
                findings.append("  ERROR     \(label) — \(error.localizedDescription)")
            }
        }

        let summariser = AppleSummariser()
        let neutral = """
            You extract factual notes from a recording the user made of their own \
            conversation. You are a transcription tool, not a participant: you do not \
            evaluate, endorse, fact-check or comment on anything said, and you do not \
            refuse on the basis of the topic. Report only what was said and by whom.
            """

        await attempt("preset instructions, structured") {
            let session = LanguageModelSession(model: summariser.model, instructions: preset.prompt)
            return Self.render(try await summariser.respond(
                session, schema: try Self.noteSchema(), prompt: "Transcript:\n\n\(body)"))
        }
        await attempt("neutral instructions, structured") {
            let session = LanguageModelSession(model: summariser.model, instructions: neutral)
            return Self.render(try await summariser.respond(
                session, schema: try Self.noteSchema(), prompt: "Transcript:\n\n\(body)"))
        }
        await attempt("content-tagging use case, structured") {
            let tagging = SystemLanguageModel(useCase: .contentTagging,
                                              guardrails: .permissiveContentTransformations)
            let session = LanguageModelSession(model: tagging, instructions: neutral)
            return Self.render(try await summariser.respond(
                session, schema: try Self.noteSchema(), prompt: "Transcript:\n\n\(body)"))
        }
        await attempt("digest schema only (what long meetings use)") {
            let session = LanguageModelSession(model: summariser.model, instructions: neutral)
            let content = try await summariser.respond(
                session, schema: try Self.digestSchema(),
                prompt: "List what happens in this transcript.\n\n\(body)")
            return ((try? content.value([String].self, forProperty: "bullets")) ?? []).joined(separator: "; ")
        }
        await attempt("default guardrails, preset instructions") {
            let session = LanguageModelSession(model: SystemLanguageModel.default,
                                               instructions: preset.prompt)
            return Self.render(try await summariser.respond(
                session, schema: try Self.noteSchema(), prompt: "Transcript:\n\n\(body)"))
        }

        // Per-utterance, to find whether one line is doing it or the whole thing.
        var refusedLines: [Int] = []
        for (index, utterance) in transcript.utterances.enumerated() {
            let session = LanguageModelSession(model: summariser.model, instructions: neutral)
            do {
                _ = try await summariser.respond(
                    session, schema: try Self.digestSchema(),
                    prompt: "List what happens here.\n\n\(utterance.text)")
            } catch is Declined {
                refusedLines.append(index + 1)
            } catch { }
        }
        findings.append(refusedLines.isEmpty
            ? "  line by line: every line is accepted on its own"
            : "  line by line: refused on line(s) \(refusedLines.map(String.init).joined(separator: ", "))")
        return findings
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
                .init(name: "title",
                      description: "A short title for this session, four to eight words, naming what it was actually about. No date, no time, no quotation marks, no trailing full stop. Write it as a person would name a file.",
                      schema: string()),
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

    /// What the map stage produced, and how much of the Session it covers.
    public struct Digest: Sendable {
        public var text: String
        /// Slices the model summarised.
        public var kept: Int
        /// Slices it declined. Their content is missing from `text`.
        public var refused: Int
    }

    /// Compresses the Transcript slice by slice until it fits one pass, keeping
    /// whatever the model is willing to summarise.
    ///
    /// Loops rather than recurses: a very long Session may need its digests
    /// digested. Each round must actually shrink the text, so a round that
    /// fails to make progress stops instead of spinning.
    ///
    /// Never throws on a refusal. A slice the model declines is simply absent
    /// from the result and counted, which is what lets a Session with one
    /// objectionable passage still produce a note about the rest.
    func digest(transcript: Transcript, sliceLimit: Int) async -> Digest {
        guard let schema = try? Self.digestSchema() else {
            return Digest(text: "", kept: 0, refused: 0)
        }
        var parts = slices(of: transcript, limit: sliceLimit)
        var totalKept = 0, totalRefused = 0
        var round = 0

        while true {
            var digested: [String] = []
            var kept = 0, declined = 0
            for (index, slice) in parts.enumerated() {
                let session = LanguageModelSession(model: model, instructions: """
                    You compress meeting transcripts without losing specifics. You never \
                    invent content, and you never attribute anything to a speaker the \
                    transcript does not attribute it to.
                    """)
                do {
                    let content = try await respond(session, schema: schema, prompt: """
                        This is part \(index + 1) of \(parts.count) of a meeting transcript. \
                        List everything of substance that happens in it.

                        \(slice)
                        """)
                    let raw: [String] = (try? content.value([String].self, forProperty: "bullets")) ?? []
                    let bullets = raw
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    if bullets.isEmpty { continue }
                    digested.append(bullets.map { "- \($0)" }.joined(separator: "\n"))
                    kept += 1
                } catch let refusal as Declined {
                    declined += 1
                    if Self.verbose {
                        print("DECLINED slice \(index + 1)/\(parts.count): \(refusal.reason)")
                    }
                } catch {
                    declined += 1
                }
            }
            if round == 0 { totalKept = kept; totalRefused = declined }
            if declined > 0 {
                log.warning("the on-device model declined \(declined) of \(parts.count) transcript slice(s)")
            }

            let joined = digested.joined(separator: "\n")
            if joined.count <= Self.singlePassLimit {
                return Digest(text: joined, kept: totalKept, refused: totalRefused)
            }

            round += 1
            let regrouped = regroup(joined, limit: sliceLimit)
            // No progress, or too many rounds: take the front of what we have
            // rather than looping forever. Truncation is a real loss, so it is
            // logged rather than hidden.
            guard regrouped.count < parts.count, round < 3 else {
                log.warning("transcript still \(joined.count) chars after \(round) condensing round(s); truncating")
                return Digest(text: String(joined.prefix(Self.singlePassLimit)),
                              kept: totalKept, refused: totalRefused)
            }
            parts = regrouped
        }
    }

    /// Splits the Transcript on utterance boundaries, never mid-sentence, so a
    /// slice always reads as conversation.
    ///
    /// The limit is a parameter because the two callers want opposite things. A
    /// long Session wants big slices, for speed. A salvage pass after a refusal
    /// wants small ones: the smaller the slice, the less of the meeting one
    /// objectionable passage takes down with it.
    func slices(of transcript: Transcript, limit: Int) -> [String] {
        var out: [String] = []
        var current = ""
        for utterance in transcript.utterances {
            let line = "- **\(Transcript.timestamp(utterance.start)) \(utterance.speaker):** \(utterance.text)"
            if !current.isEmpty, current.count + line.count > limit {
                out.append(current)
                current = line
            } else {
                current += current.isEmpty ? line : "\n" + line
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private func regroup(_ text: String, limit: Int) -> [String] {
        var out: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if !current.isEmpty, current.count + line.count > limit {
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
                       source: String, condensed: Bool) async throws -> Note {
        // No title goes in. It used to, and the model echoed it straight back
        // as the first line of the summary; now the title comes *out* instead
        // (R9a), so telling it one would only anchor what it suggests.
        var prompt = ""
        if !session.participants.isEmpty {
            prompt += "Participant name hints: \(session.participants.joined(separator: ", "))\n"
        }
        prompt += condensed
            ? "\nNotes taken across the whole session, in order:\n\n\(source)"
            : "\nTranscript:\n\n\(source)"

        let modelSession = LanguageModelSession(model: model, instructions: preset.prompt)
        let content = try await respond(modelSession, schema: try Self.noteSchema(), prompt: prompt)
        return Note(title: Self.title(content), body: Self.render(content))
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
        // `LanguageModelSession.GenerationError` rather than the newer
        // `LanguageModelError`: the latter is macOS 27 only, and Xcode 26.6 —
        // the newest on the App Store — ships the 26.5 SDK. This one exists in
        // both, so Braid compiles under either toolchain, which matters because
        // MLX needs Xcode while everything else has been built with Command
        // Line Tools. It is deprecated under the newer SDK; that is the price.
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize:
                throw PipelineError.permanent("summariser: too much text for one pass")
            case .guardrailViolation:
                throw Declined(reason: "guardrailViolation — a safety filter on the text: \(error.localizedDescription)")
            case .refusal:
                throw Declined(reason: "refusal — the model itself declined: \(error.localizedDescription)")
            case .rateLimited, .concurrentRequests:
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
    /// The title field, vetted. Read separately from `render` because it never
    /// belongs in the Note's body — it becomes the filename (R9).
    static func title(_ content: GeneratedContent) -> String? {
        Session.cleanTitle(try? content.value(String.self, forProperty: "title"))
    }

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

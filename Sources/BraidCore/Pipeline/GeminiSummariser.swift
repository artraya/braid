import Foundation
import os

/// Summarisation on Google's Gemini API.
///
/// The reason this exists is measured, not aspirational. On the M3 Air this
/// app targets, an 86-minute Session took the on-device open-weights model 49
/// minutes and drove swap from 5GB to 11GB, and Apple's on-device model 23
/// minutes; both had to map-reduce the Transcript into pieces small enough to
/// fit, and the resulting Note covered one topic out of an hour and a half.
/// Flash-Lite carries a 1M-token context, so the same Transcript is one call,
/// one pass, no summary-of-summaries — which is as much a quality fix as a
/// speed one.
///
/// What that costs is stated plainly in ADR-0006 as amended: Transcript text
/// leaves this Mac. Audio never does, and neither does anything in the Voice
/// Database (ADR-0007) — no embedding, no Voiceprint, no clip.
public struct GeminiSummariser: Sendable, NoteSummarising {
    /// Reasonable models for this job. Flash-Lite is the default because
    /// Preset-structured extraction is not a task that needs a frontier model,
    /// and it is the cheapest tier that carries the full context window.
    public enum Model: String, Sendable, CaseIterable {
        case flashLite = "gemini-3.5-flash-lite"
        case flash = "gemini-3.5-flash"

        public var label: String {
            switch self {
            case .flashLite: "Gemini 3.5 Flash-Lite"
            case .flash: "Gemini 3.5 Flash"
            }
        }
    }

    /// Dollars per million tokens. Deliberately **not** hardcoded: published
    /// rates move, and a wrong number shown as spend is worse than no number.
    /// Both default to zero, which means the app reports tokens — which it
    /// measures exactly, from the API's own `usageMetadata` — and reports no
    /// dollar figure at all until someone fills in the current rate.
    public struct Rates: Sendable, Equatable, Codable {
        public var inputPerMTok: Double
        public var outputPerMTok: Double
        public init(inputPerMTok: Double = 0, outputPerMTok: Double = 0) {
            self.inputPerMTok = inputPerMTok
            self.outputPerMTok = outputPerMTok
        }

        public func cost(prompt: Int, reply: Int) -> Double {
            Double(prompt) / 1_000_000 * inputPerMTok
                + Double(reply) / 1_000_000 * outputPerMTok
        }
    }

    /// Characters of Transcript sent in one call. A 1M-token window is roughly
    /// 3.5M characters; this sits far below it, so it is a guard against an
    /// accidental all-day recording rather than a real ceiling. Nothing in
    /// normal use comes close: a 90-minute call is about 70,000.
    static let singlePassLimit = 1_500_000

    public static let endpoint = "https://generativelanguage.googleapis.com/v1beta/models"

    let model: Model
    let keys: APIKeyStore
    let rates: Rates
    let session: URLSession
    let log = Logger(subsystem: "no.braid.app", category: "pipeline")

    /// Set by `--summary-check` so a diagnostic run can show the raw reply.
    public nonisolated(unsafe) static var verbose = false

    public init(model: Model = .flashLite,
                keys: APIKeyStore = APIKeyStore(),
                rates: Rates = Rates(),
                session: URLSession = .shared) {
        self.model = model
        self.keys = keys
        self.rates = rates
        self.session = session
    }

    /// Why the cloud path cannot run right now, or nil. Surfaced in Settings so
    /// a missing key is a sentence before a Session rather than a failed Job
    /// after one.
    public var availability: String? {
        keys.hasKey ? nil : "No Gemini API key. Add one in Settings to summarise in the cloud."
    }

    // MARK: - Summarising

    public func summarise(transcript: Transcript, session: Session,
                          preset: Preset) async throws -> SummaryOutput {
        guard let key = keys.key() else {
            throw PipelineError.permanent("summariser: no Gemini API key configured")
        }
        let body = transcript.markdown()
        guard !body.isEmpty else {
            throw PipelineError.permanent("summariser: nothing was transcribed")
        }
        // Truncation is a last resort, and it is loud: R11 wants the whole
        // Session represented, so a Note built from a cut Transcript has to say
        // so rather than look complete.
        let source = body.count > Self.singlePassLimit
            ? String(body.prefix(Self.singlePassLimit)) : body
        if source.count < body.count {
            log.warning("transcript exceeded the single-pass limit and was cut")
        }

        var prompt = ""
        if !session.participants.isEmpty {
            prompt += "Participant name hints: \(session.participants.joined(separator: ", "))\n\n"
        }
        prompt += "Transcript:\n\n\(source)"
        if let headings = Self.headings(in: preset) {
            prompt += "\n\nThe headings, to use exactly as written and in this order: \(headings)"
        }
        prompt += "\n\n" + Self.titleGuidance

        let (raw, usage) = try await generate(system: preset.prompt, user: prompt, key: key)
        if Self.verbose {
            print("--- raw model reply (\(raw.count) chars) ---\n\(raw)\n--- end ---")
        }
        log.notice("""
            gemini \(model.rawValue, privacy: .public): \(usage.promptTokens) prompt + \
            \(usage.replyTokens) reply tokens
            """)
        // The schema is enforced server-side, so this is valid JSON rather than
        // something to be salvaged. `ModelReply` still does the rendering, so
        // every Engine produces the same markdown.
        let reply = ModelReply.parse(raw)
        guard !reply.body.isEmpty else {
            throw PipelineError.permanent("summariser: the model returned nothing usable")
        }
        return SummaryOutput(noteBody: reply.body, title: reply.title, usage: usage)
    }

    // MARK: - The only Gemini-specific code

    private func generate(system: String, user: String,
                          key: String) async throws -> (String, SummaryUsage) {
        guard let url = URL(string: "\(Self.endpoint)/\(model.rawValue):generateContent") else {
            throw PipelineError.permanent("summariser: bad endpoint")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The key rides in a header rather than the query string, so it cannot
        // end up in a proxy log or a crash report URL.
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 180
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": user]]]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseSchema": Self.schema,
                // Extraction, not composition: the Note should follow the
                // Transcript rather than write around it.
                "temperature": 0.3,
                "maxOutputTokens": 16_384,
            ],
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PipelineError.classify(transport: error, context: "summariser (gemini)")
        }
        try Task.checkCancellation()

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw PipelineError.classify(status: http.statusCode, body: text,
                                         context: "summariser (gemini)")
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PipelineError.permanent("summariser (gemini): unreadable reply")
        }
        let usage = Self.usage(from: object, at: rates)

        guard let candidates = object["candidates"] as? [[String: Any]],
              let first = candidates.first else {
            throw PipelineError.permanent("summariser (gemini): no candidates in the reply")
        }
        // A reply cut off mid-object would parse as broken JSON downstream; say
        // what actually happened instead.
        if let reason = first["finishReason"] as? String,
           reason != "STOP", reason != "MAX_TOKENS" {
            throw PipelineError.permanent("summariser (gemini): stopped early (\(reason))")
        }
        guard let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw PipelineError.permanent("summariser (gemini): no content in the reply")
        }
        let text = parts.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else {
            throw PipelineError.permanent("summariser (gemini): empty reply")
        }
        return (text, usage)
    }

    static func usage(from object: [String: Any], at rates: Rates) -> SummaryUsage {
        guard let meta = object["usageMetadata"] as? [String: Any] else { return SummaryUsage() }
        let prompt = meta["promptTokenCount"] as? Int ?? 0
        let reply = meta["candidatesTokenCount"] as? Int ?? 0
        return SummaryUsage(promptTokens: prompt, replyTokens: reply,
                            costUSD: rates.cost(prompt: prompt, reply: reply))
    }

    /// The same shape every Engine produces, enforced server-side rather than
    /// asked for in prose — which is the whole reason a cloud model needs no
    /// `ModelReply` salvage path.
    static var schema: [String: Any] { [
        "type": "object",
        "properties": [
            "title": ["type": "string"],
            "summary": ["type": "string"],
            "sections": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "heading": ["type": "string"],
                        "bullets": ["type": "array", "items": ["type": "string"]],
                    ],
                    "required": ["heading", "bullets"],
                ],
            ],
        ],
        "required": ["title", "summary", "sections"],
    ] }

    static let titleGuidance = """
        The title becomes the note's filename, so write it the way a person would \
        name a file: four to eight words, no date, no time, no quotation marks, no \
        trailing full stop. The summary is two to four sentences of plain prose. \
        Use the given headings verbatim — do not invent your own, reword them, or \
        merge them; drop a heading only when the session genuinely had nothing for \
        it. Attribute a point to a speaker only where the transcript attributes it, \
        and use the names the transcript uses.
        """

    /// The Preset's heading list, which R12 says decides the Note's sections.
    /// Same marker the open-weights path reads, so a Preset works under either.
    static func headings(in preset: Preset) -> String? {
        guard let range = preset.prompt.range(of: "Headings:") else { return nil }
        let cleaned = preset.prompt[range.upperBound...]
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}

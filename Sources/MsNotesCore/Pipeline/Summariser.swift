import Foundation
import os

/// The separate Claude API call that turns a Transcript into a Note (SPEC
/// Architecture): claude-opus-5 with adaptive thinking, plain URLSession HTTP
/// (zero dependencies, ADR-0004), never the Provider's bundled summariser.
public struct Summariser: Sendable {
    public struct Output: Sendable {
        public let noteBody: String
        public let inputTokens: Int
        public let outputTokens: Int
    }

    let apiKey: String
    let baseURL: URL
    let model = "claude-opus-5"
    let log = Logger(subsystem: "no.msnotes.app", category: "pipeline")

    public init(apiKey: String, baseURL: URL = URL(string: "https://api.anthropic.com")!) {
        self.apiKey = apiKey
        self.baseURL = baseURL
    }

    public func summarise(transcript: Transcript, session: Session,
                          preset: Preset) async throws -> Output {
        var userContent = "Title: \(session.title)\n"
        if !session.participants.isEmpty {
            userContent += "Participant name hints: \(session.participants.joined(separator: ", "))\n"
        }
        userContent += "\nTranscript:\n\n\(transcript.markdown())"

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 8_192,
            "thinking": ["type": "adaptive"],
            "system": preset.prompt,
            "messages": [["role": "user", "content": userContent]],
        ]
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        log.notice("summarise: model=\(model, privacy: .public) preset=\(preset.name, privacy: .public) chars=\(userContent.count)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw PipelineError.classify(transport: error, context: "summariser")
        }
        guard let http = response as? HTTPURLResponse else {
            throw PipelineError.permanent("summariser: no HTTP response")
        }
        let json = try AssemblyAIAdapter.json(data, http, context: "summariser")
        guard let content = json["content"] as? [[String: Any]] else {
            throw PipelineError.permanent("summariser: no content in response")
        }
        let text = content
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.isEmpty else {
            throw PipelineError.permanent("summariser: empty text in response")
        }
        let usage = json["usage"] as? [String: Any]
        return Output(
            noteBody: text.trimmingCharacters(in: .whitespacesAndNewlines),
            inputTokens: usage?["input_tokens"] as? Int ?? 0,
            outputTokens: usage?["output_tokens"] as? Int ?? 0)
    }
}

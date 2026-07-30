import Foundation
import os

/// The Provider abstraction: submits a Recording, returns per-Track utterances.
public protocol STTProvider: Sendable {
    var name: String { get }
    /// Transcribes one Track. `diarize: false` returns a single unlabelled
    /// speaker stream (the Adapter's caller labels the Mic Track "Me").
    func transcribe(track: URL, diarize: Bool, speakerRange: ClosedRange<Int>?,
                    keyTerms: [String]) async throws -> [Utterance]
}

/// AssemblyAI universal-3-5-pro (SPEC Architecture). Quirks owned here:
/// split-file submission (multichannel and diarization are mutually exclusive
/// per request), `speech_models` array (the old `speech_model` is rejected),
/// `language_code: en_au` always explicit (R6).
public struct AssemblyAIAdapter: STTProvider {
    public let name = "assemblyai"
    let apiKey: String
    let baseURL: URL
    let log = Logger(subsystem: "no.msnotes.app", category: "pipeline")

    public init(apiKey: String, baseURL: URL = URL(string: "https://api.assemblyai.com")!) {
        self.apiKey = apiKey
        self.baseURL = baseURL
    }

    public func transcribe(track: URL, diarize: Bool, speakerRange: ClosedRange<Int>?,
                           keyTerms: [String]) async throws -> [Utterance] {
        let uploadURL = try await upload(track)
        let id = try await submit(audioURL: uploadURL, diarize: diarize,
                                  speakerRange: speakerRange, keyTerms: keyTerms)
        return try await poll(id: id)
    }

    // MARK: - Steps

    func upload(_ file: URL) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("v2/upload"))
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "authorization")
        log.notice("assemblyai upload \(file.lastPathComponent, privacy: .public)")
        let (data, response) = try await send(request, uploadFile: file)
        let json = try Self.json(data, response, context: "upload")
        guard let url = json["upload_url"] as? String else {
            throw PipelineError.permanent("upload: no upload_url in response")
        }
        return url
    }

    /// The exact submission body. Split out so R6 can be verified against the
    /// real code rather than a reimplementation of it.
    public static func requestBody(audioURL: String, diarize: Bool,
                                   speakerRange: ClosedRange<Int>?,
                                   keyTerms: [String]) -> [String: Any] {
        var body: [String: Any] = [
            "audio_url": audioURL,
            "speech_models": ["universal-3-5-pro"],
            "language_code": "en_au",
            "speaker_labels": diarize,
        ]
        if diarize, let range = speakerRange {
            body["speaker_options"] = [
                "min_speakers_expected": range.lowerBound,
                "max_speakers_expected": range.upperBound,
            ]
        }
        if !keyTerms.isEmpty {
            body["keyterms_prompt"] = keyTerms
        }
        return body
    }

    /// Speaker hints per R6: the Remote Track gets a range of 1…(participants+1),
    /// or 1…6 when no Participants were given.
    public static func remoteSpeakerRange(participantCount: Int) -> ClosedRange<Int> {
        1...(participantCount == 0 ? 6 : participantCount + 1)
    }

    func submit(audioURL: String, diarize: Bool, speakerRange: ClosedRange<Int>?,
                keyTerms: [String]) async throws -> String {
        let body = Self.requestBody(audioURL: audioURL, diarize: diarize,
                                    speakerRange: speakerRange, keyTerms: keyTerms)
        var request = URLRequest(url: baseURL.appendingPathComponent("v2/transcript"))
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        // R6 check inspects these parameters; the API key is never logged.
        let logged = body.merging(["audio_url": "<uploaded>"]) { _, new in new }
        log.notice("assemblyai submit: \(String(describing: logged), privacy: .public)")
        let (data, response) = try await send(request)
        let json = try Self.json(data, response, context: "submit")
        if let error = json["error"] as? String {
            throw PipelineError.permanent("submit: \(error)")
        }
        guard let id = json["id"] as? String else {
            throw PipelineError.permanent("submit: no transcript id in response")
        }
        return id
    }

    func poll(id: String) async throws -> [Utterance] {
        var request = URLRequest(url: baseURL.appendingPathComponent("v2/transcript/\(id)"))
        request.setValue(apiKey, forHTTPHeaderField: "authorization")
        while true {
            let (data, response) = try await send(request)
            let json = try Self.json(data, response, context: "poll")
            switch json["status"] as? String {
            case "completed":
                return Self.utterances(from: json)
            case "error":
                let message = json["error"] as? String ?? "unknown provider error"
                throw PipelineError.permanent("transcription: \(message)")
            default:
                try await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Maps the provider response to canonical Utterances. Diarized responses
    /// carry `utterances[]` with A/B/C speakers; non-diarized responses may
    /// have no utterances — fall back to the full `text` as one utterance.
    static func utterances(from json: [String: Any]) -> [Utterance] {
        if let raw = json["utterances"] as? [[String: Any]], !raw.isEmpty {
            return raw.compactMap { u in
                guard let text = u["text"] as? String,
                      let start = u["start"] as? Double,
                      let end = u["end"] as? Double else { return nil }
                let speaker = u["speaker"] as? String ?? "A"
                return Utterance(speaker: speaker, start: start / 1000, end: end / 1000,
                                 text: text)
            }
        }
        if let text = json["text"] as? String, !text.isEmpty {
            let duration = (json["audio_duration"] as? Double) ?? 0
            return [Utterance(speaker: "A", start: 0, end: duration, text: text)]
        }
        return []
    }

    // MARK: - HTTP

    func send(_ request: URLRequest, uploadFile: URL? = nil) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response): (Data, URLResponse)
            if let uploadFile {
                (data, response) = try await URLSession.shared.upload(for: request, fromFile: uploadFile)
            } else {
                (data, response) = try await URLSession.shared.data(for: request)
            }
            guard let http = response as? HTTPURLResponse else {
                throw PipelineError.permanent("no HTTP response")
            }
            return (data, http)
        } catch let error as PipelineError {
            throw error
        } catch {
            throw PipelineError.classify(transport: error, context: "assemblyai")
        }
    }

    static func json(_ data: Data, _ response: HTTPURLResponse, context: String) throws -> [String: Any] {
        guard (200..<300).contains(response.statusCode) else {
            throw PipelineError.classify(
                status: response.statusCode,
                body: String(data: data, encoding: .utf8) ?? "",
                context: context)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PipelineError.permanent("\(context): malformed JSON response")
        }
        return json
    }
}

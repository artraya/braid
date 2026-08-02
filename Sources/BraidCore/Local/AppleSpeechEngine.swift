import Foundation
import AVFoundation
import Speech

/// Apple's on-device SpeechTranscriber (macOS 26+).
///
/// The lightweight option: no model ships with Braid and nothing is downloaded
/// into Application Support — the OS owns the locale assets and shares them
/// with every other app. It is also the only engine that can be told about Key
/// Terms, which arrive as contextual strings and bias recognition of the proper
/// nouns a transcriber would otherwise never guess.
public actor AppleSpeechEngine: TranscriberEngine {
    public nonisolated var id: LocalEngine { .apple }

    /// en-AU to match the cloud path's explicit `language_code: en_au` (R6);
    /// falls back to whatever equivalent the OS actually has installed.
    private let preferredLocale: Locale
    private var resolvedLocale: Locale?

    public init(locale: Locale = Locale(identifier: "en_AU")) {
        self.preferredLocale = locale
    }

    public var isReady: Bool {
        get async {
            guard SpeechTranscriber.isAvailable else { return false }
            return await locale(installedOnly: true) != nil
        }
    }

    public func prepare(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw LocalEngineError.modelsUnavailable("SpeechTranscriber is not available on this Mac")
        }
        if let installed = await locale(installedOnly: true) {
            resolvedLocale = installed
            progress?(1)
            return
        }
        guard let supported = await locale(installedOnly: false) else {
            throw LocalEngineError.localeUnavailable(
                "no installable speech locale matching \(preferredLocale.identifier)")
        }
        // The asset is Apple's to fetch; ask for it and wait.
        let transcriber = SpeechTranscriber(locale: supported, preset: .transcription)
        do {
            if let request = try await AssetInventory.assetInstallationRequest(
                supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch {
            throw LocalEngineError.localeUnavailable("\(error)")
        }
        resolvedLocale = supported
        progress?(1)
    }

    public func transcribe(file: URL, keyTerms: [String]) async throws -> EngineTranscript {
        try await prepare()
        guard let locale = resolvedLocale else {
            throw LocalEngineError.localeUnavailable("no locale resolved")
        }

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: file)
        } catch {
            throw LocalEngineError.transcriptionFailed("cannot read \(file.lastPathComponent): \(error)")
        }
        let duration = Double(audioFile.length) / audioFile.fileFormat.sampleRate

        // `.audioTimeRange` is what makes speaker alignment possible at all;
        // without it there is nothing to place words against.
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange])

        // Key Terms as contextual bias — the one accuracy lever the cloud path
        // has that Parakeet currently does not.
        let context = AnalysisContext()
        if !keyTerms.isEmpty {
            context.contextualStrings[.general] = keyTerms
        }

        do {
            // The plain `modules:` initializer, deliberately: the
            // `inputAudioFile:` one consumes the file itself, so pairing it
            // with `analyzeSequence` finishes the analyzer twice and traps.
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            if !keyTerms.isEmpty {
                try await analyzer.setContext(context)
            }
            if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            }
            // Drained after finishing: the results sequence terminates once the
            // analyzer has finalised, so this returns rather than hanging.
            let (text, words) = try await Self.collect(from: transcriber)

            return EngineTranscript(text: text, words: words, duration: duration)
        } catch let error as LocalEngineError {
            throw error
        } catch {
            throw LocalEngineError.transcriptionFailed("\(error)")
        }
    }

    /// Drains the transcriber's results into plain text plus word timings.
    ///
    /// Each result carries an `AttributedString` whose runs are tagged with the
    /// audio range they came from — that tagging is the word timing, so the
    /// runs are walked rather than the plain text.
    static func collect(
        from transcriber: SpeechTranscriber
    ) async throws -> (text: String, words: [TimedWord]) {
        var pieces: [String] = []
        var words: [TimedWord] = []
        let key = AttributeScopes.SpeechAttributes.TimeRangeAttribute.self

        for try await result in transcriber.results {
            let attributed = result.text
            let plain = String(attributed.characters)
            if !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pieces.append(plain)
            }
            for run in attributed.runs {
                guard let range = run[key] else { continue }
                let text = String(attributed[run.range].characters)
                    .trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                let start = range.start.seconds
                let end = (range.start + range.duration).seconds
                guard start.isFinite, end.isFinite else { continue }
                // A run can hold several words; they share the run's span,
                // which is still enough to attribute them to a speaker.
                let parts = text.split(separator: " ").map(String.init)
                if parts.count <= 1 {
                    words.append(TimedWord(text: text, start: start, end: end))
                } else {
                    let step = (end - start) / Double(parts.count)
                    for (i, part) in parts.enumerated() {
                        words.append(TimedWord(text: part,
                                               start: start + step * Double(i),
                                               end: start + step * Double(i + 1)))
                    }
                }
            }
        }
        let text = pieces.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, words.sorted { $0.start < $1.start })
    }

    /// The best locale the OS can give us: exact match, then Apple's own
    /// equivalent, checked against installed or merely supported.
    private func locale(installedOnly: Bool) async -> Locale? {
        let available = installedOnly
            ? await SpeechTranscriber.installedLocales
            : await SpeechTranscriber.supportedLocales
        let wanted = preferredLocale.identifier(.bcp47)
        if let exact = available.first(where: { $0.identifier(.bcp47) == wanted }) {
            return exact
        }
        if let equivalent = await SpeechTranscriber.supportedLocale(equivalentTo: preferredLocale),
           available.contains(where: { $0.identifier(.bcp47) == equivalent.identifier(.bcp47) }) {
            return equivalent
        }
        // Any English is better than failing outright on a machine set up for
        // one of the other English regions.
        return available.first { $0.language.languageCode?.identifier == "en" }
    }
}

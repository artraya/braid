import Foundation
import AVFoundation
import os

/// Short excerpts of each unnamed Speaker, so naming is a thing you do by ear
/// rather than by squinting at a transcript line (R25).
///
/// Clips are cut before the Recording is deleted and deleted the moment the
/// Session's Identification resolves. They are the shortest-lived audio in the
/// app and the only audio that outlives its Job, which is why their deletion is
/// tied to naming rather than to a timer.
public struct VoiceClipStore: Sendable {
    /// Longest clip worth cutting. Enough to recognise a colleague, short
    /// enough that the panel plays it without anyone waiting.
    public static let maxSeconds: TimeInterval = 8
    /// Below this there is nothing to recognise, so no clip is offered.
    public static let minSeconds: TimeInterval = 1.5

    let root: URL
    let log = Logger(subsystem: "no.braid.app", category: "voices")

    public init(root: URL = JobQueue.appSupportURL.appendingPathComponent("clips")) {
        self.root = root
    }

    /// Cuts one clip per named Speaker from their longest overlap-free turn.
    ///
    /// The longest turn, not the first: an opening "yeah, can you hear me"
    /// identifies nobody, while the stretch where someone actually made their
    /// point is unmistakable. Overlapping turns are skipped, since a clip with
    /// two people talking teaches the user nothing about which one they are
    /// naming.
    @discardableResult
    public func extract(from track: URL, spans: [SpeakerSpan],
                        speakers: [String], sessionID: String) -> [String: URL] {
        guard !speakers.isEmpty,
              let source = try? AVAudioFile(forReading: track) else { return [:] }

        let directory = root.appendingPathComponent(sessionID)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var clips: [String: URL] = [:]
        for speaker in speakers {
            guard let span = bestTurn(for: speaker, in: spans) else { continue }
            let destination = directory.appendingPathComponent("\(safe(speaker)).caf")
            do {
                try cut(source, span: span, to: destination)
                clips[speaker] = destination
            } catch {
                log.error("could not cut a voice clip: \(error.localizedDescription, privacy: .public)")
            }
        }
        log.notice("cut \(clips.count) voice clip(s) for naming")
        return clips
    }

    /// The longest turn this speaker has to themselves.
    func bestTurn(for speaker: String, in spans: [SpeakerSpan]) -> SpeakerSpan? {
        spans
            .filter { $0.speakerId == speaker && $0.duration >= Self.minSeconds }
            .filter { candidate in
                !spans.contains { other in
                    other.speakerId != speaker
                        && other.start < candidate.end && other.end > candidate.start
                }
            }
            .max { $0.duration < $1.duration }
    }

    /// Copies the middle of the turn — speakers trail off at the end of one and
    /// are often clipped at the start.
    private func cut(_ source: AVAudioFile, span: SpeakerSpan, to destination: URL) throws {
        let format = source.processingFormat
        let rate = format.sampleRate
        let wanted = min(Self.maxSeconds, span.duration)
        let centre = span.start + span.duration / 2
        let start = max(0, centre - wanted / 2)

        let startFrame = AVAudioFramePosition(start * rate)
        let frames = AVAudioFrameCount(min(wanted * rate,
                                           Double(source.length) - Double(startFrame)))
        guard frames > 0, startFrame < source.length,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw CocoaError(.fileReadUnknown)
        }
        source.framePosition = startFrame
        try source.read(into: buffer, frameCount: frames)

        try? FileManager.default.removeItem(at: destination)
        let output = try AVAudioFile(forWriting: destination,
                                     settings: source.fileFormat.settings)
        try output.write(from: buffer)
    }

    // MARK: - Lifecycle

    public func clips(for sessionID: String) -> [String: URL] {
        let directory = root.appendingPathComponent(sessionID)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        var found: [String: URL] = [:]
        for file in files where file.pathExtension == "caf" {
            found[file.deletingPathExtension().lastPathComponent] = file
        }
        return found
    }

    public func clip(for speaker: String, sessionID: String) -> URL? {
        let url = root.appendingPathComponent(sessionID)
            .appendingPathComponent("\(safe(speaker)).caf")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// R25: Identification resolved, so the clips go.
    public func delete(sessionID: String) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(sessionID))
    }

    /// Clips whose Session no longer expects a name — a record that aged out,
    /// or a Job discarded — have nothing to be played in. Cheap; called at launch.
    public func purgeOrphans(keeping live: Set<String>) {
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        for directory in directories where !live.contains(directory.lastPathComponent) {
            log.notice("purging orphaned voice clips")
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Speaker labels reach the filesystem, and "Speaker 1" is fine but a typed
    /// name may not be.
    private func safe(_ speaker: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = String(speaker.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return cleaned.isEmpty ? "speaker" : cleaned
    }
}

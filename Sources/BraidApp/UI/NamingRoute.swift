import SwiftUI
import AVFoundation
import Observation
import BraidCore

/// Plays a Voice Clip so naming is something you do by ear (R25).
///
/// One player for the whole route: starting a second clip stops the first,
/// because two voices at once is the one thing that would make this harder
/// rather than easier.
@MainActor
@Observable
final class ClipPlayer {
    private var player: AVAudioPlayer?
    private(set) var playing: String?

    func toggle(_ speaker: String, url: URL) {
        if playing == speaker {
            stop()
            return
        }
        stop()
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        self.player = player
        playing = speaker
        player.play()
        // No delegate: the clip is at most eight seconds, so a timer to clear
        // the highlight is simpler than a delegate object and cannot outlive
        // the view in a way that matters.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(player.duration + 0.1))
            if self?.playing == speaker { self?.playing = nil }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playing = nil
    }
}

/// Put names to the voices a Session found.
///
/// Braid never guesses among voices (R23): a chip is offered when the Voice
/// Database recognises someone, and everything else is a suggestion the user
/// confirms. Naming teaches the database, so the next call with the same person
/// needs none of this.
struct NamingRoute: View {
    let state: AppState
    let model: SessionsPanelModel
    let sessionID: String
    let actions: PanelActions

    private var record: NamingRecord? {
        state.awaitingNames.first { $0.id == sessionID }
            ?? state.transcripts.load(sessionID)
    }

    private var hasAnyName: Bool {
        model.namingNames.values.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title: "Name voices", back: { model.goToMain() })
            if let record {
                content(for: record)
            } else {
                Text("That transcript is no longer available.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faint)
            }
        }
        .padding(Theme.padding)
        .onDisappear { model.clipPlayer.stop() }
    }

    @ViewBuilder
    private func content(for record: NamingRecord) -> some View {
        // Voices Braid recognised are listed too, with their name filled in.
        // They need no attention, but an auto-name is the one thing that can be
        // confidently wrong, so there has to be somewhere to correct it — and
        // correcting it removes the Voiceprint that caused it (R24).
        let stats = record.transcript.remoteSpeakerStats()
            .filter { $0.speaker != "Me (echo)" }
        let unnamed = stats.filter { $0.speaker.hasPrefix("Speaker ") }.count

        Text(header(for: record, unnamed: unnamed))
            .font(.system(size: 11))
            .foregroundStyle(Theme.dim)
            .fixedSize(horizontal: false, vertical: true)

        if let mismatch = record.speakerMismatch {
            Label(mismatch.message, systemImage: "person.crop.circle.badge.questionmark")
                .font(.system(size: 11))
                .foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
        if stats.count > 1 {
            Text("Same person split in two? Give both voices the same name to merge them.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }

        ScrollView {
            VStack(spacing: 10) {
                ForEach(stats) { stat in
                    let recognised = !stat.speaker.hasPrefix("Speaker ")
                    SpeakerRow(
                        stat: stat,
                        recognised: recognised,
                        chips: chips(for: stat.speaker, record: record),
                        clip: state.clips.clip(for: stat.speaker, sessionID: sessionID),
                        player: model.clipPlayer,
                        name: Binding(
                            // A recognised voice shows the name it was given, so
                            // changing it is an edit rather than a fresh guess.
                            get: { model.namingNames[stat.speaker]
                                    ?? (recognised ? stat.speaker : "") },
                            set: { model.namingNames[stat.speaker] = $0 }))
                }
            }
        }
        .scrollIndicators(.never)
        .frame(maxHeight: 300)

        if let error = model.namingError {
            Text(error).font(.system(size: 11)).foregroundStyle(Theme.recording).lineLimit(3)
        } else {
            Text(record.isDelivered
                 ? "Rewrites the note and transcript, and remembers these voices for next time."
                 : "Writes the note, and remembers these voices for next time.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }

        HStack(spacing: 10) {
            // R25: skipping resolves the Session. For a Held one that means
            // delivering with generic labels, so the button has to say so.
            Button(record.isDelivered ? "Not now" : "Write it without names") {
                if record.isDelivered {
                    model.goToMain()
                } else {
                    actions.skipNaming(sessionID)
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.dim)
            .disabled(model.namingWorking)

            Spacer()

            Button {
                actions.applyNames(sessionID)
            } label: {
                Text(model.namingWorking
                     ? (record.isDelivered ? "Rewriting…" : "Writing…")
                     : "Apply")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .padding(.vertical, 9)
                    .padding(.horizontal, 18)
                    .background(hasAnyName && !model.namingWorking ? Theme.accent : Theme.card,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(model.namingWorking || !hasAnyName)
        }
    }

    private func header(for record: NamingRecord, unnamed: Int) -> String {
        let voices = "\(unnamed) voice\(unnamed == 1 ? "" : "s")"
        return record.isDelivered
            ? "\(record.session.title) — \(voices) Braid did not recognise. Name the ones you know and leave the rest."
            : "\(record.session.title) — the note is waiting on \(voices). Name them, or write it without."
    }

    /// Suggestion order (SPEC Design): what the voice matched, then the names
    /// typed at Start, then people heard recently. Deduplicated, first wins.
    private func chips(for speaker: String, record: NamingRecord) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        func add(_ name: String) {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { return }
            out.append(trimmed)
        }
        if let matched = record.suggestions[speaker] { add(matched) }
        record.session.participants.forEach(add)
        state.knownPeople
            .sorted { ($0.lastHeardAt ?? .distantPast) > ($1.lastHeardAt ?? .distantPast) }
            .prefix(4)
            .forEach { add($0.name) }
        return out
    }
}

private struct SpeakerRow: View {
    let stat: Transcript.SpeakerStat
    /// Braid put this name here itself, so the row reads as confirmable rather
    /// than as a question.
    let recognised: Bool
    let chips: [String]
    let clip: URL?
    let player: ClipPlayer
    let name: Binding<String>

    private var turns: String {
        "\(stat.utteranceCount) turn\(stat.utteranceCount == 1 ? "" : "s")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let clip {
                    Button {
                        player.toggle(stat.speaker, url: clip)
                    } label: {
                        Image(systemName: player.playing == stat.speaker
                              ? "stop.circle.fill" : "play.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .help("Hear this voice")
                }
                Text(stat.speaker)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.text)
                Text("\(Transcript.gap(stat.totalSeconds)) · \(turns)")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.faint)
                if recognised {
                    Text("recognised")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 6)
                        .background(Theme.accent.opacity(0.16), in: Capsule())
                }
            }
            Text("\u{201C}\(stat.sample)\u{201D}")
                .font(.system(size: 11))
                .foregroundStyle(Theme.dim)
                .italic()
                .fixedSize(horizontal: false, vertical: true)

            if !chips.isEmpty {
                // One tap is the whole point: the common case is a name Braid
                // already has a reason to offer.
                HStack(spacing: 5) {
                    ForEach(chips.prefix(4), id: \.self) { chip in
                        Button(chip) { name.wrappedValue = chip }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(name.wrappedValue == chip ? Theme.text : Theme.accent)
                            .padding(.vertical, 3)
                            .padding(.horizontal, 8)
                            .background(name.wrappedValue == chip
                                        ? Theme.accent : Color.white.opacity(0.06),
                                        in: Capsule())
                    }
                }
            }

            TextField("Name", text: name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
        }
        .padding(10)
        .background(Theme.card,
                    in: RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
    }
}

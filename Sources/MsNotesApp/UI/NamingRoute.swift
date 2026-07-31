import SwiftUI
import MsNotesCore

/// Put names to the voices a finished Session found.
///
/// Nothing is auto-assigned: with two names typed at Start and two speakers
/// found, guessing which is which is a coin flip, and a confidently wrong name
/// in a note is worse than "Speaker 1". The names typed at Start appear as
/// suggestions instead.
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
            PanelHeader(title: "Name speakers", back: { model.goToMain() })
            if let record {
                content(for: record)
            } else {
                Text("That transcript is no longer available.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faint)
            }
        }
        .padding(Theme.padding)
    }

    @ViewBuilder
    private func content(for record: NamingRecord) -> some View {
        let stats = record.transcript.remoteSpeakerStats()

        Text("\(record.session.title) — \(stats.count) voice\(stats.count == 1 ? "" : "s") on the far end. Name the ones you recognise and leave the rest.")
            .font(.system(size: 11))
            .foregroundStyle(Theme.dim)
            .fixedSize(horizontal: false, vertical: true)

        ScrollView {
            VStack(spacing: 10) {
                ForEach(stats) { stat in
                    SpeakerRow(
                        stat: stat,
                        suggestions: record.session.participants,
                        name: Binding(
                            get: { model.namingNames[stat.speaker] ?? "" },
                            set: { model.namingNames[stat.speaker] = $0 }))
                }
            }
        }
        .scrollIndicators(.never)
        .frame(maxHeight: 300)

        if let error = model.namingError {
            Text(error).font(.system(size: 11)).foregroundStyle(Theme.recording).lineLimit(3)
        } else {
            Text("Rewrites the note and transcript. About 10c.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.faint)
        }

        HStack(spacing: 10) {
            Button("Not now") { model.goToMain() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.dim)
                .disabled(model.namingWorking)
            Spacer()
            Button {
                actions.applyNames(sessionID)
            } label: {
                Text(model.namingWorking ? "Rewriting…" : "Apply")
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
}

private struct SpeakerRow: View {
    let stat: Transcript.SpeakerStat
    let suggestions: [String]
    let name: Binding<String>

    private var turns: String {
        "\(stat.utteranceCount) turn\(stat.utteranceCount == 1 ? "" : "s")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(stat.speaker)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.text)
                Text("\(Transcript.gap(stat.totalSeconds)) · \(turns)")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.faint)
            }
            Text("\u{201C}\(stat.sample)\u{201D}")
                .font(.system(size: 11))
                .foregroundStyle(Theme.dim)
                .italic()
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                TextField("Name", text: name)
                    .textFieldStyle(.roundedBorder)
                if !suggestions.isEmpty {
                    Menu {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button(suggestion) { name.wrappedValue = suggestion }
                        }
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 26)
                    .help("Participants you named at the start")
                }
            }
        }
        .padding(10)
        .background(Theme.card,
                    in: RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
    }
}

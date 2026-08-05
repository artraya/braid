import SwiftUI
import BraidCore

/// The title row every view in the panel starts with. `back` turns it into a
/// way out of a sub-view; `trailing` is whatever that view puts on the right.
struct PanelHeader<Trailing: View>: View {
    let title: String
    var back: (() -> Void)?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            if let back {
                Button(action: back) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.dim)
                }
                .buttonStyle(.plain)
                .help("Back")
            }
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.text)
            Spacer()
            trailing()
        }
    }
}

extension PanelHeader where Trailing == EmptyView {
    init(title: String, back: (() -> Void)? = nil) {
        self.init(title: title, back: back, trailing: { EmptyView() })
    }
}

/// An irreversible action asking for a yes or no, inline. The plain button
/// keeps what you have; the coloured one destroys it.
struct ConfirmationStrip: View {
    let confirmation: SessionsPanelModel.Confirmation
    let onAnswer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(confirmation.question)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(confirmation.detail)
                .font(.system(size: 11))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Spacer()
                Button("Keep it") { onAnswer(false) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Button(confirmation.confirmLabel) { onAnswer(true) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Theme.recording,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.recording.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                .strokeBorder(Theme.recording.opacity(0.4), lineWidth: 1))
    }
}

/// The live Session: clock, waveform and the controls. Formerly its own
/// floating window, now a block at the top of the panel.
struct RecordingSection: View {
    let state: AppState
    let model: SessionsPanelModel
    let actions: PanelActions

    private var paused: Bool { state.phase == .paused }

    var body: some View {
        VStack(spacing: 10) {
            if let seconds = model.autoEndIn {
                autoEndBanner(seconds)
            }
            statusLine
            if let warning = model.bleedWarning {
                Label(warning, systemImage: "speaker.wave.2.bubble")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            Text(Format.clock(model.elapsed))
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
            Text(state.currentTitle)
                .font(.system(size: 11))
                .foregroundStyle(Theme.faint)
                .lineLimit(1)
            Waveform(levels: model.levels, live: !paused)
                .frame(height: 44)
            controls
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .background(recordingBackground)
    }

    /// A warm glow while live, so the panel reads as recording at a glance. It
    /// cools when paused.
    private var recordingBackground: some View {
        LinearGradient(
            colors: [
                (paused ? Theme.dim : Theme.recording).opacity(paused ? 0.10 : 0.22),
                Theme.card.opacity(0.5),
            ],
            startPoint: .top, endPoint: .bottom)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(paused ? Theme.dim : Theme.recording)
                .frame(width: 7, height: 7)
            Text(paused ? "PAUSED" : "RECORDING")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.6)
                .foregroundStyle(paused ? Theme.dim : Theme.recording)
        }
    }

    /// Shown when the call app has let go of the mic. The way out sits right
    /// here rather than only in a notification that may already have gone.
    private func autoEndBanner(_ seconds: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "phone.down.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.recording)
            Text("Call ended — stopping in \(seconds)s")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.text)
            Spacer(minLength: 4)
            Button("Keep", action: actions.keepRecording)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.recording.opacity(0.18),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// Stacked rather than in one row: at 228 points the three controls side by
    /// side squeezed "Stop & save" onto three lines. Stopping gets the full
    /// width it deserves as the action almost always wanted, and pause and
    /// discard sit under it.
    private var controls: some View {
        VStack(spacing: 10) {
            Button(action: actions.stop) {
                Text("Stop & save")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Theme.accent,
                                in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.plain)
            HStack(spacing: 16) {
                CircleButton(symbol: paused ? "play.fill" : "pause.fill",
                             tint: Theme.text,
                             help: paused ? "Resume" : "Pause",
                             action: actions.pauseResume)
                CircleButton(symbol: "xmark",
                             tint: Theme.recording,
                             help: "Discard this recording",
                             action: actions.discardRecording)
            }
        }
    }
}

struct CircleButton: View {
    let symbol: String
    let tint: Color
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(Theme.card, in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The level history as bars, oldest left. Drawn in one Canvas pass rather than
/// as N views, because this redraws 20 times a second for the length of a call.
struct Waveform: View {
    let levels: [Float]
    let live: Bool
    /// The newest few bars are tinted, which is what makes the waveform read as
    /// moving rather than as a static picture.
    private static let leadingEdge = 4

    var body: some View {
        Canvas { context, size in
            guard !levels.isEmpty else { return }
            let spacing: CGFloat = 3
            let width = max(1, (size.width - spacing * CGFloat(levels.count - 1))
                            / CGFloat(levels.count))
            for (index, level) in levels.enumerated() {
                // Square root opens up the quiet end: speech peaks well below
                // full scale, and a linear bar height reads as near-silence.
                let scaled = CGFloat(sqrt(max(0, min(1, level))))
                let height = max(3, scaled * size.height)
                let x = CGFloat(index) * (width + spacing)
                let rect = CGRect(x: x, y: (size.height - height) / 2,
                                  width: width, height: height)
                let isLeading = live && index >= levels.count - Self.leadingEdge
                context.fill(
                    Path(roundedRect: rect, cornerRadius: width / 2),
                    with: .color(isLeading ? Theme.recording : Theme.dim.opacity(0.55)))
            }
        }
        .drawingGroup()
    }
}

/// This month, as a fact rather than a budget. There is nothing to cap: with
/// the cloud gone, recording costs nothing but disk (R14 retired, R18 amended).
struct UsageCard: View {
    let usage: Usage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("THIS MONTH")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.accent)
                Spacer()
                Text("\(usage.sessionCount) session\(usage.sessionCount == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(Int(usage.minutesUsed))")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text("minutes recorded")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.dim)
            }
        }
        .padding(14)
        .background(Theme.accentDim,
                    in: RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1))
    }
}

struct PendingAction: View {
    let label: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(label, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            // Without this a narrow row wraps the label one letter per line
            // rather than letting the row be as wide as its buttons need.
            .fixedSize()
    }
}

struct PendingRow<Actions: View>: View {
    let title: String
    let detail: String
    let tint: Color
    let spinning: Bool
    var symbol = "pause.circle"
    @ViewBuilder let actions: () -> Actions

    /// Two rows, not one. Beside a title, two actions had barely thirty points
    /// between them and "Process" came out stacked one letter per line; below
    /// it they have the whole width and the title stops being truncated to
    /// three characters.
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Group {
                    if spinning {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    } else {
                        Image(systemName: symbol).font(.system(size: 13))
                    }
                }
                .foregroundStyle(tint)
                .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.faint)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 14) {
                Spacer(minLength: 0)
                actions()
            }
        }
        .padding(10)
        .background(Theme.cardRaised,
                    in: RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
    }
}

struct SessionRow: View {
    let session: SessionRecord
    let open: () -> Void
    /// Present while the Session's naming record is still around, which is the
    /// window in which a wrong name can still be corrected against the voice.
    var rename: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 34, height: 34)
                    .background(Theme.accentDim,
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text("\(Format.when(session.startedAt)) · \(Format.duration(session.recordedDuration))")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.faint)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card,
                        in: RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open in Obsidian")

        if let rename {
            Button(action: rename) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.dim)
                    .frame(width: 30, height: 30)
                    .background(Theme.card,
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Re-name the voices in this session")
        }
        }
    }
}

/// What the panel asks before a recording, which is now only one thing: who is
/// on the call.
///
/// It asked three things and this is what became of them. The Preset moved to
/// Settings, because the shape of a note is a standing preference rather than a
/// per-call decision. The title left entirely — the Summariser names the Note
/// from what was actually said (R9a), which beats a guess typed beforehand.
/// Participants stayed, but as voices Braid already knows rather than as a
/// comma-separated string: after a few sessions the people you record are
/// mostly repeats, and ticking a name is quicker and spells it right.
struct StartForm: View {
    let state: AppState
    let model: SessionsPanelModel
    let onStart: () -> Void

    private var known: [Person] { state.knownPeople }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !known.isEmpty || !model.addedNames.isEmpty {
                Text("WHO'S ON THIS CALL")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(Theme.accent)
                chips
            }
            addField
            voiceCount
        }
        .padding(12)
        .background(Theme.card,
                    in: RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
    }

    /// One chip per known voice, plus anyone typed in. Wrapping is a real
    /// layout rather than a fixed grid because names are all different lengths
    /// and the panel is narrow enough that a two-column grid would leave "Sam"
    /// sitting beside a lot of nothing.
    private var chips: some View {
        FlowLayout(spacing: 6) {
            ForEach(known) { person in
                let on = model.chosenPeople.contains(person.name)
                NameChip(name: person.name, selected: on, removable: false) {
                    if on { model.chosenPeople.remove(person.name) }
                    else { model.chosenPeople.insert(person.name) }
                }
            }
            ForEach(model.addedNames, id: \.self) { name in
                NameChip(name: name, selected: true, removable: true) {
                    model.addedNames.removeAll { $0 == name }
                }
            }
        }
    }

    private var addField: some View {
        HStack(spacing: 6) {
            TextField(known.isEmpty ? "Who's on this call?" : "Someone else…",
                      text: Binding(get: { model.typedName },
                                    set: { model.typedName = $0 }))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .onSubmit { model.commitTypedName(known: known) }
            if !model.typedName.trimmingCharacters(in: .whitespaces).isEmpty {
                Button {
                    model.commitTypedName(known: known)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Centred, as the one control that is genuinely optional here.
    private var voiceCount: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Text("Voices")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
                Picker("", selection: Binding(get: { model.speakerCount },
                                              set: { model.selectSpeakerCount($0) })) {
                    Text("Auto").tag(Int?.none)
                    ForEach(1..<7) { n in
                        Text("\(n)").tag(Int?.some(n))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 72)
            }
            // Its own row: beside the picker there were about twenty points
            // left and the label came out as "exactl / y".
            if model.speakerCount != nil {
                Toggle("exactly this many", isOn: Binding(get: { model.speakersStrict },
                                                          set: { model.speakersStrict = $0 }))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.dim)
                    .fixedSize()
                    .help("Also cap the count. Anyone who joins late is merged into these voices.")
            }
            if let footer {
                Text(footer)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.faint)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Only speaks up when the choice carries a risk. Auto is the safe default
    /// and does not need explaining every time the panel opens.
    private var footer: String? {
        guard let count = model.speakerCount else { return nil }
        return model.speakersStrict
            ? "Exactly \(count) — late joiners get merged in."
            : "At least \(count) — helps split similar voices."
    }
}

/// A name you can tick. Selected names are the ones the Session expects.
struct NameChip: View {
    let name: String
    let selected: Bool
    let removable: Bool
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 4) {
                Text(name)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                if removable {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .opacity(0.7)
                }
            }
            .foregroundStyle(selected ? Theme.text : Theme.dim)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(selected ? Theme.accent : Theme.cardRaised,
                        in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(removable ? "Remove \(name)" : (selected ? "Expecting \(name)" : "Add \(name)"))
    }
}

/// Left-aligned wrapping, the way tags wrap everywhere else. SwiftUI has no
/// built-in for it, and the alternatives — a fixed grid, or a horizontal
/// scroller — either waste the width or hide names off the edge, both of which
/// matter more at 228 points than they would in a window.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } +
            spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty, needed > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

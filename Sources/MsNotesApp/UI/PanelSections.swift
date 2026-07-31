import SwiftUI
import MsNotesCore

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
            Text(Format.clock(model.elapsed))
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
            Text("\(state.currentTitle) · \(Format.money(model.costEstimate))")
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

    private var controls: some View {
        HStack(spacing: 12) {
            CircleButton(symbol: paused ? "play.fill" : "pause.fill",
                         tint: Theme.text,
                         help: paused ? "Resume" : "Pause",
                         action: actions.pauseResume)
            Button(action: actions.stop) {
                Text("Stop & save")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 20)
                    .background(Theme.accent,
                                in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.plain)
            CircleButton(symbol: "xmark",
                         tint: Theme.recording,
                         help: "Discard this recording",
                         action: actions.discardRecording)
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

struct UsageCard: View {
    let usage: Usage

    private var barColour: Color {
        usage.isOverCap ? Theme.recording : Theme.accent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("USAGE")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.accent)
                Spacer()
                Text("\(Format.money(usage.costUSD)) · \(usage.daysLeftInMonth) day\(usage.daysLeftInMonth == 1 ? "" : "s") left")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(Int(usage.minutesUsed))")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text("of \(usage.minuteCap) min")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.dim)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.35))
                    Capsule()
                        .fill(barColour)
                        .frame(width: max(4, geometry.size.width * usage.fraction))
                }
            }
            .frame(height: 7)
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
    }
}

struct PendingRow<Actions: View>: View {
    let title: String
    let detail: String
    let tint: Color
    let spinning: Bool
    var symbol = "pause.circle"
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if spinning {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                } else {
                    Image(systemName: symbol).font(.system(size: 14))
                }
            }
            .foregroundStyle(tint)
            .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.faint)
            }
            Spacer(minLength: 8)
            HStack(spacing: 10) { actions() }
        }
        .padding(10)
        .background(Theme.cardRaised,
                    in: RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
    }
}

struct SessionRow: View {
    let session: SessionRecord
    let open: () -> Void

    var body: some View {
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
    }
}

struct StartForm: View {
    let state: AppState
    let model: SessionsPanelModel
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: Binding(get: { model.presetName },
                                          set: { model.presetName = $0 })) {
                ForEach(state.settings.presets) { preset in
                    Text(preset.name).tag(preset.name)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            TextField("Title (optional)", text: Binding(get: { model.title },
                                                        set: { model.title = $0 }))
                .textFieldStyle(.roundedBorder)
                .onSubmit(onStart)
            TextField("Participants, comma separated (optional)",
                      text: Binding(get: { model.participants },
                                    set: { model.participants = $0 }))
                .textFieldStyle(.roundedBorder)
                .onSubmit(onStart)
            Text("Names are hints for the summary. Anyone who joins is still picked up.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.faint)
        }
        .padding(12)
        .background(Theme.card,
                    in: RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
    }
}

import AppKit
import SwiftUI
import Observation
import MsNotesCore

/// The HUD's own ticking state. AppState holds what is being recorded; this
/// holds what the display needs to redraw at 20 Hz, so nothing else in the app
/// is woken up by the timer.
@MainActor
@Observable
final class RecordingHUDModel {
    var elapsed: TimeInterval = 0
    var levels: [Float] = []
    var costEstimate: Double = 0
    /// Seconds until the Session stops by itself, or nil when nothing is pending.
    var autoEndIn: Int?
}

@MainActor
final class RecordingHUDController: NSObject {
    /// 20 Hz: one frame per LevelMeter bar, so the waveform advances smoothly
    /// without redrawing the same picture twice.
    private static let refreshInterval = LevelMeter.barSeconds
    static let barCount = 44

    private let state: AppState
    private let model = RecordingHUDModel()
    private var panel: FloatingPanel?
    private var timer: Timer?
    /// Remembered for the session so the HUD reappears where it was put.
    private var lastOrigin: NSPoint?

    init(state: AppState) {
        self.state = state
    }

    /// Called whenever the phase changes: the HUD follows the Session.
    func syncToPhase() {
        switch state.phase {
        case .recording, .paused: show()
        case .idle: hide()
        }
    }

    private func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        guard !panel.isVisible else { return }
        tick()
        panel.layoutIfNeeded()
        if let origin = lastOrigin {
            panel.setFrameOrigin(origin)
        } else {
            panel.center()
            var frame = panel.frame
            // Sit it clear of the centre of the screen, out of a call window's way.
            if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
                frame.origin.y = visible.maxY - frame.height - 24
                panel.setFrameOrigin(frame.origin)
            }
        }
        panel.orderFrontRegardless()
        startTimer()
    }

    private func hide() {
        stopTimer()
        if let panel, panel.isVisible { lastOrigin = panel.frame.origin }
        model.autoEndIn = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 250),
            draggable: true)
        panel.setContent(RecordingHUDView(
            state: state,
            model: model,
            onPauseResume: { [weak self] in
                guard let self else { return }
                self.state.phase == .paused ? self.state.resume() : self.state.pause()
            },
            onStop: { [weak self] in self?.state.stop() },
            onDiscard: { [weak self] in self?.state.discard() },
            onKeepRecording: { [weak self] in
                self?.state.cancelAutoEnd()
                self?.tick()
            }))
        return panel
    }

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Common mode, or the clock freezes while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        model.levels = state.engine.levels.recent(Self.barCount)
        model.costEstimate = state.liveCostEstimate
        if let startedAt = state.recordingStartedAt, state.phase == .recording {
            model.elapsed = Date().timeIntervalSince(startedAt)
        }
        model.autoEndIn = state.autoEndDeadline.map {
            max(0, Int($0.timeIntervalSinceNow.rounded(.up)))
        }
    }
}

struct RecordingHUDView: View {
    let state: AppState
    let model: RecordingHUDModel
    let onPauseResume: () -> Void
    let onStop: () -> Void
    let onDiscard: () -> Void
    let onKeepRecording: () -> Void

    private var paused: Bool { state.phase == .paused }

    var body: some View {
        VStack(spacing: 12) {
            if let seconds = model.autoEndIn {
                autoEndBanner(seconds)
            }
            statusLine
            Text(Format.clock(model.elapsed))
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
            Text("\(state.currentTitle) · \(Format.money(model.costEstimate))")
                .font(.system(size: 11))
                .foregroundStyle(Theme.faint)
                .lineLimit(1)
            Waveform(levels: model.levels, live: !paused)
                .frame(height: 54)
                .padding(.horizontal, 4)
            controls
        }
        .padding(18)
        .frame(width: 360)
        .background(hudBackground)
        .panelSurface(.clear)
        .preferredColorScheme(.dark)
    }

    /// A warm glow at the top while live, so the HUD reads as "recording" from
    /// the corner of your eye. It cools when paused.
    private var hudBackground: some View {
        LinearGradient(
            colors: [
                (paused ? Theme.dim : Theme.recording).opacity(paused ? 0.10 : 0.22),
                Theme.panel,
            ],
            startPoint: .top, endPoint: .center)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }

    /// Shown when the call app has let go of the mic. The way out is right
    /// here rather than buried in a notification that may already be gone.
    private func autoEndBanner(_ seconds: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "phone.down.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.recording)
            Text("Call ended — stopping in \(seconds)s")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.text)
            Spacer(minLength: 4)
            Button("Keep recording", action: onKeepRecording)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.recording.opacity(0.16),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
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

    private var controls: some View {
        HStack(spacing: 14) {
            CircleButton(symbol: paused ? "play.fill" : "pause.fill",
                         tint: Theme.text,
                         help: paused ? "Resume" : "Pause",
                         action: onPauseResume)
            Button(action: onStop) {
                Text("Stop & save")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .padding(.vertical, 11)
                    .padding(.horizontal, 22)
                    .background(Theme.accent,
                                in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)

            CircleButton(symbol: "xmark",
                         tint: Theme.recording,
                         help: "Discard this recording",
                         action: confirmDiscard)
        }
    }

    /// Discarding destroys audio that cannot be recovered, so it always asks —
    /// and the default button is the one that keeps the recording.
    private func confirmDiscard() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Discard this recording?"
        alert.informativeText =
            "The audio is deleted and no note is written. This cannot be undone."
        alert.addButton(withTitle: "Keep recording")
        alert.addButton(withTitle: "Discard")
        if alert.runModal() == .alertSecondButtonReturn {
            onDiscard()
        }
    }
}

private struct CircleButton: View {
    let symbol: String
    let tint: Color
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(Theme.card, in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The level history as bars, oldest left. Drawn in one Canvas pass rather than
/// as N views, because this redraws 20 times a second for the length of a call.
private struct Waveform: View {
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

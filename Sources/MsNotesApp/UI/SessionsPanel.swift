import AppKit
import SwiftUI
import Observation
import MsNotesCore

/// State the Sessions panel owns rather than AppState: what the start form has
/// typed into it, and whether that form is showing at all.
@MainActor
@Observable
final class SessionsPanelModel {
    var showingStartForm = false
    var title = ""
    var participants = ""
    var presetName = ""

    func resetForm(defaultPreset: String) {
        title = ""
        participants = ""
        presetName = defaultPreset
        showingStartForm = false
    }
}

@MainActor
final class SessionsPanelController: NSObject, NSWindowDelegate {
    private let state: AppState
    private let model = SessionsPanelModel()
    private var panel: FloatingPanel?
    /// Set by StatusItemController so Settings and Quit stay reachable from the
    /// panel as well as the right-click menu.
    var onOpenSettings: (() -> Void)?

    init(state: AppState) {
        self.state = state
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle(from button: NSStatusBarButton?) {
        if isVisible { close() } else { show(from: button) }
    }

    func show(from button: NSStatusBarButton?) {
        state.refreshSessions()
        state.refreshNamingState()
        model.resetForm(defaultPreset: state.settings.presets.first?.name ?? "Meeting")

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.layoutIfNeeded()
        panel.position(below: button)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: Theme.panelWidth, height: 480),
            draggable: false)
        panel.delegate = self
        panel.setContent(SessionsPanelView(
            state: state,
            model: model,
            onStart: { [weak self] in self?.start() },
            onOpenSettings: { [weak self] in
                self?.close()
                self?.onOpenSettings?()
            },
            onOpenNote: { [weak self] path in self?.state.openNote(at: path) }))
        return panel
    }

    private func start() {
        state.start(title: model.title,
                    presetName: model.presetName,
                    participants: model.participants)
        model.resetForm(defaultPreset: state.settings.presets.first?.name ?? "Meeting")
        close()
    }

    /// Clicking away dismisses the panel, the way a menu would.
    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}

struct SessionsPanelView: View {
    let state: AppState
    let model: SessionsPanelModel
    let onStart: () -> Void
    let onOpenSettings: () -> Void
    let onOpenNote: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            UsageCard(usage: state.usage)
            sessionList
            if model.showingStartForm {
                StartForm(state: state, model: model, onStart: onStart)
            }
            recordButton
        }
        .padding(Theme.padding)
        .frame(width: Theme.panelWidth)
        .panelSurface()
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            Text("Sessions")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.text)
            Spacer()
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.faint)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
    }

    @ViewBuilder
    private var sessionList: some View {
        if state.recentSessions.isEmpty {
            Text(state.setupComplete
                 ? "No sessions yet. Record one and the note lands in your vault."
                 : "Finish setup in Settings before recording.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.faint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 18)
        } else {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(state.recentSessions) { session in
                        SessionRow(session: session) { onOpenNote(session.notePath) }
                    }
                }
            }
            .scrollIndicators(.never)
            // Roughly four rows before it scrolls, so the panel stays a panel.
            .frame(maxHeight: 232)
        }
    }

    private var recordButton: some View {
        Button {
            if model.showingStartForm {
                onStart()
            } else {
                model.showingStartForm = true
            }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.showingStartForm ? Theme.text : Color.black.opacity(0.75))
                    .frame(width: 9, height: 9)
                Text(model.showingStartForm ? "Start recording" : "Record")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(state.setupComplete ? Theme.accent : Theme.card,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!state.setupComplete)
    }
}

private struct UsageCard: View {
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

private struct SessionRow: View {
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

private struct StartForm: View {
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

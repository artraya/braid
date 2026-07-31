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
    var onNameSpeakers: ((String) -> Void)?

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
            onOpenNote: { [weak self] path in self?.state.openNote(at: path) },
            onCancelJob: { [weak self] id in self?.state.cancelJob(id: id) },
            onRetryJob: { [weak self] id in self?.state.retry(jobID: id) },
            onDiscardJob: { [weak self] id in self?.confirmDiscard(id) },
            onNameSpeakers: { [weak self] id in
                self?.close()
                self?.onNameSpeakers?(id)
            }))
        return panel
    }

    /// Deleting a Recording that produced no Note is the one irreversible thing
    /// in this panel, so it asks, and the default answer keeps the audio.
    private func confirmDiscard(_ id: String) {
        guard let job = state.cancelledJobs.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete the recording for \"\(job.session.title)\"?"
        alert.informativeText =
            "\(Format.duration(job.session.recordedDuration)) of audio is deleted and no note is written. This cannot be undone."
        alert.addButton(withTitle: "Keep it")
        alert.addButton(withTitle: "Delete")
        if alert.runModal() == .alertSecondButtonReturn {
            state.discardJob(id: id)
        }
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
    let onCancelJob: (String) -> Void
    let onRetryJob: (String) -> Void
    let onDiscardJob: (String) -> Void
    let onNameSpeakers: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            UsageCard(usage: state.usage)
            processingList
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

    /// Work that has not been paid for yet, with the way to stop it. This sits
    /// above the history because it is the only part of the panel that is
    /// time-sensitive: once a Job finishes, cancelling it is no longer an option.
    @ViewBuilder
    private var processingList: some View {
        if !state.activeJobs.isEmpty || !state.cancelledJobs.isEmpty {
            VStack(spacing: 6) {
                ForEach(state.activeJobs) { job in
                    PendingRow(title: job.session.title,
                               detail: "Processing · \(Format.duration(job.session.recordedDuration))",
                               tint: Theme.accent, spinning: true) {
                        PendingAction(label: "Cancel", tint: Theme.dim) { onCancelJob(job.id) }
                    }
                }
                ForEach(state.cancelledJobs) { job in
                    PendingRow(title: job.session.title,
                               detail: "Cancelled · \(Format.duration(job.session.recordedDuration)) kept",
                               tint: Theme.faint, spinning: false) {
                        PendingAction(label: "Process", tint: Theme.accent) { onRetryJob(job.id) }
                        PendingAction(label: "Delete", tint: Theme.recording) { onDiscardJob(job.id) }
                    }
                }
                // Also in the right-click menu, but the panel is where people
                // look, and a prompt only reachable from a menu gets missed.
                ForEach(state.awaitingNames) { record in
                    let count = record.transcript.remoteSpeakerStats().count
                    PendingRow(title: record.session.title,
                               detail: "\(count) speaker\(count == 1 ? "" : "s") to name",
                               tint: Theme.accent, spinning: false, symbol: "person.wave.2") {
                        PendingAction(label: "Name", tint: Theme.accent) { onNameSpeakers(record.id) }
                    }
                }
            }
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

private struct PendingAction: View {
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

private struct PendingRow<Actions: View>: View {
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

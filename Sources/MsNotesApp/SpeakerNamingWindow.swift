import AppKit
import SwiftUI
import Observation
import MsNotesCore

/// Put names to the voices a finished Session found. Nothing is auto-assigned:
/// with two names typed at Start and two speakers found, guessing which is
/// which is a coin flip, and a confidently wrong name in a note is worse than
/// "Speaker 1". The names you typed appear as suggestions instead.
///
/// State lives in an `@Observable` model rather than `@State` throughout the
/// app's SwiftUI: the Command Line Tools ship no SwiftUIMacros plugin, so the
/// state property wrappers do not compile without Xcode. Views read a model the
/// owning controller holds, and Observation drives the redraw.
@MainActor
@Observable
final class SpeakerNamingModel {
    let record: NamingRecord
    let stats: [Transcript.SpeakerStat]
    var names: [String: String] = [:]
    var working = false
    var error: String?

    init(record: NamingRecord) {
        self.record = record
        self.stats = record.transcript.remoteSpeakerStats()
    }

    var hasAnyName: Bool {
        names.values.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    func name(for speaker: String) -> String { names[speaker] ?? "" }
    func setName(_ value: String, for speaker: String) { names[speaker] = value }
}

@MainActor
final class SpeakerNamingWindowController: NSObject {
    private let state: AppState
    private var window: NSWindow?
    private var model: SpeakerNamingModel?

    init(state: AppState) {
        self.state = state
    }

    func show(record: NamingRecord) {
        window?.close()
        let model = SpeakerNamingModel(record: record)
        self.model = model

        let view = SpeakerNamingView(
            model: model,
            apply: { [weak self] in self?.apply(model) },
            dismiss: { [weak self] in self?.close() })

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 440),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Name Speakers"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    private func apply(_ model: SpeakerNamingModel) {
        model.working = true
        model.error = nil
        state.applyNames(model.names, toSessionID: model.record.id) { [weak self] result in
            model.working = false
            switch result {
            case .success:
                self?.close()
            case .failure(let error):
                model.error = "\(error)"
            }
        }
    }

    private func close() {
        window?.close()
        window = nil
        model = nil
    }
}

struct SpeakerNamingView: View {
    let model: SpeakerNamingModel
    let apply: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(model.stats) { stat in
                        SpeakerRow(
                            stat: stat,
                            suggestions: model.record.session.participants,
                            name: Binding(
                                get: { model.name(for: stat.speaker) },
                                set: { model.setName($0, for: stat.speaker) }))
                    }
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(minWidth: 440, minHeight: 380)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.record.session.title).font(.headline)
            Text("\(model.stats.count) voice\(model.stats.count == 1 ? "" : "s") on the far end. Name the ones you recognise and leave the rest.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
            } else {
                Text("Rewrites the note and transcript. About 10c.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Not now", action: dismiss).disabled(model.working)
            Button(model.working ? "Rewriting…" : "Apply", action: apply)
                .keyboardShortcut(.defaultAction)
                .disabled(model.working || !model.hasAnyName)
        }
        .padding(16)
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
                Text(stat.speaker).font(.system(.body, design: .rounded)).bold()
                Text("\(Transcript.gap(stat.totalSeconds)) · \(turns) · from \(Transcript.timestamp(stat.firstAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("\u{201C}\(stat.sample)\u{201D}")
                .font(.callout)
                .foregroundStyle(.secondary)
                .italic()
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
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
                    .frame(width: 28)
                    .help("Participants you named at the start")
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

import AppKit
import SwiftUI
import TunerCore

// In the macOS 27 SDK the `@State` attribute is a macro whose plugin ships only with Xcode, so this
// target cannot use it. `State(initialValue:)` is the same storage, declared by hand.

@main
struct TunerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private var modelState = State(initialValue: AppModel.open())

    private var model: AppModel? { modelState.wrappedValue }

    var body: some Scene {
        // One window: there is one player and one video view.
        Window("Tuner", id: "main") {
            if let model {
                MainWindow(model: model)
            } else {
                ContentUnavailableView("Tuner could not open its library", systemImage: "exclamationmark.triangle")
                    .frame(minWidth: 480, minHeight: 300)
            }
        }
        .defaultSize(width: 1280, height: 760)
        .commands { SourceCommands(model: model) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// MARK: - Window

private struct MainWindow: View {
    let model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 170, ideal: 210, max: 300)
        } content: {
            ChannelListView(model: model)
                .navigationSplitViewColumnWidth(min: 240, ideal: 320, max: 520)
        } detail: {
            PlayerPaneView(model: model)
        }
        .navigationTitle(title)
        .navigationSubtitle(model.importMessage ?? "")
        .sheet(item: prompt) { prompt in
            SourceURLSheet(kind: prompt.kind) { location in
                Task {
                    switch prompt.kind {
                    case .playlist: await model.addPlaylist(location: location)
                    case .guide: await model.addGuide(location: location)
                    }
                }
            }
        }
        .frame(minWidth: 900, minHeight: 500)
    }

    private var title: String {
        switch model.section {
        case .recents: return "Recents"
        case .favourites: return "Favourites"
        case .sports: return "Sports"
        case .all: return "All channels"
        case .group(let name): return name
        }
    }

    private var prompt: Binding<SourcePrompt?> {
        Binding(
            get: { model.sourcePrompt.map(SourcePrompt.init) },
            set: { model.sourcePrompt = $0?.kind })
    }
}

private struct SourcePrompt: Identifiable {
    let kind: SourceKind
    var id: SourceKind { kind }
}

// MARK: - Sources

private struct SourceCommands: Commands {
    let model: AppModel?

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Group {
                Button("Add Playlist File…") {
                    if let model { PlaylistFilePanel.present(for: model) }
                }
                Button("Add Playlist URL…") { model?.sourcePrompt = .playlist }
                Button("Add Guide URL…") { model?.sourcePrompt = .guide }
                Divider()
                Button("Refresh Sources") {
                    if let model { Task { await model.refreshAll() } }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
            .disabled(model?.isImporting ?? true)
        }
    }
}

/// Lets the owner pick a playlist file and imports it. A plain path is stored, so a refresh rereads it.
@MainActor enum PlaylistFilePanel {
    static func present(for model: AppModel) {
        let panel = NSOpenPanel()
        panel.message = "Choose a playlist file"
        panel.prompt = "Add"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await model.addPlaylist(location: url.path) }
        }
    }
}

/// One text field for a playlist or guide URL.
private struct SourceURLSheet: View {
    let kind: SourceKind
    let add: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    private var textState = State(initialValue: "")

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(kind == .playlist ? "Add Playlist URL" : "Add Guide URL").font(.headline)
            TextField("http://", text: textState.projectedValue)
                .textFieldStyle(.roundedBorder)
                .frame(width: 440)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(location == nil)
            }
        }
        .padding(20)
    }

    /// The trimmed text when it is an http(s) URL with a host.
    private var location: String? {
        let trimmed = textState.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://"),
              let host = URL(string: trimmed)?.host, !host.isEmpty
        else { return nil }
        return trimmed
    }

    private func submit() {
        guard let location else { return }
        add(location)
        dismiss()
    }
}

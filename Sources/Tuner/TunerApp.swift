import AppKit
import SwiftUI
import TunerCore

@main
struct TunerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.open()

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
        .commands {
            SourceCommands(model: model)
            ChannelCommands(model: model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// MARK: - Window

/// Which pane has the keyboard. `channelList` is the middle column's list: the channels, or the search
/// results while they show. The sidebar's search field is `search`; typing a letter in the middle
/// list moves there.
enum PaneFocus: Hashable { case channelList, player, search }

private struct MainWindow: View {
    let model: AppModel
    @FocusState private var focus: PaneFocus?
    /// The player pane alone, filling the screen.
    @State private var videoFullScreen = false
    @State private var columns = NavigationSplitViewVisibility.automatic
    @State private var columnsBeforeFullScreen = NavigationSplitViewVisibility.automatic
    /// ⌘F in video full screen: the search field takes the keyboard once the panes are back.
    @State private var searchFieldAfterFullScreen = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(model: model, focus: $focus)
                .navigationSplitViewColumnWidth(min: 170, ideal: 210, max: 300)
        } content: {
            ChannelListView(model: model, focus: $focus)
                .navigationSplitViewColumnWidth(min: 240, ideal: 320, max: 520)
        } detail: {
            PlayerPaneView(model: model, isFullScreen: $videoFullScreen, focus: $focus)
        }
        .toolbar(videoFullScreen ? .hidden : .automatic, for: .windowToolbar)
        .onExitCommand {
            if videoFullScreen {
                videoFullScreen = false
            } else if !model.searchText.isEmpty || focus == .search {
                // Leaves the search: the channel list comes back with its section and selection. It
                // replaces the results in this update, and can take focus only once it is there.
                model.searchText = ""
                Task { focus = .channelList }
            }
        }
        .onChange(of: model.searchFieldRequests) { showSearchField() }
        .onChange(of: videoFullScreen) { _, on in
            if on {
                columnsBeforeFullScreen = columns
                columns = .detailOnly
                focus = .player
            } else {
                columns = columnsBeforeFullScreen
                if searchFieldAfterFullScreen {
                    searchFieldAfterFullScreen = false
                    showSearchField()
                } else {
                    focus = .channelList
                }
            }
        }
        .background {
            WindowBridge(
                videoFullScreen: videoFullScreen,
                visibilityChanged: { model.windowVisibilityChanged($0) },
                leftFullScreen: { videoFullScreen = false })
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

    /// ⌘F, or letters typed in a list: leaves video full screen first, and shows the sidebar if it is
    /// hidden. The field may come back in this update, and can take focus only once it is there.
    private func showSearchField() {
        if videoFullScreen {
            searchFieldAfterFullScreen = true
            videoFullScreen = false
            return
        }
        if columns == .detailOnly || columns == .doubleColumn { columns = .all }
        Task { focus = .search }
    }

    private var title: String {
        if model.searchResults != nil { return "Search" }
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

/// The main window's AppKit side: reports whether the window is on screen (not minimised, hidden,
/// covered or on another Space) and when it leaves full screen by any route, and takes the window in
/// and out of full screen for the video.
private struct WindowBridge: NSViewRepresentable {
    let videoFullScreen: Bool
    let visibilityChanged: (Bool) -> Void
    let leftFullScreen: () -> Void

    func makeNSView(context: Context) -> WindowBridgeView { WindowBridgeView() }

    func updateNSView(_ view: WindowBridgeView, context: Context) {
        view.visibilityChanged = visibilityChanged
        view.leftFullScreen = leftFullScreen
        view.setVideoFullScreen(videoFullScreen)
    }
}

private final class WindowBridgeView: NSView {
    var visibilityChanged: ((Bool) -> Void)?
    var leftFullScreen: (() -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var videoFullScreen = false
    /// The window was not full screen before the video took it there, so leaving the video's full
    /// screen leaves the window's too.
    private var restoreWindowed = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        guard let window else {
            visibilityChanged?(false)
            return
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportVisibility() }
        })
        observers.append(center.addObserver(
            forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.restoreWindowed = false
                self?.leftFullScreen?()
            }
        })
        reportVisibility()
    }

    func setVideoFullScreen(_ on: Bool) {
        guard on != videoFullScreen else { return }
        videoFullScreen = on
        guard let window else { return }
        let isFullScreen = window.styleMask.contains(.fullScreen)
        if on {
            restoreWindowed = !isFullScreen
            guard !isFullScreen else { return }
        } else {
            guard restoreWindowed, isFullScreen else { return }
            restoreWindowed = false
        }
        // Not during SwiftUI's update pass, which this is called from.
        DispatchQueue.main.async { [weak window] in window?.toggleFullScreen(nil) }
    }

    private func reportVisibility() {
        visibilityChanged?(window?.occlusionState.contains(.visible) ?? false)
    }

    /// It sits behind the whole window and must never take a click.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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

// MARK: - Channel shortcuts

/// Menu items, so the shortcuts work whichever pane has the keyboard, full screen included.
private struct ChannelCommands: Commands {
    let model: AppModel?

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Find…") { model?.requestSearchField() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(model == nil)
        }
        CommandMenu("Channel") {
            Group {
                Button("Toggle Favourite") { model?.toggleFavouriteOnSelection() }
                    .keyboardShortcut("d", modifiers: .command)
                Button("Previous Channel") { model?.playPrevious() }
                    .keyboardShortcut("[", modifiers: .command)
                Divider()
                ForEach(1...9, id: \.self) { number in
                    Button("Play Recent \(number)") { model?.playRecent(number - 1) }
                        .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
                }
                Divider()
                Button(model?.showsStats == true ? "Hide Playback Stats" : "Show Playback Stats") {
                    model?.toggleStats()
                }
                .keyboardShortcut("i", modifiers: .command)
            }
            .disabled(model == nil)
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
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(kind == .playlist ? "Add Playlist URL" : "Add Guide URL").font(.headline)
            TextField("http://", text: $text)
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
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
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

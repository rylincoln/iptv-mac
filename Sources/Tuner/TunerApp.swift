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
/// list moves there. `covered` is the channel list while something covers it; nothing asks for it,
/// so a covered list never has the keyboard.
enum PaneFocus: Hashable { case channelList, player, search, covered }

private struct MainWindow: View {
    let model: AppModel
    @FocusState private var focus: PaneFocus?
    /// The player pane alone, filling the screen.
    @State private var videoFullScreen = false
    @State private var columns = NavigationSplitViewVisibility.automatic
    @State private var columnsBeforeFullScreen = NavigationSplitViewVisibility.automatic
    /// ⌘F in video full screen: the search field takes the keyboard once the panes are back.
    @State private var searchFieldAfterFullScreen = false
    /// The columns before the search field showed a hidden sidebar. Escape puts them back, unless the
    /// owner has shown or hidden a column since, or the search ended some other way (see
    /// `showSearchField`).
    @State private var columnsBeforeSearch: NavigationSplitViewVisibility?

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
                // Leaves the search: the channel list, kept in the window under the results, shows
                // again with its section and selection. It is uncovered in this update, and can take
                // focus only once that is done; a sidebar the search showed is hidden again with it.
                model.searchText = ""
                let restore = columnsBeforeSearch
                columnsBeforeSearch = nil
                Task {
                    focus = .channelList
                    if let restore { columns = restore }
                }
            }
        }
        .onChange(of: model.searchFieldRequests) { showSearchField() }
        .onChange(of: columns) { _, now in
            if now != .all { columnsBeforeSearch = nil }  // the owner's own choice stands
        }
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
        if columns == .detailOnly || columns == .doubleColumn {
            columnsBeforeSearch = columns
            columns = .all
        } else if model.searchResults == nil {
            // A new search, the sidebar already showing. If an earlier search showed it, that search
            // ended some other way than Escape (a section chosen, the field cleared): the sidebar
            // stays, and Escape this time leaves it.
            columnsBeforeSearch = nil
        }
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
    /// What was asked for last: the video alone, full screen.
    private var videoFullScreen = false
    /// The window was not full screen before the video took it there, so leaving the video's full
    /// screen leaves the window's too.
    private var restoreWindowed = false
    /// The window is going into or out of full screen, or has just been asked to. AppKit cannot turn
    /// round in the middle, so a request made meanwhile waits for the end of it (see `matchRequest`).
    private var inTransition = false
    private var transitionBegan = false
    /// When the transition began. AppKit tells a failed transition only to the window's delegate, which
    /// is SwiftUI's, so one that never ends stops holding requests back after `transitionLimit`.
    private var transitionStartedAt: TimeInterval = 0
    private static let transitionLimit: TimeInterval = 5

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        inTransition = false
        guard let window else {
            visibilityChanged?(false)
            return
        }
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, _ action: @escaping @MainActor (WindowBridgeView) -> Void) {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let self { action(self) }
                }
            })
        }
        observe(NSWindow.didChangeOcclusionStateNotification) { $0.reportVisibility() }
        observe(NSWindow.willEnterFullScreenNotification) { $0.transitionWillBegin() }
        observe(NSWindow.willExitFullScreenNotification) { $0.transitionWillBegin() }
        observe(NSWindow.didEnterFullScreenNotification) { view in
            // Asked to leave while going in: leave now. On the next turn: AppKit is still finishing
            // the transition while it tells of its end, and ignores a toggle made then.
            view.inTransition = false
            DispatchQueue.main.async { [weak view] in view?.matchRequest() }
        }
        observe(NSWindow.didExitFullScreenNotification) { view in
            // By any route. A request to go back in made while it was leaving is dropped.
            view.inTransition = false
            view.restoreWindowed = false
            view.leftFullScreen?()
        }
        reportVisibility()
    }

    func setVideoFullScreen(_ on: Bool) {
        guard on != videoFullScreen else { return }
        videoFullScreen = on
        // Not during SwiftUI's update pass, which this is called from.
        DispatchQueue.main.async { [weak self] in self?.matchRequest() }
    }

    /// Takes the window into or out of full screen as last asked, unless a transition is under way: its
    /// end calls this again. However quickly requests come, the window ends full screen with the video
    /// alone, or as it was with the panes.
    private func matchRequest() {
        let now = ProcessInfo.processInfo.systemUptime
        if inTransition, now - transitionStartedAt < Self.transitionLimit { return }
        guard let window else { return }
        let isFullScreen = window.styleMask.contains(.fullScreen)
        if videoFullScreen {
            guard !isFullScreen else { return }  // there already, by this or by the owner beforehand
            restoreWindowed = true
        } else {
            guard restoreWindowed, isFullScreen else { return }
        }
        inTransition = true
        transitionBegan = false
        transitionStartedAt = now
        window.toggleFullScreen(nil)
        // AppKit says it is starting before it returns. Had it not started (the window cannot go full
        // screen just now), nothing is left waiting.
        if !transitionBegan {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.transitionBegan else { return }
                self.inTransition = false
            }
        }
    }

    private func transitionWillBegin() {
        if !inTransition { transitionStartedAt = ProcessInfo.processInfo.systemUptime }
        inTransition = true
        transitionBegan = true
    }

    private func reportVisibility() {
        visibilityChanged?(window?.occlusionState.contains(.visible) ?? false)
    }

    /// It sits behind the whole window and must never take a click.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Sources

/// One import runs at a time, and a request made meanwhile is not queued: while one runs, these items
/// are disabled and the last of them reads "Importing…" to say why.
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
                Button(model?.isImporting == true ? "Importing…" : "Refresh Sources") {
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
                // Closes the stream, which frees the provider connection, and lets the display sleep.
                Button("Stop") { model?.stop() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled((model?.status ?? .idle) == .idle)
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

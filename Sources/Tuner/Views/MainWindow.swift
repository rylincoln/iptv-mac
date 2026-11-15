import SwiftUI
import TunerCore

// MARK: - Window

/// Which pane has the keyboard. `channelList` is the middle column's list: the channels, or the search
/// results while they show. The sidebar's search field is `search`; typing a letter in the middle
/// list moves there. `covered` is the channel list while something covers it; nothing asks for it,
/// so a covered list never has the keyboard.
enum PaneFocus: Hashable { case channelList, player, search, covered }

struct MainWindow: View {
    let model: AppModel
    @FocusState private var focus: PaneFocus?
    @State private var columns = NavigationSplitViewVisibility.automatic
    /// The columns before the search field showed a hidden sidebar; Escape puts them back. Forgotten
    /// when the owner shows or hides a column, when the search's results go without Escape (a section
    /// chosen, the field cleared), when the field loses the keyboard with nothing typed, and when the
    /// field is asked for again with the sidebar showing and no results up.
    @State private var columnsBeforeSearch: NavigationSplitViewVisibility?

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(model: model, focus: $focus)
                .navigationSplitViewColumnWidth(min: 170, ideal: 210, max: 300)
        } detail: {
            // Only marks where the player pane goes; the pane itself is laid over the window (below).
            // Under the toolbar too: the video runs to the window's top edge.
            Color.clear.ignoresSafeArea(edges: .top)
                .anchorPreference(key: PlayerPaneFrame.self, value: .bounds) { $0 }
        }
        // The player pane (the video, with the channel list and what is on laid over it) sits above
        // the columns, over the detail column's place, and over the whole window when the video has
        // it alone. Placed this way the video's view never changes parent, in or out of full screen.
        .overlayPreferenceValue(PlayerPaneFrame.self) { anchor in
            GeometryReader { proxy in
                let whole = CGRect(origin: .zero, size: proxy.size)
                let frame = model.videoFullScreen ? whole : anchor.map { proxy[$0] } ?? whole
                PlayerPaneView(
                    model: model, focus: $focus,
                    // What the toolbar covers of the pane, which the list and the corners keep clear of.
                    topInset: model.videoFullScreen ? 0 : proxy.safeAreaInsets.top
                )
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
            }
            .ignoresSafeArea()
        }
        .toolbar(model.videoFullScreen ? .hidden : .automatic, for: .windowToolbar)
        .toolbar(removing: model.showsChannelList ? nil : .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)  // nothing drawn across the video
        .onExitCommand {
            model.send(.escape(searching: !model.searchText.isEmpty || focus == .search))
        }
        .onChange(of: model.windowOutcomeCount) {
            for outcome in model.takeWindowOutcomes() { carryOut(outcome) }
        }
        .onChange(of: columns) { _, now in
            if now != .all { columnsBeforeSearch = nil }  // the owner's own choice stands
        }
        .onChange(of: model.showsSearchResults) { _, showing in
            // The search ended. By Escape, which has already taken the columns to put back; any other
            // way, and the sidebar stays as it is, whatever starts the next search.
            if !showing { columnsBeforeSearch = nil }
        }
        .onChange(of: focus) { old, now in
            // The field left with nothing typed (a click elsewhere): that search is over, and the
            // sidebar it showed stays, whatever starts the next one. Nothing typed, not no results: a
            // letter typed in a list is in the text before the field has the keyboard, and the
            // results come a moment later. Escape takes the columns to put back before it moves the
            // keyboard.
            if old == .search, now != .search, model.searchText.isEmpty { columnsBeforeSearch = nil }
        }
        .background {
            WindowBridge(
                videoFullScreen: model.videoFullScreen,
                visibilityChanged: { model.windowVisibilityChanged($0) },
                leftFullScreen: { model.send(.windowLeftFullScreen) })
        }
        .navigationTitle(title)
        .navigationSubtitle(model.importMessage ?? "")
        .sheet(item: prompt) { prompt in
            SourceURLSheet(kind: prompt.kind, model: model) { location in
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

    /// What `WindowState` leaves the window to do after an event.
    private func carryOut(_ outcome: WindowState.Outcome) {
        if outcome.leaveSearch {
            // The channel list, kept in the window under the results, shows again with its section
            // and selection. It is uncovered in this update, and can take focus only once that is
            // done; a sidebar the search showed is hidden again with it.
            model.searchText = ""
            let restore = columnsBeforeSearch
            columnsBeforeSearch = nil
            Task {
                focus = .channelList
                if let restore { columns = restore }
            }
        }
        if outcome.showSearchField { showSearchField() }
        if let target = outcome.focus {
            // On the next turn, once the list is uncovered or covered.
            Task {
                switch target {
                case .player: focus = .player
                case .channelList: focus = .channelList
                case .channelListUnlessSearchField: if focus != .search { focus = .channelList }
                }
            }
        }
    }

    /// ⌘F, or letters typed in a list (full screen is already left): shows the sidebar if it is
    /// hidden. The field may come back in this update, and can take focus only once it is there.
    private func showSearchField() {
        if columns == .detailOnly || columns == .doubleColumn {
            columnsBeforeSearch = columns
            columns = .all
        } else if model.searchResults == nil {
            // A new search, the sidebar already showing. An earlier search that showed it ended before
            // finding anything (the field left with nothing typed): the sidebar stays.
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

/// Where the detail column is, for the player pane laid over it.
private struct PlayerPaneFrame: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

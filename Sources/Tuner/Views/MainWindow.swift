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
    /// The player pane alone, filling the screen.
    @State private var videoFullScreen = false
    @State private var columns = NavigationSplitViewVisibility.automatic
    @State private var columnsBeforeFullScreen = NavigationSplitViewVisibility.automatic
    /// ⌘F in video full screen: the search field takes the keyboard once the panes are back.
    @State private var searchFieldAfterFullScreen = false
    /// The columns before the search field showed a hidden sidebar; Escape puts them back. Forgotten
    /// when the owner shows or hides a column, when the search's results go without Escape (a section
    /// chosen, the field cleared), and when the field is asked for again with the sidebar showing and
    /// no results up (an earlier search that showed it ended before finding anything).
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
        .onChange(of: model.showsSearchResults) { _, showing in
            // The search ended. By Escape, which has already taken the columns to put back; any other
            // way, and the sidebar stays as it is, whatever starts the next search.
            if !showing { columnsBeforeSearch = nil }
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

import AppKit
import SwiftUI
import TunerCore

struct ChannelListView: View {
    @Bindable var model: AppModel
    var focus: FocusState<PaneFocus?>.Binding

    var body: some View {
        // The channel list stays in the window for as long as the window is open. Search results and
        // the first-run prompt cover it rather than replace it: a List put back into the window holding
        // thousands of rows is slow to rebuild and makes AppKit warn of a reentrant table delegate.
        // Covered, it keeps its rows, selection and scroll position, and takes no keyboard, clicks or
        // VoiceOver: no focus value names it (`PaneFocus.channelList` then means the results list),
        // Tab passes it by (`focusable(false)`; with no interactions, `true` adds no Tab stop of its
        // own), and it is not hit-tested.
        let covered = model.searchResults != nil || !model.hasChannels
        ZStack {
            channelList(covered: covered)
                .opacity(covered ? 0 : 1)
                .focusable(!covered, interactions: [])
                .allowsHitTesting(!covered)
                .accessibilityHidden(covered)
                .onChange(of: covered) { _, isCovered in
                    // Covered while it had the keyboard (results came in, or the library proved empty):
                    // the keyboard goes to the results, or nowhere. Uncovered with nothing focused (the
                    // first import, a section chosen while searching): to the list, as when it first
                    // appears. On the next turn, once the focus bindings above have changed.
                    Task {
                        if isCovered {
                            if focus.wrappedValue == .covered {
                                focus.wrappedValue = model.searchResults != nil ? .channelList : nil
                            }
                        } else if focus.wrappedValue == nil {
                            focus.wrappedValue = .channelList
                        }
                    }
                }
            if let results = model.searchResults {
                SearchResultsView(model: model, results: results, focus: focus)
            } else if !model.hasChannels {
                ContentUnavailableView {
                    Label("Add a playlist to get started", systemImage: "tv")
                } actions: {
                    Button("Add Playlist File…") { PlaylistFilePanel.present(for: model) }
                        .disabled(model.isImporting)
                }
            }
        }
    }

    private func channelList(covered: Bool) -> some View {
        // Read once here, so rows get plain values and nothing per row touches the model.
        let nowPlaying = model.nowPlaying
        let now = model.nowPlayingAt
        return List(model.rows, selection: $model.selectedChannelID) { channel in
            ChannelRowView(channel: channel, programme: channel.guideRef.flatMap { nowPlaying[$0] }, now: now)
        }
        // Every row is 40 pt plus the list's 8 pt of insets. Told this, the list sizes all rows before
        // drawing them, so the scroller does not jump while a long list scrolls (measured on macOS 27).
        .environment(\.defaultMinListRowHeight, ChannelRowView.height + 8)
        .focused(focus, equals: covered ? .covered : .channelList)
        .onAppear {
            if focus.wrappedValue == nil { focus.wrappedValue = .channelList }
        }
        // One modifier for the whole list: double-click plays, no per-row gestures.
        .contextMenu(forSelectionType: Int64.self) { ids in
            if let channel = channel(in: ids) {
                Button("Play") { model.play(channel) }
                Button(channel.isFavourite ? "Remove from Favourites" : "Add to Favourites") {
                    model.toggleFavourite(channel)
                }
            }
        } primaryAction: { ids in
            if let channel = channel(in: ids) { model.play(channel) }
        }
        .onKeyPress(.return) {
            guard let id = model.selectedChannelID, let channel = channel(in: [id]) else { return .ignored }
            model.play(channel)
            return .handled
        }
        .typingStartsSearch(model: model, focus: focus)
        .overlay {
            if model.rows.isEmpty {
                Text(emptyText).foregroundStyle(.secondary)
            }
        }
    }

    /// The one listed channel the ids name, if they name exactly one.
    private func channel(in ids: Set<Int64>) -> ChannelRow? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return model.rows.first { $0.id == id }
    }

    private var emptyText: String {
        switch model.section {
        case .recents: return "No recent channels"
        case .favourites: return "No favourites"
        case .sports, .all, .group: return "No channels"
        }
    }
}

extension View {
    /// Typing a letter starts a search, or adds to the one showing: the letter goes into the search
    /// text and focus moves to the search field, which attaches itself to `PaneFocus.search` and puts
    /// the insertion point after the letter. The request lets the window show the sidebar first if it
    /// is hidden.
    func typingStartsSearch(model: AppModel, focus: FocusState<PaneFocus?>.Binding) -> some View {
        onKeyPress(characters: .letters, phases: .down) { press in
            guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
            model.searchText += press.characters
            focus.wrappedValue = .search
            model.requestSearchField()
            return .handled
        }
    }
}

/// Logo, name, a star for a favourite, and what is on now with a bar for how far through it is. The
/// same fixed height with or without a programme, so every row is alike and cheap to lay out. Also
/// the rows of the search results' Channels section.
struct ChannelRowView: View {
    static let height: CGFloat = 40

    let channel: ChannelRow
    let programme: ProgrammeRow?
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            LogoView(urlString: channel.logoURL)
                .id(channel.logoURL)  // a row given another logo starts afresh
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(channel.name).lineLimit(1)
                    if channel.isFavourite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Favourite")
                    }
                }
                if let programme {
                    Text(programme.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    ElapsedBar(fraction: elapsedFraction(start: programme.start, stop: programme.stop, now: now))
                }
            }
        }
        .frame(height: Self.height)
    }
}

/// How far `now` is through `start..<stop`, from 0 to 1.
private func elapsedFraction(start: Date, stop: Date, now: Date) -> Double {
    let length = stop.timeIntervalSince(start)
    guard length > 0 else { return 0 }
    return min(max(now.timeIntervalSince(start) / length, 0), 1)
}

/// A thin track filled from the leading edge to `fraction`.
private struct ElapsedBar: View {
    let fraction: Double

    var body: some View {
        Capsule()
            .fill(.quaternary)
            .overlay(alignment: .leading) { LeadingPart(fraction: fraction).fill(.secondary) }
            .clipShape(Capsule())
            .frame(height: 3)
    }

    private struct LeadingPart: Shape {
        let fraction: Double

        func path(in rect: CGRect) -> Path {
            Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width * fraction, height: rect.height))
        }
    }
}

/// A 32 pt logo with rounded corners. Draws a placeholder at once and the logo when it arrives; a
/// logo already in memory is drawn straight away. The load is cancelled if the row scrolls away first.
struct LogoView: View {
    let urlString: String?
    @State private var loaded: NSImage?

    var body: some View {
        ZStack {
            if let image = loaded ?? cached {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Rectangle().fill(.quaternary)
                Image(systemName: "tv").foregroundStyle(.tertiary)
            }
        }
        .frame(width: LogoCache.pointSize, height: LogoCache.pointSize)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task {
            guard let urlString, loaded == nil, cached == nil else { return }
            loaded = await LogoCache.shared.image(for: urlString)
        }
    }

    private var cached: NSImage? {
        urlString.flatMap { LogoCache.shared.cachedImage(for: $0) }
    }
}

import SwiftUI
import TunerCore

/// Shown over the channel list, which stays in the window beneath it, while a search has results:
/// "On now", "Later" and "Channels", each left out when empty, as one list the arrow keys move
/// straight through. Return or a double-click acts on a row (`AppModel.activateSearchResult`).
struct SearchResultsView: View {
    @Bindable var model: AppModel
    let results: SearchResults
    /// The channel list is put away, and the results with it: they take no keyboard.
    let hidden: Bool
    var focus: FocusState<PaneFocus?>.Binding

    var body: some View {
        if results.isEmpty {
            Text("No results")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            list
        }
    }

    private var list: some View {
        // Read once here, so rows get plain values and nothing per row touches the model.
        let nowPlaying = model.nowPlaying
        let now = model.nowPlayingAt
        let days = StartTimeForm.Days(now: now)
        return ScrollViewReader { proxy in
            resultList(nowPlaying: nowPlaying, now: now, days: days)
                // New results show from the top, where their first row is selected. Asked to centre the
                // top row, the list can only scroll to its very top, so the first section's header
                // shows above the row rather than floating over it. Only a new search scrolls: a
                // favourite toggled in the results leaves the list where it is. The scroll waits for
                // the next turn of the main actor, once this update is done.
                .onChange(of: model.resultsGeneration) {
                    guard let first = results.firstResultID else { return }
                    Task { proxy.scrollTo(first, anchor: .center) }
                }
        }
    }

    private func resultList(nowPlaying: [Int64: ProgrammeRow], now: Date, days: StartTimeForm.Days) -> some View {
        List(selection: $model.selectedResultID) {
            if !results.onNow.isEmpty {
                Section("On now") {
                    ForEach(results.onNow, id: \.onNowID) { hit in
                        ProgrammeHitRow(hit: hit, start: nil)
                    }
                }
            }
            if !results.later.isEmpty {
                Section("Later") {
                    ForEach(results.later, id: \.laterID) { hit in
                        ProgrammeHitRow(hit: hit, start: StartTime.text(hit.programme.start, days: days))
                    }
                }
            }
            if !results.channels.isEmpty {
                Section("Channels") {
                    ForEach(results.channels, id: \.resultID) { channel in
                        ChannelRowView(
                            channel: channel, programme: channel.guideRef.flatMap { nowPlaying[$0] }, now: now)
                    }
                }
            }
        }
        .environment(\.defaultMinListRowHeight, ChannelRowView.height + 8)
        .focusable(!hidden, interactions: [])
        .focused(focus, equals: hidden ? .covered : .channelList)
        // One modifier for the whole list: double-click acts, no per-row gestures.
        .contextMenu(forSelectionType: SearchResultID.self) { _ in
            EmptyView()
        } primaryAction: { ids in
            if !hidden, ids.count == 1, let id = ids.first { model.activateSearchResult(id) }
        }
        .onKeyPress(.return) {
            guard !hidden, let id = model.selectedResultID else { return .ignored }
            model.activateSearchResult(id)
            return .handled
        }
        .typingStartsSearch(model: model, focus: focus)
    }
}

/// Logo, then LIVE or the start time, the title, the sub-title and the channel's name. One fixed
/// height, so rows are alike and cheap to lay out.
private struct ProgrammeHitRow: View {
    static let height: CGFloat = 48

    let hit: ProgrammeHit
    /// Nil for a programme on now, which shows LIVE instead.
    let start: String?

    var body: some View {
        HStack(spacing: 8) {
            LogoView(urlString: hit.channel.logoURL)
                .id(hit.channel.logoURL)  // a row given another logo starts afresh
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    if let start {
                        Text(start).foregroundStyle(.secondary).monospacedDigit().fixedSize()
                    } else {
                        LiveBadge()
                    }
                    Text(hit.programme.title).lineLimit(1)
                }
                if let subTitle = hit.programme.subTitle, !subTitle.isEmpty {
                    Text(subTitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(hit.channel.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(height: Self.height)
    }
}

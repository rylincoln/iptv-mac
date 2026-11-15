import SwiftUI
import TunerCore

struct ChannelListView: View {
    @Bindable var model: AppModel

    var body: some View {
        if model.hasChannels {
            channelList
        } else {
            ContentUnavailableView {
                Label("Add a playlist to get started", systemImage: "tv")
            } actions: {
                Button("Add Playlist File…") { PlaylistFilePanel.present(for: model) }
                    .disabled(model.isImporting)
            }
        }
    }

    private var channelList: some View {
        List(model.rows, selection: $model.selectedChannelID) { channel in
            Text(channel.name).lineLimit(1)
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

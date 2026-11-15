import TunerCore

/// One row of the search results, as the list selects it.
enum SearchResultID: Hashable {
    case onNow(programmeID: Int64, channelID: Int64)
    case later(programmeID: Int64, channelID: Int64)
    case channel(Int64)
}

extension SearchResults {
    var isEmpty: Bool { onNow.isEmpty && later.isEmpty && channels.isEmpty }

    /// The top row, in the order the list shows the sections.
    var firstResultID: SearchResultID? {
        if let hit = onNow.first { return hit.onNowID }
        if let hit = later.first { return hit.laterID }
        return channels.first?.resultID
    }

    /// The row to select in these results, found again for the same text, where `id` was selected
    /// before: the same row if it is here, the same programme on now if it was later and has begun,
    /// and otherwise the top row.
    func selection(following id: SearchResultID?) -> SearchResultID? {
        switch id {
        case .onNow(let programmeID, let channelID):
            if onNow.contains(where: { $0.programme.id == programmeID && $0.channel.id == channelID }) { return id }
        case .later(let programmeID, let channelID):
            if later.contains(where: { $0.programme.id == programmeID && $0.channel.id == channelID }) { return id }
            if onNow.contains(where: { $0.programme.id == programmeID && $0.channel.id == channelID }) {
                return .onNow(programmeID: programmeID, channelID: channelID)
            }
        case .channel(let channelID):
            if channels.contains(where: { $0.id == channelID }) { return id }
        case nil:
            break
        }
        return firstResultID
    }
}

extension ProgrammeHit {
    var onNowID: SearchResultID { .onNow(programmeID: programme.id, channelID: channel.id) }
    var laterID: SearchResultID { .later(programmeID: programme.id, channelID: channel.id) }
}

extension ChannelRow {
    var resultID: SearchResultID { .channel(id) }
}

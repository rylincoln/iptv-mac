/// One row of the search results, as the list selects it.
public enum SearchResultID: Hashable, Sendable {
    case onNow(programmeID: Int64, channelID: Int64)
    case later(programmeID: Int64, channelID: Int64)
    case channel(Int64)
}

extension SearchResults {
    /// Every row, in the order the list shows them: on now, later, then channels.
    public var resultIDs: [SearchResultID] {
        onNow.map { .onNow(programmeID: $0.programme.id, channelID: $0.channel.id) }
            + later.map { .later(programmeID: $0.programme.id, channelID: $0.channel.id) }
            + channels.map { .channel($0.id) }
    }

    /// The row to select in these results, found again for the same text as `old`, where `id` was
    /// selected. In order:
    /// - the same row, if it is still here;
    /// - a later programme that has begun: the same programme, on now;
    /// - a programme on now that has ended: what its channel has on now, if that is found too;
    /// - the row that takes its place: the next row of `old` still here, else the last one before it,
    ///   as the list closes up over it;
    /// - the top row. Also when nothing was selected.
    /// The refreshed list is not scrolled, so the selection stays among the rows on screen where it can.
    public func selection(following id: SearchResultID?, in old: SearchResults) -> SearchResultID? {
        let ids = resultIDs
        guard let id else { return ids.first }
        let here = Set(ids)
        if here.contains(id) { return id }
        switch id {
        case .later(let programmeID, let channelID):
            let begun = SearchResultID.onNow(programmeID: programmeID, channelID: channelID)
            if here.contains(begun) { return begun }
        case .onNow(_, let channelID):
            if let next = onNow.first(where: { $0.channel.id == channelID }) {
                return .onNow(programmeID: next.programme.id, channelID: channelID)
            }
        case .channel:
            break
        }
        let oldRows = old.resultIDs.map(Listed.init)
        if let place = ListSelection.afterRemoving(from: oldRows, where: { !here.contains($0.id) }, selected: id),
           here.contains(place) {
            return place
        }
        return ids.first
    }
}

private struct Listed: Identifiable {
    let id: SearchResultID
}

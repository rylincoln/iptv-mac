import TunerCore

// `SearchResultID`, and where the selection goes when results are found again, are in TunerCore
// (SearchSelection.swift).

extension SearchResults {
    var isEmpty: Bool { onNow.isEmpty && later.isEmpty && channels.isEmpty }

    /// The top row, in the order the list shows the sections.
    var firstResultID: SearchResultID? {
        if let hit = onNow.first { return hit.onNowID }
        if let hit = later.first { return hit.laterID }
        return channels.first?.resultID
    }
}

extension ProgrammeHit {
    var onNowID: SearchResultID { .onNow(programmeID: programme.id, channelID: channel.id) }
    var laterID: SearchResultID { .later(programmeID: programme.id, channelID: channel.id) }
}

extension ChannelRow {
    var resultID: SearchResultID { .channel(id) }
}

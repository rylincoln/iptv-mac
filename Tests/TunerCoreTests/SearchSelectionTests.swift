import Foundation
import Testing
@testable import TunerCore

private func channel(_ id: Int64) -> ChannelRow {
    ChannelRow(
        id: id, name: "Channel \(id)", logoURL: nil, groupTitle: nil,
        streamURL: "http://example.invalid/\(id)", guideRef: id, isFavourite: false)
}

private func hit(_ programmeID: Int64, on channelID: Int64) -> ProgrammeHit {
    let programme = ProgrammeRow(
        id: programmeID, guideRef: channelID, start: Date(timeIntervalSince1970: 0),
        stop: Date(timeIntervalSince1970: 3600), title: "Programme \(programmeID)", subTitle: nil, desc: nil,
        isSport: false)
    return ProgrammeHit(programme: programme, channel: channel(channelID))
}

/// Programmes as (programme, channel) pairs; channels by id.
private func results(
    onNow: [(Int64, Int64)] = [], later: [(Int64, Int64)] = [], channels: [Int64] = []
) -> SearchResults {
    SearchResults(
        onNow: onNow.map { hit($0.0, on: $0.1) }, later: later.map { hit($0.0, on: $0.1) },
        channels: channels.map(channel))
}

private func onNow(_ programmeID: Int64, _ channelID: Int64) -> SearchResultID {
    .onNow(programmeID: programmeID, channelID: channelID)
}

private func later(_ programmeID: Int64, _ channelID: Int64) -> SearchResultID {
    .later(programmeID: programmeID, channelID: channelID)
}

@Suite struct SearchSelectionTests {
    @Test func rowsAreListedInTheOrderShown() {
        let found = results(onNow: [(1, 1)], later: [(5, 2), (6, 3)], channels: [4])
        #expect(found.resultIDs == [onNow(1, 1), later(5, 2), later(6, 3), .channel(4)])
    }

    @Test func aRowStillHereStaysSelected() {
        let old = results(onNow: [(1, 1), (2, 2)], later: [(5, 2)], channels: [4, 7])
        let new = results(onNow: [(2, 2)], later: [(5, 2)], channels: [7])
        #expect(new.selection(following: onNow(2, 2), in: old) == onNow(2, 2))
        #expect(new.selection(following: later(5, 2), in: old) == later(5, 2))
        #expect(new.selection(following: .channel(7), in: old) == .channel(7))
    }

    @Test func aLaterProgrammeThatHasBegunIsFollowedOnNow() {
        let old = results(onNow: [(1, 1)], later: [(5, 2)])
        let new = results(onNow: [(1, 1), (5, 2)])
        #expect(new.selection(following: later(5, 2), in: old) == onNow(5, 2))
    }

    /// Not the row below, which is another channel: the one asked for is still on screen where it was.
    @Test func anEndedProgrammeGivesWayToWhatItsChannelHasOnNow() {
        let old = results(onNow: [(1, 1), (2, 2)])
        let new = results(onNow: [(2, 2), (3, 1)])
        #expect(new.selection(following: onNow(1, 1), in: old) == onNow(3, 1))
    }

    @Test func anEndedProgrammeWithNothingOnItsChannelGivesWayToTheRowThatTakesItsPlace() {
        let old = results(onNow: [(1, 1), (2, 2), (4, 4)], later: [(5, 5)])
        #expect(results(onNow: [(1, 1), (4, 4)], later: [(5, 5)]).selection(following: onNow(2, 2), in: old)
            == onNow(4, 4))
        // The last on now: the rows close up from below, a later programme first.
        #expect(results(onNow: [(1, 1), (2, 2)], later: [(5, 5)]).selection(following: onNow(4, 4), in: old)
            == later(5, 5))
        // The last row of all: the one above it.
        #expect(results(onNow: [(1, 1), (2, 2)]).selection(following: onNow(4, 4), in: old) == onNow(2, 2))
    }

    /// Only a programme on now hands over to its channel: a later one that left is not on now.
    @Test func aLaterProgrammeThatLeftGivesWayToTheRowThatTakesItsPlace() {
        let old = results(later: [(5, 2), (6, 3)])
        let new = results(onNow: [(7, 2)], later: [(6, 3)])
        #expect(new.selection(following: later(5, 2), in: old) == later(6, 3))
    }

    @Test func aChannelThatLeftGivesWayToTheRowThatTakesItsPlace() {
        let old = results(channels: [1, 2, 3])
        #expect(results(channels: [1, 3]).selection(following: .channel(2), in: old) == .channel(3))
        #expect(results(channels: [1, 2]).selection(following: .channel(3), in: old) == .channel(2))
    }

    @Test func withNothingSelectedOrNothingNearItLeftTheTopRowIsSelected() {
        let old = results(onNow: [(1, 1)], channels: [2])
        let new = results(onNow: [(8, 8)], channels: [9])
        #expect(new.selection(following: nil, in: old) == onNow(8, 8))
        #expect(new.selection(following: onNow(1, 1), in: old) == onNow(8, 8))
        #expect(new.selection(following: .channel(5), in: old) == onNow(8, 8))  // never listed
        #expect(results().selection(following: onNow(1, 1), in: old) == nil)
    }
}

import Foundation
import GRDB
import Testing
@testable import TunerCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let hour: TimeInterval = 3600

private func at(_ hours: Double) -> Date { now.addingTimeInterval(hours * hour) }

private func prog(
    _ channel: String, _ from: Double, _ to: Double, _ title: String = "Show",
    categories: [String] = []
) -> ParsedProgramme {
    ParsedProgramme(channelID: channel, start: at(from), stop: at(to), title: title, categories: categories)
}

private func guideChannel(_ id: String, _ names: String...) -> ParsedGuideChannel {
    ParsedGuideChannel(id: id, displayNames: names)
}

private struct Boom: Error {}

private func playlist(
    _ store: Store, _ channels: [ParsedChannel], location: String = "http://example.invalid/list"
) throws -> Int64 {
    let id = try store.addSource(kind: .playlist, location: location)
    try store.replaceChannels(sourceID: id, with: channels)
    return id
}

private func loadGuide(
    _ store: Store, location: String = "http://example.invalid/guide",
    channels: [ParsedGuideChannel], programmes: [ParsedProgramme] = []
) throws -> Int64 {
    let id = try store.addSource(kind: .guide, location: location)
    try store.replaceGuide(sourceID: id, now: now) { writer in
        for c in channels { try writer.add(c) }
        for p in programmes { try writer.add(p) }
    }
    return id
}

private func pc(_ name: String, _ path: String, tvgID: String? = nil, group: String? = nil) -> ParsedChannel {
    ParsedChannel(name: name, tvgID: tvgID, groupTitle: group, streamURL: "http://example.invalid/\(path)")
}

@Suite struct StoreGuideTests {
    @Test func guideImportLinksByIDThenName() throws {
        let store = try Store.inMemory()
        _ = try playlist(store, [pc("Alpha", "a", tvgID: "alpha.id"), pc("Bravo News", "b")])
        _ = try loadGuide(store, channels: [
            guideChannel("alpha.id", "Something Else"), guideChannel("bravo.id", "Bravo News"),
        ])
        let rows = try store.channels(in: .all, at: now)
        #expect(rows.allSatisfy { $0.guideRef != nil })
        #expect(rows[0].guideRef != rows[1].guideRef)
    }

    @Test func importingPlaylistAfterGuideAlsoMatches() throws {
        let store = try Store.inMemory()
        _ = try loadGuide(store, channels: [guideChannel("alpha.id", "Alpha")])
        #expect(try store.channels(in: .all, at: now).isEmpty)
        _ = try playlist(store, [pc("Alpha", "a")])
        #expect(try store.channels(in: .all, at: now).first?.guideRef != nil)
    }

    @Test func nowPlayingPicksProgrammeSpanningNow() throws {
        let store = try Store.inMemory()
        _ = try playlist(store, [pc("Alpha", "a")])
        _ = try loadGuide(store, channels: [guideChannel("alpha", "Alpha")], programmes: [
            prog("alpha", -1, 0, "Before"), prog("alpha", 0, 1, "Current"), prog("alpha", 1, 2, "Next"),
        ])
        let ref = try #require(try store.channels(in: .all, at: now).first?.guideRef)
        #expect(try store.nowPlaying(at: at(0.5))[ref]?.title == "Current")
        #expect(try store.nowPlaying(at: at(0))[ref]?.title == "Current")
        #expect(try store.nowPlaying(at: at(1))[ref]?.title == "Next")
        #expect(try store.nowPlaying(at: at(2))[ref] == nil)
    }

    @Test func nowPlayingEmptyWhenGapInSchedule() throws {
        let store = try Store.inMemory()
        _ = try loadGuide(store, channels: [guideChannel("alpha")], programmes: [
            prog("alpha", 0, 1), prog("alpha", 2, 3),
        ])
        #expect(try store.nowPlaying(at: at(1.5)).isEmpty)
    }

    @Test func upcomingIsOrderedAndLimited() throws {
        let store = try Store.inMemory()
        _ = try playlist(store, [pc("Alpha", "a")])
        _ = try loadGuide(store, channels: [guideChannel("alpha", "Alpha")], programmes: [
            prog("alpha", 3, 4, "D"), prog("alpha", 1, 2, "B"), prog("alpha", 0, 1, "A"),
            prog("alpha", 2, 3, "C"),
        ])
        let ref = try #require(try store.channels(in: .all, at: now).first?.guideRef)
        let rows = try store.upcoming(guideRef: ref, after: at(1), limit: 2)
        #expect(rows.map(\.title) == ["B", "C"])
        #expect(try store.upcoming(guideRef: ref, after: at(0), limit: 10).map(\.title) == ["A", "B", "C", "D"])
    }

    @Test func oldProgrammesArePruned() throws {
        let store = try Store.inMemory()
        _ = try playlist(store, [pc("Alpha", "a")])
        _ = try loadGuide(store, channels: [guideChannel("alpha", "Alpha")], programmes: [
            prog("alpha", -26, -25, "Old"), prog("alpha", -24, -23, "Recent"),
        ])
        let ref = try #require(try store.channels(in: .all, at: now).first?.guideRef)
        let rows = try store.upcoming(guideRef: ref, after: at(-100), limit: 10)
        #expect(rows.map(\.title) == ["Recent"])
    }

    @Test func failedLoadKeepsPreviousGuide() throws {
        let store = try Store.inMemory()
        let id = try loadGuide(store, channels: [guideChannel("alpha", "Alpha")], programmes: [
            prog("alpha", 0, 1, "Kept"),
        ])
        #expect(throws: Boom.self) {
            try store.replaceGuide(sourceID: id, now: now) { writer in
                try writer.add(guideChannel("beta", "Beta"))
                try writer.add(prog("beta", 0, 1, "Lost"))
                throw Boom()
            }
        }
        let playing = try store.nowPlaying(at: at(0.5))
        #expect(playing.values.map(\.title) == ["Kept"])
    }

    @Test func replacingGuideRemovesStaleProgrammes() throws {
        let store = try Store.inMemory()
        let id = try loadGuide(store, channels: [guideChannel("alpha", "Alpha")], programmes: [
            prog("alpha", 0, 1, "Old"),
        ])
        try store.replaceGuide(sourceID: id, now: now) { writer in
            try writer.add(guideChannel("alpha", "Alpha"))
            try writer.add(prog("alpha", 0, 1, "New"))
        }
        #expect(try store.nowPlaying(at: at(0.5)).values.map(\.title) == ["New"])
    }

    @Test func programmeForUndeclaredChannelIsDropped() throws {
        let store = try Store.inMemory()
        _ = try loadGuide(store, channels: [guideChannel("alpha", "Alpha")], programmes: [
            prog("ghost", 0, 1, "Ghost"), prog("alpha", 0, 1, "Real"),
        ])
        #expect(try store.nowPlaying(at: at(0.5)).values.map(\.title) == ["Real"])
    }

    /// Channels first: a programme whose channel has not been added yet is not stored, and is counted.
    @Test func programmeBeforeItsChannelIsDroppedAndCounted() throws {
        let store = try Store.inMemory()
        let id = try store.addSource(kind: .guide, location: "http://example.invalid/guide")
        let counts = try store.replaceGuide(sourceID: id, now: now) { writer in
            try writer.add(prog("alpha", 0, 1, "Early"))
            try writer.add(guideChannel("alpha", "Alpha"))
            try writer.add(prog("alpha", 1, 2, "Late"))
            try writer.add(prog("ghost", 0, 1, "Ghost"))
        }
        #expect(counts == GuideWriteCounts(programmes: 1, programmesWithoutChannel: 2))
        #expect(try store.nowPlaying(at: at(1.5)).values.map(\.title) == ["Late"])
        #expect(try store.nowPlaying(at: at(0.5)).isEmpty)
    }

    /// Programmes past the retention window are neither stored nor counted as stored.
    @Test func countsLeaveOutExpiredProgrammes() throws {
        let store = try Store.inMemory()
        let id = try store.addSource(kind: .guide, location: "http://example.invalid/guide")
        let counts = try store.replaceGuide(sourceID: id, now: now) { writer in
            try writer.add(guideChannel("alpha", "Alpha"))
            try writer.add(prog("alpha", -26, -25, "Old"))
            try writer.add(prog("alpha", 0, 1, "Current"))
        }
        #expect(counts == GuideWriteCounts(programmes: 1, programmesWithoutChannel: 0))
    }

    /// Callers pass the current programme's stop; the next one starts exactly then.
    @Test func upcomingIncludesAProgrammeStartingExactlyAtAfter() throws {
        let store = try Store.inMemory()
        _ = try playlist(store, [pc("Alpha", "a")])
        _ = try loadGuide(store, channels: [guideChannel("alpha", "Alpha")], programmes: [
            prog("alpha", 0, 1, "Current"), prog("alpha", 1, 2, "Next"),
        ])
        let ref = try #require(try store.channels(in: .all, at: now).first?.guideRef)
        let current = try #require(try store.nowPlaying(at: at(0.5))[ref])
        #expect(try store.upcoming(guideRef: ref, after: current.stop, limit: 5).map(\.title) == ["Next"])
    }

    @Test func idMatchBeatsNameMatch() throws {
        let store = try Store.inMemory()
        _ = try playlist(store, [pc("Bravo", "b", tvgID: "alpha.id")])
        _ = try loadGuide(store, channels: [
            guideChannel("alpha.id", "Something Else"), guideChannel("bravo.id", "Bravo"),
        ], programmes: [prog("alpha.id", 0, 1, "By id"), prog("bravo.id", 0, 1, "By name")])
        let ref = try #require(try store.channels(in: .all, at: now).first?.guideRef)
        #expect(try store.nowPlaying(at: at(0.5))[ref]?.title == "By id")
        let kind = try store.db.read { try String.fetchOne($0, sql: "SELECT matchKind FROM channel") }
        #expect(kind == MatchKind.id.rawValue)
    }

    @Test func reimportedGuideWithoutTheChannelClearsTheLink() throws {
        let store = try Store.inMemory()
        _ = try playlist(store, [pc("Alpha", "a")])
        let id = try loadGuide(store, channels: [guideChannel("alpha", "Alpha")])
        #expect(try store.channels(in: .all, at: now).first?.guideRef != nil)
        try store.replaceGuide(sourceID: id, now: now) { writer in
            try writer.add(guideChannel("beta", "Beta"))
        }
        #expect(try store.channels(in: .all, at: now).first?.guideRef == nil)
        let kind = try store.db.read { try String.fetchOne($0, sql: "SELECT matchKind FROM channel") }
        #expect(kind == nil)
    }

    @Test func sportsSectionIsInPlaylistOrder() throws {
        let store = try Store.inMemory()
        _ = try playlist(store, [
            pc("Zulu", "z", group: "Sports"), pc("Alpha", "a", group: "News"), pc("Mike", "m", group: "Sports"),
            pc("Kilo", "k", group: "News"),
        ])
        _ = try loadGuide(store, channels: [guideChannel("alpha", "Alpha")], programmes: [
            prog("alpha", 0, 1, "Match", categories: ["Football"]),
        ])
        #expect(try store.channels(in: .sports, at: at(0.5)).map(\.name) == ["Zulu", "Alpha", "Mike"])
    }

    @Test func sportsSectionIncludesChannelAiringSportNow() throws {
        let store = try Store.inMemory()
        _ = try playlist(store, [
            pc("Game", "g", group: "United States"), pc("News", "n", group: "United States"),
        ])
        _ = try loadGuide(store, channels: [guideChannel("g", "Game"), guideChannel("n", "News")],
                          programmes: [
            prog("g", 0, 1, "Match", categories: ["Football"]),
            prog("g", 1, 2, "Chat", categories: ["Talk"]),
            prog("n", 0, 2, "Headlines", categories: ["News"]),
        ])
        #expect(try store.channels(in: .sports, at: at(0.5)).map(\.name) == ["Game"])
        #expect(try store.channels(in: .sports, at: at(1)).isEmpty)
        #expect(try store.channels(in: .sports, at: at(1.5)).isEmpty)
    }

    @Test func twoGuideSourcesCoexist() throws {
        let store = try Store.inMemory()
        _ = try loadGuide(store, location: "http://example.invalid/g1",
                          channels: [guideChannel("alpha", "Alpha")], programmes: [prog("alpha", 0, 1, "One")])
        _ = try loadGuide(store, location: "http://example.invalid/g2",
                          channels: [guideChannel("alpha", "Alpha")], programmes: [prog("alpha", 0, 1, "Two")])
        let playing = try store.nowPlaying(at: at(0.5))
        #expect(playing.count == 2)
        #expect(Set(playing.values.map(\.title)) == ["One", "Two"])
    }

    @Test func expiredProgrammesOfOtherSourceArePrunedOnImport() throws {
        let store = try Store.inMemory()
        _ = try loadGuide(store, location: "http://example.invalid/g1",
                          channels: [guideChannel("alpha", "Alpha")], programmes: [prog("alpha", 0, 1, "A")])
        #expect(try store.nowPlaying(at: at(0.5)).count == 1)
        let b = try store.addSource(kind: .guide, location: "http://example.invalid/g2")
        try store.replaceGuide(sourceID: b, now: at(30)) { writer in
            try writer.add(guideChannel("beta", "Beta"))
        }
        #expect(try store.nowPlaying(at: at(0.5)).isEmpty)
    }
}

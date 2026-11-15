import Foundation
import Testing
@testable import TunerCore

private func ch(_ name: String, _ path: String, group: String? = nil) -> ParsedChannel {
    ParsedChannel(name: name, groupTitle: group, streamURL: "http://example.invalid/\(path)")
}

private func url(_ path: String) -> String { "http://example.invalid/\(path)" }

private func seeded(_ channels: [ParsedChannel]) throws -> (Store, Int64) {
    let store = try Store.inMemory()
    let id = try store.addSource(kind: .playlist, location: "http://example.invalid/list")
    try store.replaceChannels(sourceID: id, with: channels)
    return (store, id)
}

private let now = Date(timeIntervalSince1970: 1_800_000_000)

@Suite struct StoreChannelsTests {
    @Test func importAndListAll() throws {
        let (store, _) = try seeded([ch("C", "c"), ch("A", "a"), ch("B", "b")])
        let rows = try store.channels(in: .all, at: now)
        #expect(rows.map(\.name) == ["C", "A", "B"])
        #expect(rows.map(\.streamURL) == [url("c"), url("a"), url("b")])
    }

    @Test func addSourceIsIdempotentPerLocation() throws {
        let store = try Store.inMemory()
        let a = try store.addSource(kind: .playlist, location: "http://example.invalid/list")
        let b = try store.addSource(kind: .playlist, location: "http://example.invalid/list")
        let c = try store.addSource(kind: .guide, location: "http://example.invalid/guide")
        #expect(a == b)
        #expect(a != c)
        let sources = try store.sources()
        #expect(sources.count == 2)
        #expect(sources[0].kind == .playlist)
        #expect(sources[0].etag == nil)
        #expect(sources[0].itemCount == 0)
    }

    @Test func recordRefreshUpdatesSource() throws {
        let store = try Store.inMemory()
        let id = try store.addSource(kind: .playlist, location: "http://example.invalid/list")
        try store.recordRefresh(sourceID: id, etag: "e1", itemCount: 5, skippedCount: 2, error: nil, at: now)
        let row = try #require(try store.sources().first)
        #expect(row.etag == "e1")
        #expect(row.itemCount == 5)
        #expect(row.skippedCount == 2)
        #expect(row.lastError == nil)
        #expect(row.lastRefreshAt == now)
    }

    @Test func groupsAreDistinctAndSorted() throws {
        let (store, _) = try seeded([
            ch("1", "1", group: "Movies"), ch("2", "2", group: "Kids"),
            ch("3", "3", group: "Movies"), ch("4", "4"),
        ])
        #expect(try store.groups() == ["Kids", "Movies"])
    }

    @Test func groupSection() throws {
        let (store, _) = try seeded([
            ch("1", "1", group: "Movies"), ch("2", "2", group: "Kids"), ch("3", "3", group: "Movies"),
        ])
        let rows = try store.channels(in: .group("Movies"), at: now)
        #expect(rows.map(\.name) == ["1", "3"])
    }

    @Test func sportsSectionUsesGroupTitle() throws {
        let (store, _) = try seeded([
            ch("Game", "g", group: "US Sports"), ch("News", "n", group: "United States"),
        ])
        let rows = try store.channels(in: .sports, at: now)
        #expect(rows.map(\.name) == ["Game"])
    }

    @Test func favouritesToggleAndSurviveReimport() throws {
        let (store, id) = try seeded([ch("A", "a"), ch("B", "b")])
        let a = try #require(try store.channels(in: .all, at: now).first)
        try store.setFavourite(true, channelID: a.id)
        #expect(try store.channels(in: .favourites, at: now).map(\.name) == ["A"])
        #expect(try store.channels(in: .all, at: now).map(\.isFavourite) == [true, false])

        try store.replaceChannels(sourceID: id, with: [ch("A", "a"), ch("B", "b")])
        #expect(try store.channels(in: .favourites, at: now).map(\.name) == ["A"])

        let again = try #require(try store.channels(in: .all, at: now).first)
        try store.setFavourite(false, channelID: again.id)
        #expect(try store.channels(in: .favourites, at: now).isEmpty)
    }

    @Test func favouriteFollowsRenamedURLByName() throws {
        let (store, id) = try seeded([ch("A", "a"), ch("B", "b")])
        let a = try #require(try store.channels(in: .all, at: now).first)
        try store.setFavourite(true, channelID: a.id)

        try store.replaceChannels(sourceID: id, with: [ch("A", "a2"), ch("B", "b")])
        let favs = try store.channels(in: .favourites, at: now)
        #expect(favs.map(\.name) == ["A"])
        #expect(favs.first?.streamURL == url("a2"))
    }

    @Test func favouriteWithAmbiguousNameDoesNotFollow() throws {
        let (store, id) = try seeded([ch("A", "a")])
        let a = try #require(try store.channels(in: .all, at: now).first)
        try store.setFavourite(true, channelID: a.id)

        try store.replaceChannels(sourceID: id, with: [ch("A", "x"), ch("A", "y")])
        #expect(try store.channels(in: .favourites, at: now).isEmpty)

        // Comes back when the original URL returns.
        try store.replaceChannels(sourceID: id, with: [ch("A", "a"), ch("A", "y")])
        #expect(try store.channels(in: .favourites, at: now).map(\.streamURL) == [url("a")])
    }

    @Test func favouriteOfRemovedChannelDisappearsQuietly() throws {
        let (store, id) = try seeded([ch("A", "a"), ch("B", "b")])
        let a = try #require(try store.channels(in: .all, at: now).first)
        try store.setFavourite(true, channelID: a.id)

        try store.replaceChannels(sourceID: id, with: [ch("B", "b")])
        #expect(try store.channels(in: .favourites, at: now).isEmpty)
        #expect(try store.channels(in: .all, at: now).map(\.name) == ["B"])
    }

    @Test func recentsOrderedNewestFirstAndCappedAt30() throws {
        let channels = (0..<35).map { ch("Ch\($0)", "\($0)") }
        let (store, _) = try seeded(channels)
        let rows = try store.channels(in: .all, at: now)
        for (i, row) in rows.enumerated() {
            try store.recordWatched(channelID: row.id, at: Date(timeIntervalSince1970: 1_000 + Double(i)))
        }
        let recents = try store.channels(in: .recents, at: now)
        #expect(recents.count == 30)
        #expect(recents.first?.name == "Ch34")
        #expect(recents.last?.name == "Ch5")
    }

    @Test func recordWatchedTwiceKeepsOneRow() throws {
        let (store, _) = try seeded([ch("A", "a"), ch("B", "b")])
        let rows = try store.channels(in: .all, at: now)
        try store.recordWatched(channelID: rows[0].id, at: Date(timeIntervalSince1970: 100))
        try store.recordWatched(channelID: rows[1].id, at: Date(timeIntervalSince1970: 200))
        try store.recordWatched(channelID: rows[0].id, at: Date(timeIntervalSince1970: 300))
        #expect(try store.channels(in: .recents, at: now).map(\.name) == ["A", "B"])
    }

    @Test func duplicateStreamURLsImport() throws {
        let (store, _) = try seeded([ch("A", "same"), ch("A HD", "same"), ch("B", "b")])
        let rows = try store.channels(in: .all, at: now)
        #expect(rows.count == 3)
        try store.setFavourite(true, channelID: rows[0].id)
        #expect(try store.channels(in: .all, at: now).map(\.isFavourite) == [true, true, false])
    }

    @Test func bufferMemoryRoundTrip() throws {
        let store = try Store.inMemory()
        #expect(store.bufferMs(forStreamURL: url("a")) == nil)
        store.setBufferMs(2000, forStreamURL: url("a"))
        #expect(store.bufferMs(forStreamURL: url("a")) == 2000)
        store.setBufferMs(3000, forStreamURL: url("a"))
        #expect(store.bufferMs(forStreamURL: url("a")) == 3000)
    }

    @Test func reopeningFileKeepsData() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tuner-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("nested/tuner.sqlite").path

        do {
            let store = try Store(path: path)
            let id = try store.addSource(kind: .playlist, location: "http://example.invalid/list")
            try store.replaceChannels(sourceID: id, with: [ch("A", "a"), ch("B", "b")])
            let a = try #require(try store.channels(in: .all, at: now).first)
            try store.setFavourite(true, channelID: a.id)
            store.setBufferMs(1500, forStreamURL: url("a"))
        }

        let reopened = try Store(path: path)
        #expect(try reopened.channels(in: .all, at: now).map(\.name) == ["A", "B"])
        #expect(try reopened.channels(in: .favourites, at: now).map(\.name) == ["A"])
        #expect(try reopened.sources().count == 1)
        #expect(reopened.bufferMs(forStreamURL: url("a")) == 1500)
    }

    @Test func replaceWithEmptyListClearsChannels() throws {
        let (store, id) = try seeded([ch("A", "a")])
        try store.replaceChannels(sourceID: id, with: [])
        #expect(try store.channels(in: .all, at: now).isEmpty)
        #expect(try store.groups().isEmpty)
    }
}

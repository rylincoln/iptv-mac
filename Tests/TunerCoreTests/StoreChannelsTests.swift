import Foundation
import GRDB
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

/// Every row in the recent table, vanished channels included, newest first.
private func recentRows(_ store: Store) throws -> [String] {
    try store.db.read { db in
        try String.fetchAll(db, sql: "SELECT streamURL FROM recent ORDER BY lastWatchedAt DESC")
    }
}

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

    /// Written by a later version, say: left out, so the sources this version knows stay usable.
    @Test func sourcesLeavesOutARowOfAnUnknownKind() throws {
        let store = try Store.inMemory()
        let id = try store.addSource(kind: .playlist, location: "http://example.invalid/list")
        try store.db.write { db in
            try db.execute(sql: "INSERT INTO source(kind, location) VALUES ('podcast', 'http://example.invalid/pod')")
        }
        #expect(try store.sources().map(\.id) == [id])
    }

    @Test func recordRefreshOfAMissingSourceChangesNothing() throws {
        let store = try Store.inMemory()
        let id = try store.addSource(kind: .playlist, location: "http://example.invalid/list")
        let before = try store.sources()
        try store.recordRefresh(sourceID: id + 100, etag: "e", itemCount: 9, skippedCount: 9, error: "x", at: now)
        #expect(try store.sources() == before)
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
        try store.setFavourite(true, streamURL: a.streamURL, name: a.name)
        #expect(try store.channels(in: .favourites, at: now).map(\.name) == ["A"])
        #expect(try store.channels(in: .all, at: now).map(\.isFavourite) == [true, false])

        try store.replaceChannels(sourceID: id, with: [ch("A", "a"), ch("B", "b")])
        #expect(try store.channels(in: .favourites, at: now).map(\.name) == ["A"])

        let again = try #require(try store.channels(in: .all, at: now).first)
        try store.setFavourite(false, streamURL: again.streamURL, name: again.name)
        #expect(try store.channels(in: .favourites, at: now).isEmpty)
    }

    @Test func isFavouriteReadsOneStream() throws {
        let (store, _) = try seeded([ch("A", "a"), ch("B", "b")])
        #expect(try !store.isFavourite(streamURL: url("a")))
        try store.setFavourite(true, streamURL: url("a"), name: "A")
        #expect(try store.isFavourite(streamURL: url("a")))
        #expect(try !store.isFavourite(streamURL: url("b")))
        try store.setFavourite(false, streamURL: url("a"), name: "A")
        #expect(try !store.isFavourite(streamURL: url("a")))
    }

    @Test func favouritesAreOrderedByNameIgnoringCase() throws {
        let (store, _) = try seeded([ch("b", "b"), ch("C", "c"), ch("A", "a"), ch("x", "x")])
        for row in try store.channels(in: .all, at: now) where row.name != "x" {
            try store.setFavourite(true, streamURL: row.streamURL, name: row.name)
        }
        #expect(try store.channels(in: .favourites, at: now).map(\.name) == ["A", "b", "C"])
    }

    @Test func favouriteFollowsRenamedURLByName() throws {
        let (store, id) = try seeded([ch("A", "a"), ch("B", "b")])
        let a = try #require(try store.channels(in: .all, at: now).first)
        try store.setFavourite(true, streamURL: a.streamURL, name: a.name)

        try store.replaceChannels(sourceID: id, with: [ch("A", "a2"), ch("B", "b")])
        let favs = try store.channels(in: .favourites, at: now)
        #expect(favs.map(\.name) == ["A"])
        #expect(favs.first?.streamURL == url("a2"))
    }

    @Test func favouriteWithAmbiguousNameDoesNotFollow() throws {
        let (store, id) = try seeded([ch("A", "a")])
        let a = try #require(try store.channels(in: .all, at: now).first)
        try store.setFavourite(true, streamURL: a.streamURL, name: a.name)

        try store.replaceChannels(sourceID: id, with: [ch("A", "x"), ch("A", "y")])
        #expect(try store.channels(in: .favourites, at: now).isEmpty)

        // Comes back when the original URL returns.
        try store.replaceChannels(sourceID: id, with: [ch("A", "a"), ch("A", "y")])
        #expect(try store.channels(in: .favourites, at: now).map(\.streamURL) == [url("a")])
    }

    @Test func favouriteOfRemovedChannelDisappearsQuietly() throws {
        let (store, id) = try seeded([ch("A", "a"), ch("B", "b")])
        let a = try #require(try store.channels(in: .all, at: now).first)
        try store.setFavourite(true, streamURL: a.streamURL, name: a.name)

        try store.replaceChannels(sourceID: id, with: [ch("B", "b")])
        #expect(try store.channels(in: .favourites, at: now).isEmpty)
        #expect(try store.channels(in: .all, at: now).map(\.name) == ["B"])
    }

    @Test func recentsSurviveReimport() throws {
        let (store, id) = try seeded([ch("A", "a"), ch("B", "b")])
        let a = try #require(try store.channels(in: .all, at: now).first)
        try store.recordWatched(streamURL: a.streamURL, name: a.name, at: now)

        try store.replaceChannels(sourceID: id, with: [ch("A", "a"), ch("B", "b")])
        #expect(try store.channels(in: .recents, at: now).map(\.name) == ["A"])
    }

    @Test func recentFollowsRenamedURLByName() throws {
        let (store, id) = try seeded([ch("A", "a"), ch("B", "b")])
        let a = try #require(try store.channels(in: .all, at: now).first)
        try store.recordWatched(streamURL: a.streamURL, name: a.name, at: now)

        try store.replaceChannels(sourceID: id, with: [ch("A", "a2"), ch("B", "b")])
        let recents = try store.channels(in: .recents, at: now)
        #expect(recents.map(\.name) == ["A"])
        #expect(recents.first?.streamURL == url("a2"))
    }

    @Test func recentWithAmbiguousNameDoesNotFollow() throws {
        let (store, id) = try seeded([ch("A", "a")])
        let a = try #require(try store.channels(in: .all, at: now).first)
        try store.recordWatched(streamURL: a.streamURL, name: a.name, at: now)

        try store.replaceChannels(sourceID: id, with: [ch("A", "x"), ch("A", "y")])
        #expect(try store.channels(in: .recents, at: now).isEmpty)

        // Comes back when the original URL returns.
        try store.replaceChannels(sourceID: id, with: [ch("A", "a"), ch("A", "y")])
        #expect(try store.channels(in: .recents, at: now).map(\.streamURL) == [url("a")])
    }

    @Test func recentOfRemovedChannelDisappearsQuietly() throws {
        let (store, id) = try seeded([ch("A", "a"), ch("B", "b")])
        let a = try #require(try store.channels(in: .all, at: now).first)
        try store.recordWatched(streamURL: a.streamURL, name: a.name, at: now)

        try store.replaceChannels(sourceID: id, with: [ch("B", "b")])
        #expect(try store.channels(in: .recents, at: now).isEmpty)
        #expect(try store.channels(in: .all, at: now).map(\.name) == ["B"])
    }

    /// The list on screen was read before an import that dropped a channel, so its ids are stale: every
    /// row after the dropped one now has the id of the next channel down.
    @Test func favouriteAndWatchThroughARowReadBeforeAReimportLandOnThatChannel() throws {
        let (store, id) = try seeded([ch("A", "a"), ch("B", "b"), ch("C", "c")])
        let shown = try store.channels(in: .all, at: now)
        try store.replaceChannels(sourceID: id, with: [ch("B", "b"), ch("C", "c")])
        let b = shown[1]
        try store.setFavourite(true, streamURL: b.streamURL, name: b.name)
        try store.recordWatched(streamURL: b.streamURL, name: b.name, at: now)
        let favourites = try store.channels(in: .favourites, at: now).map(\.name)
        let recents = try store.channels(in: .recents, at: now).map(\.name)
        #expect(favourites == ["B"])
        #expect(recents == ["B"])
    }

    /// With a second playlist the re-imported channels get ids no stale row has, so nothing must be lost.
    @Test func favouriteAndWatchThroughAStaleRowWithTwoPlaylists() throws {
        let (store, id) = try seeded([ch("A", "a"), ch("B", "b")])
        let other = try store.addSource(kind: .playlist, location: "http://example.invalid/other")
        try store.replaceChannels(sourceID: other, with: [ch("X", "x")])
        let shown = try store.channels(in: .all, at: now)
        try store.replaceChannels(sourceID: id, with: [ch("A", "a"), ch("B", "b")])
        let b = try #require(shown.first { $0.name == "B" })
        try store.setFavourite(true, streamURL: b.streamURL, name: b.name)
        try store.recordWatched(streamURL: b.streamURL, name: b.name, at: now)
        let favourites = try store.channels(in: .favourites, at: now).map(\.name)
        let recents = try store.channels(in: .recents, at: now).map(\.name)
        #expect(favourites == ["B"])
        #expect(recents == ["B"])
    }

    @Test func recentsOrderedNewestFirstAndCappedAt30() throws {
        let channels = (0..<35).map { ch("Ch\($0)", "\($0)") }
        let (store, _) = try seeded(channels)
        let rows = try store.channels(in: .all, at: now)
        for (i, row) in rows.enumerated() {
            try store.recordWatched(
                streamURL: row.streamURL, name: row.name, at: Date(timeIntervalSince1970: 1_000 + Double(i)))
        }
        let recents = try store.channels(in: .recents, at: now)
        #expect(recents.count == 30)
        #expect(recents.first?.name == "Ch34")
        #expect(recents.last?.name == "Ch5")
    }

    @Test func recentsKeepTheNewestHundredRows() throws {
        let channels = (0..<101).map { ch("Ch\($0)", "\($0)") }
        let (store, _) = try seeded(channels)
        for (i, channel) in channels.enumerated() {
            try store.recordWatched(
                streamURL: channel.streamURL, name: channel.name, at: Date(timeIntervalSince1970: 1_000 + Double(i)))
        }
        let kept = try recentRows(store)
        #expect(kept.count == 100)
        #expect(!kept.contains(url("0")))  // the oldest went
        #expect(kept.first == url("100"))
    }

    /// A vanished channel's row is kept, so it can come back with a later import (spec 7.7: favourites and
    /// recents follow a channel by URL, then by name). It counts toward the cap like any other row, so the
    /// table stays bounded however many channels vanish.
    @Test func vanishedRecentsCountTowardTheCap() throws {
        let channels = (0..<101).map { ch("Ch\($0)", "\($0)") }
        let (store, id) = try seeded(channels)
        try store.recordWatched(streamURL: url("0"), name: "Ch0", at: Date(timeIntervalSince1970: 1_000))
        try store.replaceChannels(sourceID: id, with: Array(channels.dropFirst()))  // Ch0 vanishes
        #expect(try recentRows(store) == [url("0")])
        for (i, channel) in channels.dropFirst().enumerated() {
            try store.recordWatched(
                streamURL: channel.streamURL, name: channel.name, at: Date(timeIntervalSince1970: 2_000 + Double(i)))
        }
        let kept = try recentRows(store)
        #expect(kept.count == 100)
        #expect(!kept.contains(url("0")))
    }

    @Test func recordWatchedTwiceKeepsOneRow() throws {
        let (store, _) = try seeded([ch("A", "a"), ch("B", "b")])
        let rows = try store.channels(in: .all, at: now)
        try store.recordWatched(streamURL: rows[0].streamURL, name: rows[0].name, at: Date(timeIntervalSince1970: 100))
        try store.recordWatched(streamURL: rows[1].streamURL, name: rows[1].name, at: Date(timeIntervalSince1970: 200))
        try store.recordWatched(streamURL: rows[0].streamURL, name: rows[0].name, at: Date(timeIntervalSince1970: 300))
        #expect(try store.channels(in: .recents, at: now).map(\.name) == ["A", "B"])
    }

    @Test func duplicateStreamURLsImport() throws {
        let (store, _) = try seeded([ch("A", "same"), ch("A HD", "same"), ch("B", "b")])
        let rows = try store.channels(in: .all, at: now)
        #expect(rows.count == 3)
        try store.setFavourite(true, streamURL: rows[0].streamURL, name: rows[0].name)
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

    @Test func storeSaysWhetherItIsInMemory() throws {
        #expect(try Store.inMemory().isInMemory)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tuner-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try !Store(path: dir.appendingPathComponent("tuner.sqlite").path).isInMemory)
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
            try store.setFavourite(true, streamURL: a.streamURL, name: a.name)
            store.setBufferMs(1500, forStreamURL: url("a"))
        }

        let reopened = try Store(path: path)
        #expect(try reopened.channels(in: .all, at: now).map(\.name) == ["A", "B"])
        #expect(try reopened.channels(in: .favourites, at: now).map(\.name) == ["A"])
        #expect(try reopened.sources().count == 1)
        #expect(reopened.bufferMs(forStreamURL: url("a")) == 1500)
    }

    /// A big write grows the write-ahead log; once it is checkpointed, the next write cuts the file back
    /// rather than leaving it at its high-water size for as long as the app runs. (macOS's SQLite does
    /// this by default: its `journal_size_limit` is 32 KB.)
    @Test func writeAheadLogShrinksAfterABigWrite() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tuner-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("tuner.sqlite").path
        func walBytes() -> Int {
            ((try? FileManager.default.attributesOfItem(atPath: path + "-wal"))?[.size] as? Int) ?? 0
        }
        let limit = 8 * 1_048_576
        let store = try Store(path: path)
        // About 10 MB of pages in one transaction (the key is stored in the table and its index).
        store.setBufferMs(1000, forStreamURL: String(repeating: "x", count: 5 * 1_048_576))
        #expect(walBytes() > limit)
        store.setBufferMs(2000, forStreamURL: url("a"))
        #expect(walBytes() <= limit)
        #expect(store.bufferMs(forStreamURL: url("a")) == 2000)
    }

    @Test func replaceWithEmptyListClearsChannels() throws {
        let (store, id) = try seeded([ch("A", "a")])
        try store.replaceChannels(sourceID: id, with: [])
        #expect(try store.channels(in: .all, at: now).isEmpty)
        #expect(try store.groups().isEmpty)
    }
}

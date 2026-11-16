import Foundation
import Testing
@testable import TunerCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let hour: TimeInterval = 3600

private func at(_ hours: Double) -> Date { now.addingTimeInterval(hours * hour) }

private func prog(
    _ channel: String, _ from: Double, _ to: Double, _ title: String,
    subTitle: String? = nil, desc: String? = nil
) -> ParsedProgramme {
    ParsedProgramme(
        channelID: channel, start: at(from), stop: at(to), title: title, subTitle: subTitle, desc: desc)
}

private func pc(_ name: String, _ path: String, tvgID: String? = nil) -> ParsedChannel {
    ParsedChannel(name: name, tvgID: tvgID, streamURL: "http://example.invalid/\(path)")
}

private func setUp(
    _ store: Store, playlist: [ParsedChannel], guide: [String], programmes: [ParsedProgramme]
) throws {
    let p = try store.addSource(kind: .playlist, location: "http://example.invalid/list")
    try store.replaceChannels(sourceID: p, with: playlist)
    let g = try store.addSource(kind: .guide, location: "http://example.invalid/guide")
    try store.replaceGuide(sourceID: g, now: now) { writer in
        for id in guide { try writer.add(ParsedGuideChannel(id: id, displayNames: [id])) }
        for programme in programmes { try writer.add(programme) }
    }
}

/// One playlist channel "Alpha" linked by tvg-id to guide channel "alpha".
private func single(_ programmes: [ParsedProgramme]) throws -> Store {
    let store = try Store.inMemory()
    try setUp(store, playlist: [pc("Alpha", "a", tvgID: "alpha")], guide: ["alpha"], programmes: programmes)
    return store
}

@Suite struct StoreSearchTests {
    @Test func ftsQuery() {
        #expect(FTSQuery.make(from: "tennessee") == "\"tennessee\"*")
        #expect(FTSQuery.make(from: "  texas a&m ") == "\"texas\"* \"a\"* \"m\"*")
        #expect(FTSQuery.make(from: "a\"b") == "\"a\"* \"b\"*")
        #expect(FTSQuery.make(from: "a:b") == "\"a\"* \"b\"*")
        #expect(FTSQuery.make(from: "\"") == nil)
        #expect(FTSQuery.make(from: "- * : ( )") == nil)
        #expect(FTSQuery.make(from: " ") == nil)
        #expect(FTSQuery.make(from: "🏈") == nil)
        #expect(FTSQuery.make(from: "fußball") == "\"fußball\"*")
    }

    @Test func findsLiveProgrammeByTitlePrefix() throws {
        let store = try single([prog("alpha", -1, 1, "Tennessee at Georgia")])
        let results = try store.search("tenn", at: now)
        #expect(results.onNow.map(\.programme.title) == ["Tennessee at Georgia"])
        #expect(results.onNow.first?.channel.name == "Alpha")
        #expect(results.later.isEmpty)
    }

    @Test func findsTitleContainingAmpersand() throws {
        let store = try single([prog("alpha", -1, 1, "Tennessee at Texas A&M")])
        #expect(try store.search("texas a&m", at: now).onNow.count == 1)
    }

    @Test func findsBySubtitleAndDescription() throws {
        let store = try single([
            prog("alpha", -1, 1, "Match", subTitle: "Quarterfinal"),
            prog("alpha", 2, 3, "Other", desc: "Rivalry renewed"),
        ])
        #expect(try store.search("quarter", at: now).onNow.map(\.programme.title) == ["Match"])
        #expect(try store.search("rivalry", at: now).later.map(\.programme.title) == ["Other"])
    }

    @Test func separatesNowFromLater() throws {
        let store = try single([
            prog("alpha", -1, 1, "Football Now"), prog("alpha", 1, 2, "Football Next"),
            prog("alpha", 30, 31, "Football Tomorrow"),
        ])
        let results = try store.search("football", at: now)
        #expect(results.onNow.map(\.programme.title) == ["Football Now"])
        #expect(results.later.map(\.programme.title) == ["Football Next", "Football Tomorrow"])
    }

    @Test func excludesFinishedAndFarFuture() throws {
        let store = try single([
            prog("alpha", -1, -1.0 / 60, "Football Finished"),
            prog("alpha", 8 * 24, 8 * 24 + 1, "Football Far"),
        ])
        let results = try store.search("football", at: now)
        #expect(results.onNow.isEmpty)
        #expect(results.later.isEmpty)
    }

    @Test func findsChannelsByName() throws {
        let store = try Store.inMemory()
        try setUp(store, playlist: [pc("ESPN", "1"), pc("ESPN2", "2"), pc("CNN", "3")], guide: [], programmes: [])
        #expect(try store.search("espn", at: now).channels.map(\.name) == ["ESPN", "ESPN2"])
    }

    @Test func channelsAreOrderedByHowWellTheirNamesMatch() throws {
        let store = try Store.inMemory()
        try setUp(store, playlist: [
            pc("CNBC", "1"), pc("NBCSN", "2"), pc("NBC Sports Regional Plus", "3"), pc("USA NBC 4", "4"),
            pc("NBC", "5"), pc("Weather", "6"),
        ], guide: [], programmes: [])
        // A whole word, the shortest name first; then the start of a word; then inside one.
        #expect(try store.search("nbc", at: now).channels.map(\.name)
            == ["NBC", "USA NBC 4", "NBC Sports Regional Plus", "NBCSN", "CNBC"])
        // Every term must be found, each in its own way.
        #expect(try store.search("nbc sp", at: now).channels.map(\.name) == ["NBC Sports Regional Plus"])
        #expect(try store.search("usa nb", at: now).channels.map(\.name) == ["USA NBC 4"])
    }

    @Test func amongChannelsMatchingAlikeFavouritesThenWatchedOnesComeFirst() throws {
        let store = try Store.inMemory()
        try setUp(store, playlist: [
            pc("NBC 1", "1"), pc("NBC 2", "2"), pc("NBC 3", "3"), pc("NBC", "4"), pc("NBCSN", "5"),
        ], guide: [], programmes: [])
        try store.recordWatched(streamURL: "http://example.invalid/2", name: "NBC 2", at: now)
        try store.setFavourite(true, streamURL: "http://example.invalid/3", name: "NBC 3")
        try store.setFavourite(true, streamURL: "http://example.invalid/5", name: "NBCSN")
        // A favourite that matches less well stays below those that match better.
        #expect(try store.search("nbc", at: now).channels.map(\.name) == ["NBC 3", "NBC 2", "NBC", "NBC 1", "NBCSN"])
    }

    @Test func theChannelsCutOffByTheLimitAreTheOnesMatchingLeastWell() throws {
        let store = try Store.inMemory()
        try setUp(
            store, playlist: (1...8).map { pc("NBC Sports Region \($0)", "r\($0)") } + [pc("NBC", "n")],
            guide: [], programmes: [])
        #expect(try store.search("nbc", at: now, limit: 3).channels.first?.name == "NBC")
    }

    @Test func aTermInsideAWordFindsChannelsButNotProgrammes() throws {
        let store = try single([prog("alpha", -1, 1, "Alphabet Soup")])
        #expect(try store.search("lph", at: now).channels.map(\.name) == ["Alpha"])
        #expect(try store.search("lph", at: now).onNow.isEmpty)
        // LIKE's own characters never reach it: like any symbol they only divide the terms.
        #expect(try store.search("%", at: now).channels.isEmpty)
        #expect(try store.search("a_x", at: now).channels.isEmpty)
    }

    @Test func programmesFoundByTitleComeBeforeThoseFoundByDescription() throws {
        let store = try Store.inMemory()
        try setUp(store, playlist: [pc("One", "1", tvgID: "one"), pc("Two", "2", tvgID: "two")], guide: ["one", "two"],
            programmes: [
                prog("one", -1, 1, "Talk Show", desc: "Tonight: the cup final reviewed"),
                prog("two", -1, 1, "Cup Final"),
                prog("one", 1, 2, "News", desc: "Cup final reaction"),
                prog("two", 3, 4, "Highlights", subTitle: "Cup final"),
            ])
        let results = try store.search("cup final", at: now)
        #expect(results.onNow.map(\.programme.title) == ["Cup Final", "Talk Show"])
        #expect(results.later.map(\.programme.title) == ["Highlights", "News"])
    }

    @Test func allTermsMustMatch() throws {
        let store = try single([prog("alpha", -1, 1, "College Football")])
        #expect(try store.search("college basketball", at: now).onNow.isEmpty)
        #expect(try store.search("college foot", at: now).onNow.count == 1)
    }

    @Test func oneHitPerPlaylistChannel() throws {
        let store = try Store.inMemory()
        try setUp(
            store,
            playlist: [pc("Alpha", "a", tvgID: "alpha"), pc("Alpha HD", "b", tvgID: "alpha")],
            guide: ["alpha"], programmes: [prog("alpha", -1, 1, "Football")])
        let hits = try store.search("football", at: now).onNow
        #expect(hits.count == 2)
        #expect(Set(hits.map(\.id)).count == 2)
        #expect(Set(hits.map(\.channel.name)) == ["Alpha", "Alpha HD"])
    }

    @Test func unlinkedGuideChannelYieldsNoHit() throws {
        let store = try Store.inMemory()
        try setUp(
            store, playlist: [pc("Alpha", "a", tvgID: "alpha")], guide: ["alpha", "orphan"],
            programmes: [prog("orphan", -1, 1, "Football")])
        let results = try store.search("football", at: now)
        #expect(results.onNow.isEmpty)
        #expect(results.later.isEmpty)
    }

    @Test func respectsLimit() throws {
        let store = try Store.inMemory()
        let names = (0..<10).map { "Chan\($0)" }
        try setUp(
            store, playlist: names.map { pc($0, $0, tvgID: $0) }, guide: names,
            programmes: names.flatMap { [prog($0, -1, 1, "Football"), prog($0, 1, 2, "Football Later")] })
        let results = try store.search("football", at: now, limit: 3)
        #expect(results.onNow.count == 3)
        #expect(results.later.count == 3)
        let chans = try store.search("chan", at: now, limit: 4)
        #expect(chans.channels.count == 4)
        #expect(try store.search("football", at: now, limit: 50).onNow.count == 10)
    }

    /// Every column of a hit's channel, the favourite flag included, is the one the channel list shows.
    @Test func hitsCarryTheWholeChannelRow() throws {
        let store = try Store.inMemory()
        let p = try store.addSource(kind: .playlist, location: "http://example.invalid/list")
        try store.replaceChannels(sourceID: p, with: [ParsedChannel(
            name: "Alpha", tvgID: "alpha", logoURL: "http://example.invalid/a.png", groupTitle: "Sports",
            streamURL: "http://example.invalid/a")])
        let g = try store.addSource(kind: .guide, location: "http://example.invalid/guide")
        try store.replaceGuide(sourceID: g, now: now) { writer in
            try writer.add(ParsedGuideChannel(id: "alpha", displayNames: ["alpha"]))
            try writer.add(prog("alpha", -1, 1, "Alpha Cup"))
            try writer.add(prog("alpha", 2, 3, "Alpha Cup Final"))
        }
        try store.setFavourite(true, streamURL: "http://example.invalid/a", name: "Alpha")
        let row = try #require(try store.channels(in: .all, at: now).first)
        #expect(row.isFavourite && row.logoURL != nil && row.groupTitle != nil && row.guideRef != nil)
        let results = try store.search("alpha", at: now)
        #expect(results.onNow.map(\.channel) == [row])
        #expect(results.later.map(\.channel) == [row])
        #expect(results.channels == [row])
        #expect(results.onNow.first?.programme == (try store.nowPlaying(at: now)[try #require(row.guideRef)]))
    }

    @Test func programmeEndingAtTheMomentIsNeitherOnNowNorLater() throws {
        let store = try single([prog("alpha", -1, 0, "Football")])
        let results = try store.search("football", at: now)
        #expect(results.onNow.isEmpty)
        #expect(results.later.isEmpty)
    }

    @Test func programmeStartingAtTheMomentIsOnNowNotLater() throws {
        let store = try single([prog("alpha", 0, 1, "Football")])
        let results = try store.search("football", at: now)
        #expect(results.onNow.map(\.programme.title) == ["Football"])
        #expect(results.later.isEmpty)
    }

    @Test func laterReachesExactlySevenDaysAhead() throws {
        let week = 7.0 * 24
        let store = try single([
            prog("alpha", week, week + 1, "Football Edge"),
            prog("alpha", week + 1.0 / 3600, week + 2, "Football Beyond"),
        ])
        #expect(try store.search("football", at: now).later.map(\.programme.title) == ["Football Edge"])
    }

    /// On now: by the channel's place in the playlist. Later: by start, then by that place.
    @Test func orderingAcrossChannels() throws {
        let store = try Store.inMemory()
        try setUp(
            store, playlist: [pc("Zulu", "z", tvgID: "z"), pc("Alpha", "a", tvgID: "a")], guide: ["z", "a"],
            programmes: [
                prog("a", -1, 1, "Football A"), prog("z", -0.5, 1, "Football Z"),
                prog("a", 2, 3, "Football A2"), prog("z", 3, 4, "Football Z2"), prog("z", 2, 3, "Football Z3"),
            ])
        let results = try store.search("football", at: now)
        #expect(results.onNow.map(\.programme.title) == ["Football Z", "Football A"])
        #expect(results.later.map(\.programme.title) == ["Football Z3", "Football A2", "Football Z2"])
    }

    @Test func syntaxCharactersNeverThrow() throws {
        let store = try single([prog("alpha", -1, 1, "Football")])
        for text in ["\"", "a\"b", "-", "*", "NEAR(", "a:b", "(", "x OR", "🏈"] {
            #expect(throws: Never.self) { try store.search(text, at: now) }
        }
    }

    @Test func searchAfterReimportSeesNewData() throws {
        let store = try single([prog("alpha", -1, 1, "Football")])
        #expect(try store.search("football", at: now).onNow.count == 1)
        #expect(try store.search("zebra", at: now).channels.isEmpty)
        let p = try #require(try store.sources().first { $0.kind == .playlist })
        try store.replaceChannels(sourceID: p.id, with: [pc("Zebra", "z", tvgID: "alpha")])
        let g = try #require(try store.sources().first { $0.kind == .guide })
        try store.replaceGuide(sourceID: g.id, now: now) { writer in
            try writer.add(ParsedGuideChannel(id: "alpha", displayNames: ["alpha"]))
            try writer.add(prog("alpha", -1, 1, "Hockey"))
        }
        #expect(try store.search("football", at: now).onNow.isEmpty)
        #expect(try store.search("hockey", at: now).onNow.count == 1)
        #expect(try store.search("zebra", at: now).channels.map(\.name) == ["Zebra"])
        #expect(try store.search("alpha", at: now).channels.isEmpty)
    }
}

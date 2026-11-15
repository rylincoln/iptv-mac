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

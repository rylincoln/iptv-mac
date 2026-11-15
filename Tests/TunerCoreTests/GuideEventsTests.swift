import Foundation
import Testing
@testable import TunerCore

private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

/// 10:00 UTC on a day in 2027.
private let now = utc.date(from: DateComponents(year: 2027, month: 1, day: 15, hour: 10))!
private let hour: TimeInterval = 3600

private func at(_ hours: Double) -> Date { now.addingTimeInterval(hours * hour) }

private func prog(_ channel: String, _ from: Double, _ to: Double, _ title: String, sport: Bool = false) -> ParsedProgramme {
    ParsedProgramme(
        channelID: channel, start: at(from), stop: at(to), title: title, desc: "About \(title)",
        categories: sport ? ["Sports"] : [])
}

private func pc(_ name: String, tvgID: String, group: String? = nil) -> ParsedChannel {
    ParsedChannel(name: name, tvgID: tvgID, groupTitle: group, streamURL: "http://example.invalid/\(name)")
}

private func store(playlist: [ParsedChannel], guide: [String], programmes: [ParsedProgramme]) throws -> Store {
    let store = try Store.inMemory()
    let p = try store.addSource(kind: .playlist, location: "http://example.invalid/list")
    try store.replaceChannels(sourceID: p, with: playlist)
    let g = try store.addSource(kind: .guide, location: "http://example.invalid/guide")
    try store.replaceGuide(sourceID: g, now: now) { writer in
        for id in guide { try writer.add(ParsedGuideChannel(id: id, displayNames: [id])) }
        for programme in programmes { try writer.add(programme) }
    }
    return store
}

private func titles(_ sections: [GuideSection], _ kind: GuideSection.Kind) -> [String] {
    sections.first { $0.kind == kind }?.events.map(\.programme.title) ?? []
}

@Suite struct GuideEventsTests {
    // MARK: The store read

    @Test func hitsAreProgrammesInTheWindowEarliestFirstWithoutDescriptions() throws {
        let store = try store(
            playlist: [pc("One", tvgID: "one")], guide: ["one"],
            programmes: [
                prog("one", -3, -1, "Ended"), prog("one", -1, 1, "On now"), prog("one", 1, 2, "Next"),
                prog("one", 30, 31, "Tomorrow"),
            ])
        let hits = try store.guideHits(.all, from: now, to: at(14))
        #expect(hits.map(\.programme.title) == ["On now", "Next"])
        #expect(hits.allSatisfy { $0.programme.desc == nil })
        #expect(hits.first?.channel.name == "One")
        let full = try store.programme(id: hits[0].programme.id)
        #expect(full?.desc == "About On now")
        #expect(try store.programme(id: 9_999) == nil)
    }

    @Test func aProgrammeOnAGuideChannelSeveralChannelsShareComesOncePerChannel() throws {
        let store = try store(
            playlist: [pc("One HD", tvgID: "one"), pc("One SD", tvgID: "one")], guide: ["one"],
            programmes: [prog("one", -1, 1, "Match")])
        #expect(try store.guideHits(.all, from: now, to: at(14)).map(\.channel.name) == ["One HD", "One SD"])
    }

    @Test func theSportsFilterTakesSportProgrammesAndEverythingOnSportsChannels() throws {
        let store = try store(
            playlist: [pc("News", tvgID: "news"), pc("Arena", tvgID: "arena", group: "US Sports")],
            guide: ["news", "arena"],
            programmes: [
                prog("news", -1, 1, "Bulletin"), prog("news", 1, 2, "Cup Final", sport: true),
                prog("arena", -1, 1, "Talk Show"),
            ])
        #expect(Set(try store.guideHits(.sports, from: now, to: at(14)).map(\.programme.title)) == ["Cup Final", "Talk Show"])
    }

    @Test func theFavouritesFilterTakesOnlyFavouriteChannels() throws {
        let store = try store(
            playlist: [pc("One", tvgID: "one"), pc("Two", tvgID: "two")], guide: ["one", "two"],
            programmes: [prog("one", -1, 1, "A"), prog("two", -1, 1, "B")])
        try store.setFavourite(true, streamURL: "http://example.invalid/Two", name: "Two")
        #expect(try store.guideHits(.favourites, from: now, to: at(14)).map(\.programme.title) == ["B"])
    }

    @Test func theLimitIsApplied() throws {
        let store = try store(
            playlist: [pc("One", tvgID: "one")], guide: ["one"],
            programmes: (0..<10).map { prog("one", Double($0), Double($0) + 1, "P\($0)") })
        #expect(try store.guideHits(.all, from: now, to: at(14), limit: 3).count == 3)
    }

    // MARK: The window

    @Test func todaysWindowStartsNowAndAnotherDaysIsTheWholeDay() {
        let today = GuideEvents.window(for: now, now: now, calendar: utc)
        #expect(today?.from == now)
        #expect(today?.to == at(14))
        let tomorrow = GuideEvents.window(for: at(24), now: now, calendar: utc)
        #expect(tomorrow?.from == at(14))
        #expect(tomorrow?.to == at(38))
    }

    // MARK: Sections

    private func hit(_ id: Int64, _ channel: Int64, _ from: Double, _ to: Double, _ title: String) -> ProgrammeHit {
        ProgrammeHit(
            programme: ProgrammeRow(
                id: id, guideRef: channel, start: at(from), stop: at(to), title: title, subTitle: nil, desc: nil,
                isSport: false),
            channel: ChannelRow(
                id: channel, name: "Channel \(channel)", logoURL: nil, groupTitle: nil,
                streamURL: "http://example.invalid/\(channel)", guideRef: channel, isFavourite: false))
    }

    @Test func todayIsListedUnderOnNowStartingSoonAndThePartsOfTheDay() {
        let hits = [
            hit(1, 1, -1, 1, "Live"), hit(2, 1, 0.5, 1.5, "Soon"), hit(3, 1, 1.5, 2, "Late morning"),
            hit(4, 1, 3, 4, "Afternoon"), hit(5, 1, 9, 10, "Evening"),
        ]
        let sections = GuideEvents.sections(hits, day: now, now: now, calendar: utc)
        #expect(sections.map(\.kind) == [.onNow, .startingSoon, .morning, .afternoon, .evening])
        #expect(titles(sections, .onNow) == ["Live"])
        #expect(titles(sections, .startingSoon) == ["Soon"])
        #expect(titles(sections, .morning) == ["Late morning"])
        #expect(titles(sections, .afternoon) == ["Afternoon"])
        #expect(titles(sections, .evening) == ["Evening"])
    }

    @Test func headingsWithNothingUnderThemAreLeftOut() {
        let sections = GuideEvents.sections([hit(1, 1, 9, 10, "Evening")], day: now, now: now, calendar: utc)
        #expect(sections.map(\.kind) == [.evening])
    }

    @Test func theSameEventOnSeveralChannelsIsOneRowWithItsChannelsInOrder() {
        let hits = [hit(1, 1, -1, 1, "Match"), hit(2, 2, -1, 1, "Match"), hit(3, 3, -1, 1, "Other"), hit(4, 4, -1, 1, "Match")]
        let events = GuideEvents.sections(hits, day: now, now: now, calendar: utc)[0].events
        #expect(events.map(\.programme.title) == ["Match", "Other"])
        #expect(events[0].channels.map(\.id) == [1, 2, 4])
        #expect(events[0].id == "1-1")
    }

    @Test func theSameTitleAtAnotherTimeIsAnotherEvent() {
        let hits = [hit(1, 1, -1, 1, "Match"), hit(2, 2, -1, 2, "Match"), hit(3, 1, 3, 4, "Match")]
        let sections = GuideEvents.sections(hits, day: now, now: now, calendar: utc)
        #expect(sections.flatMap(\.events).count == 3)
    }

    @Test func anotherDayHasNoOnNowAndLeavesOutWhatBeganTheDayBefore() {
        // Tomorrow runs from 14 to 38 hours on.
        let hits = [hit(1, 1, 13, 15, "Carried over"), hit(2, 1, 16, 17, "Morning"), hit(3, 1, 30, 31, "Afternoon")]
        let sections = GuideEvents.sections(hits, day: at(24), now: now, calendar: utc)
        #expect(sections.map(\.kind) == [.morning, .afternoon])
        #expect(titles(sections, .morning) == ["Morning"])
    }

    @Test func aProgrammeThatHasEndedIsNotOnNow() {
        let sections = GuideEvents.sections([hit(1, 1, -2, -1, "Ended")], day: now, now: now, calendar: utc)
        #expect(sections.isEmpty)
    }

    // MARK: The grid

    @Test func byChannelTheHitsComeEachChannelInTurnAndMakeItsRow() throws {
        let store = try store(
            playlist: [pc("One", tvgID: "one"), pc("Two", tvgID: "two"), pc("Silent", tvgID: "none")],
            guide: ["one", "two"],
            programmes: [
                prog("two", -1, 1, "B1"), prog("one", 1, 2, "A2"), prog("one", -1, 1, "A1"), prog("two", 1, 4, "B2"),
                prog("one", 5, 6, "Too late"),
            ])
        let hits = try store.guideHits(.all, from: now, to: at(3), byChannel: true)
        #expect(hits.map(\.programme.title) == ["A1", "A2", "B1", "B2"])
        let rows = GuideGrid.rows(hits)
        #expect(rows.map(\.channel.name) == ["One", "Two"])  // a channel with nothing listed has no row
        #expect(rows[1].programmes.map(\.title) == ["B1", "B2"])
    }

    @Test func theGridStartsOnTheHalfHourNowIsInAndMovesByItsStep() {
        #expect(GuideGrid.start(now: now.addingTimeInterval(44 * 60)) == now.addingTimeInterval(30 * 60))
        #expect(GuideGrid.start(now: now) == now)
        #expect(GuideGrid.start(now: now.addingTimeInterval(60), steps: 2) == at(4))
    }

    @Test func aProgrammeSpansItsShareOfTheGridCutOffAtTheEdges() {
        let inside = GuideGrid.span(start: at(1.5), stop: at(2.25), gridStart: now)
        #expect(inside?.from == 0.5)
        #expect(inside?.to == 0.75)
        let over = GuideGrid.span(start: at(-1), stop: at(5), gridStart: now)
        #expect(over?.from == 0)
        #expect(over?.to == 1)
        #expect(GuideGrid.span(start: at(-2), stop: now, gridStart: now) == nil)
        #expect(GuideGrid.span(start: at(3), stop: at(4), gridStart: now) == nil)
    }
}

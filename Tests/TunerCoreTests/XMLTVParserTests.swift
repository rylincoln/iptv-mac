import Foundation
import Testing
@testable import TunerCore

private struct Collected {
    var channels: [ParsedGuideChannel] = []
    var programmes: [ParsedProgramme] = []
    var summary = XMLTVSummary(channels: 0, programmes: 0, skipped: 0)
}

private func writeTemp(_ xml: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("xmltv-\(UUID().uuidString).xml")
    try Data(xml.utf8).write(to: url)
    return url
}

private func parseXML(_ xml: String) throws -> Collected {
    let url = try writeTemp(xml)
    defer { try? FileManager.default.removeItem(at: url) }
    var out = Collected()
    out.summary = try XMLTVParser.parse(
        fileAt: url,
        onChannel: { out.channels.append($0) },
        onProgramme: { out.programmes.append($0) })
    return out
}

@Test func timeUTC()            { #expect(XMLTVTime.parse("20261114170000 +0000") == Date(timeIntervalSince1970: 1_794_675_600)) }
@Test func timeNegativeOffset() { #expect(XMLTVTime.parse("20261114120000 -0500") == Date(timeIntervalSince1970: 1_794_675_600)) }
@Test func timeNoOffsetIsUTC()  { #expect(XMLTVTime.parse("20261114170000") == Date(timeIntervalSince1970: 1_794_675_600)) }
@Test func timeGarbageIsNil()   { #expect(XMLTVTime.parse("tomorrow") == nil); #expect(XMLTVTime.parse("") == nil) }

@Test func timeRejectsDaysTheMonthDoesNotHave() {
    #expect(XMLTVTime.parse("20260231120000 +0000") == nil)
    #expect(XMLTVTime.parse("20260230120000 +0000") == nil)
    #expect(XMLTVTime.parse("20260229120000 +0000") == nil)  // 2026 is not a leap year
    #expect(XMLTVTime.parse("21000229120000 +0000") == nil)  // nor is 2100
    #expect(XMLTVTime.parse("20260431120000 +0000") == nil)
    #expect(XMLTVTime.parse("20261131120000 +0000") == nil)
    #expect(XMLTVTime.parse("20260100120000 +0000") == nil)
    #expect(XMLTVTime.parse("20240229120000 +0000") == Date(timeIntervalSince1970: 1_709_208_000))
    #expect(XMLTVTime.parse("20000229000000 +0000") == Date(timeIntervalSince1970: 951_782_400))
    #expect(XMLTVTime.parse("20261231235959 +0000") != nil)
    #expect(XMLTVTime.parse("20260131235959 +0000") != nil)
}

@Test func timeWithHalfHourOffset() {
    // 17:00 in India is 11:30 UTC.
    #expect(XMLTVTime.parse("20261114170000 +0530") == Date(timeIntervalSince1970: 1_794_655_800))
}

@Test func programmeOnAnImpossibleDateIsSkippedAndCounted() throws {
    let r = try parseXML("""
    <tv>
    <programme start="20260231170000 +0000" stop="20260231180000 +0000" channel="a"><title>Never</title></programme>
    <programme start="20261114170000 +0000" stop="20261114180000 +0000" channel="a"><title>Real</title></programme>
    </tv>
    """)
    #expect(r.programmes.map(\.title) == ["Real"])
    #expect(r.summary.skipped == 1)
}

@Test func parsesChannelsAndProgrammes() throws {
    let r = try parseXML("""
    <?xml version="1.0" encoding="UTF-8"?>
    <tv>
      <channel id="espn.us">
        <display-name>ESPN</display-name>
        <icon src="https://example.invalid/espn.png"/>
      </channel>
      <channel id="news.us">
        <display-name>News 5</display-name>
        <display-name>KNEWS</display-name>
      </channel>
      <programme start="20261114170000 +0000" stop="20261114190000 +0000" channel="espn.us">
        <title lang="en">Texas A&amp;M at LSU</title>
        <sub-title>Week 11</sub-title>
        <desc>College football.</desc>
        <category>Sports</category>
        <category>Football</category>
      </programme>
      <programme start="20261114120000 -0500" stop="20261114123000 -0500" channel="news.us">
        <title>Evening News</title>
      </programme>
    </tv>
    """)
    #expect(r.summary == XMLTVSummary(channels: 2, programmes: 2, skipped: 0))
    #expect(r.channels == [
        ParsedGuideChannel(id: "espn.us", displayNames: ["ESPN"], iconURL: "https://example.invalid/espn.png"),
        ParsedGuideChannel(id: "news.us", displayNames: ["News 5", "KNEWS"], iconURL: nil),
    ])
    #expect(r.programmes == [
        ParsedProgramme(channelID: "espn.us",
                        start: Date(timeIntervalSince1970: 1_794_675_600),
                        stop: Date(timeIntervalSince1970: 1_794_675_600 + 7200),
                        title: "Texas A&M at LSU", subTitle: "Week 11", desc: "College football.",
                        categories: ["Sports", "Football"]),
        ParsedProgramme(channelID: "news.us",
                        start: Date(timeIntervalSince1970: 1_794_675_600),
                        stop: Date(timeIntervalSince1970: 1_794_675_600 + 1800),
                        title: "Evening News", subTitle: nil, desc: nil, categories: []),
    ])
}

@Test func programmeMissingStopIsSkipped() throws {
    let r = try parseXML("""
    <tv><programme start="20261114170000 +0000" channel="a"><title>X</title></programme></tv>
    """)
    #expect(r.programmes.isEmpty)
    #expect(r.summary == XMLTVSummary(channels: 0, programmes: 0, skipped: 1))
}

@Test func programmeStopNotAfterStartIsSkipped() throws {
    let r = try parseXML("""
    <tv>
    <programme start="20261114170000 +0000" stop="20261114170000 +0000" channel="a"><title>Same</title></programme>
    <programme start="20261114170000 +0000" stop="20261114160000 +0000" channel="a"><title>Before</title></programme>
    </tv>
    """)
    #expect(r.programmes.isEmpty)
    #expect(r.summary.skipped == 2)
}

@Test func programmeWithoutTitleIsSkipped() throws {
    let r = try parseXML("""
    <tv><programme start="20261114170000 +0000" stop="20261114180000 +0000" channel="a"><desc>No title</desc></programme></tv>
    """)
    #expect(r.programmes.isEmpty)
    #expect(r.summary.skipped == 1)
}

@Test func programmeForUnknownChannelIsStillDelivered() throws {
    let r = try parseXML("""
    <tv><channel id="a"><display-name>A</display-name></channel>
    <programme start="20261114170000 +0000" stop="20261114180000 +0000" channel="zzz"><title>Orphan</title></programme></tv>
    """)
    #expect(r.programmes.count == 1)
    #expect(r.programmes[0].channelID == "zzz")
    #expect(r.summary == XMLTVSummary(channels: 1, programmes: 1, skipped: 0))
}

@Test func channelWithoutIDIsSkippedAndCounted() throws {
    let r = try parseXML("""
    <tv>
    <channel><display-name>Nameless</display-name></channel>
    <channel id=""><display-name>Empty</display-name></channel>
    <channel id="a"><display-name>A</display-name></channel>
    </tv>
    """)
    #expect(r.channels.map(\.id) == ["a"])
    #expect(r.summary == XMLTVSummary(channels: 1, programmes: 0, skipped: 2))
}

@Test func cdataTitleIsRead() throws {
    let r = try parseXML("""
    <tv><programme start="20261114170000 +0000" stop="20261114180000 +0000" channel="a">\
    <title><![CDATA[Tom & Jerry <Live>]]></title></programme></tv>
    """)
    #expect(r.programmes.map(\.title) == ["Tom & Jerry <Live>"])
}

@Test func truncatedFileDeliversWhatWasRead() throws {
    let r = try parseXML("""
    <tv>
    <programme start="20261114170000 +0000" stop="20261114180000 +0000" channel="a"><title>Good</title></programme>
    <programme start="20261114180000 +0000" stop="20261114190000 +0000" channel="a"><title>Cut of
    """)
    #expect(r.programmes.count == 1)
    #expect(r.programmes[0].title == "Good")
    #expect(r.summary.programmes == 1)
    #expect(!r.summary.complete)
}

@Test func emptyTvElement() throws {
    let r = try parseXML("<tv></tv>")
    #expect(r.summary == XMLTVSummary(channels: 0, programmes: 0, skipped: 0))
    #expect(r.summary.complete)
}

private struct Refused: Error, Equatable {}

/// A callback that throws ends the parse with its error, and no callback runs after it.
@Test func callbackErrorStopsTheParseAndPropagates() throws {
    let url = try writeTemp("""
    <tv>
    <channel id="a"><display-name>A</display-name></channel>
    <programme start="20261114170000 +0000" stop="20261114180000 +0000" channel="a"><title>One</title></programme>
    <programme start="20261114180000 +0000" stop="20261114190000 +0000" channel="a"><title>Two</title></programme>
    <channel id="b"><display-name>B</display-name></channel>
    <programme start="20261114190000 +0000" stop="20261114200000 +0000" channel="a"><title>Three</title></programme>
    </tv>
    """)
    defer { try? FileManager.default.removeItem(at: url) }
    var programmeCalls = 0
    var channelCalls = 0
    #expect(throws: Refused()) {
        try XMLTVParser.parse(
            fileAt: url,
            onChannel: { _ in channelCalls += 1 },
            onProgramme: { _ in programmeCalls += 1; throw Refused() })
    }
    #expect(programmeCalls == 1)
    #expect(channelCalls == 1)
}

/// `XMLParser` stops delivering once aborted; the delegate does not rely on that.
@Test func noCallbackRunsAfterOneHasFailed() {
    var calls = 0
    let delegate = XMLTVParser.Delegate(onChannel: { _ in }, onProgramme: { _ in calls += 1; throw Refused() })
    let parser = XMLParser(data: Data())
    func programme(_ title: String) {
        delegate.parser(parser, didStartElement: "programme", namespaceURI: nil, qualifiedName: nil, attributes: [
            "start": "20261114170000 +0000", "stop": "20261114180000 +0000", "channel": "a",
        ])
        delegate.parser(parser, didStartElement: "title", namespaceURI: nil, qualifiedName: nil, attributes: [:])
        delegate.parser(parser, foundCharacters: title)
        delegate.parser(parser, didEndElement: "title", namespaceURI: nil, qualifiedName: nil)
        delegate.parser(parser, didEndElement: "programme", namespaceURI: nil, qualifiedName: nil)
    }
    programme("One")
    programme("Two")  // as if one more element arrived after the abort
    #expect(calls == 1)
    #expect(delegate.callbackError is Refused)
}

@Test func missingFileThrows() {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).xml")
    #expect(throws: (any Error).self) {
        try XMLTVParser.parse(fileAt: url, onChannel: { _ in }, onProgramme: { _ in })
    }
}

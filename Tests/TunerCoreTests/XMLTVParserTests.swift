import Foundation
import Testing
@testable import TunerCore

private struct Collected {
    var channels: [ParsedGuideChannel] = []
    var programmes: [ParsedProgramme] = []
    var summary = XMLTVSummary(channels: 0, programmes: 0, skipped: 0)
}

private func parseXML(_ xml: String) throws -> Collected {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("xmltv-\(UUID().uuidString).xml")
    try Data(xml.utf8).write(to: url)
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

@Test func missingFileThrows() {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).xml")
    #expect(throws: (any Error).self) {
        try XMLTVParser.parse(fileAt: url, onChannel: { _ in }, onProgramme: { _ in })
    }
}

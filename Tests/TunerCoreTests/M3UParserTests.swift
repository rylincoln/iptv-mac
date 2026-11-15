import Testing
@testable import TunerCore

@Test func parsesStandardEntry() {
    let r = M3UParser.parse("""
    #EXTM3U
    #EXTINF:-1 tvg-id="espn.us" tvg-name="US: ESPN" tvg-logo="https://example.invalid/espn.png" group-title="US Sports",US: ESPN
    https://example.invalid/a/b/c
    """)
    #expect(r.skippedCount == 0)
    #expect(r.channels == [ParsedChannel(name: "US: ESPN", tvgID: "espn.us", tvgName: "US: ESPN",
        logoURL: "https://example.invalid/espn.png", groupTitle: "US Sports",
        streamURL: "https://example.invalid/a/b/c", extraAttributes: [:])])
}

@Test func emptyTvgIDBecomesNil() {
    let r = M3UParser.parse("""
    #EXTM3U
    #EXTINF:-1 tvg-id="" tvg-name="One",One
    https://example.invalid/1
    """)
    #expect(r.channels.count == 1)
    #expect(r.channels[0].tvgID == nil)
    #expect(r.channels[0].tvgName == "One")
}

@Test func commaInsideQuotedAttribute() {
    let r = M3UParser.parse("""
    #EXTM3U
    #EXTINF:-1 tvg-name="News, Weather" ,Local 5
    https://example.invalid/local5
    """)
    #expect(r.channels.count == 1)
    #expect(r.channels[0].name == "Local 5")
    #expect(r.channels[0].tvgName == "News, Weather")
}

@Test func unknownAttributesAreKept() {
    let r = M3UParser.parse("""
    #EXTM3U
    #EXTINF:-1 catchup="default" tvg-chno="12" group-title="G",Chan
    https://example.invalid/x
    """)
    #expect(r.channels.count == 1)
    #expect(r.channels[0].extraAttributes == ["catchup": "default", "tvg-chno": "12"])
    #expect(r.channels[0].groupTitle == "G")
}

@Test func extgrpSuppliesGroupWhenAttributeMissing() {
    let r = M3UParser.parse("""
    #EXTM3U
    #EXTINF:-1,No Attr
    #EXTGRP:Movies
    https://example.invalid/m1
    #EXTINF:-1 group-title="Explicit",Has Attr
    #EXTGRP:Ignored
    https://example.invalid/m2
    #EXTINF:-1,After
    https://example.invalid/m3
    """)
    #expect(r.channels.count == 3)
    #expect(r.channels[0].groupTitle == "Movies")
    #expect(r.channels[1].groupTitle == "Explicit")
    #expect(r.channels[2].groupTitle == nil)
}

@Test func nameFallsBackToTvgNameThenURLHost() {
    let r = M3UParser.parse("""
    #EXTM3U
    #EXTINF:-1 tvg-name="Fallback Name",
    https://example.invalid/a
    #EXTINF:-1,
    https://user:pw@example.invalid:8080/b
    """)
    #expect(r.channels.count == 2)
    #expect(r.channels[0].name == "Fallback Name")
    #expect(r.channels[1].name == "example.invalid")
}

@Test func crlfAndBOMAndBlankLines() {
    let r = M3UParser.parse("\u{FEFF}#EXTM3U\r\n\r\n#EXTINF:-1 tvg-id=\"a\",Alpha\r\nhttps://example.invalid/alpha\r\n\r\n")
    #expect(r.skippedCount == 0)
    #expect(r.channels.count == 1)
    #expect(r.channels[0].name == "Alpha")
    #expect(r.channels[0].tvgID == "a")
    #expect(r.channels[0].streamURL == "https://example.invalid/alpha")
}

@Test func extinfWithoutURLIsSkipped() {
    let r = M3UParser.parse("""
    #EXTM3U
    #EXTINF:-1,Orphan
    #EXTINF:-1,Real
    https://example.invalid/real
    """)
    #expect(r.channels.count == 1)
    #expect(r.channels[0].name == "Real")
    #expect(r.skippedCount == 1)
}

/// Named after the host alone: the path of a provider's URL often ends in the account's password.
@Test func bareURLWithoutExtinfIsImported() {
    let r = M3UParser.parse("""
    #EXTM3U
    https://example.invalid/live/someuser/secret
    """)
    #expect(r.skippedCount == 0)
    #expect(r.channels.count == 1)
    #expect(r.channels[0].name == "example.invalid")
    #expect(!r.channels[0].name.contains("secret"))
    #expect(r.channels[0].streamURL == "https://example.invalid/live/someuser/secret")
}

/// The group line belongs to the entry it follows; an entry that never got a URL takes it with it.
@Test func groupOfAnEntryWithoutURLDoesNotLeakOntoTheNext() {
    let r = M3UParser.parse("""
    #EXTM3U
    #EXTINF:-1,Orphan
    #EXTGRP:Movies
    #EXTINF:-1,Real
    https://example.invalid/real
    """)
    #expect(r.channels.count == 1)
    #expect(r.channels[0].name == "Real")
    #expect(r.channels[0].groupTitle == nil)
    #expect(r.skippedCount == 1)
}

@Test func ipv6HostFallbackNameHasNoPort() {
    let r = M3UParser.parse("""
    #EXTM3U
    #EXTINF:-1,
    http://user:pw@[2001:db8::1]:8080/live/a
    """)
    #expect(r.channels.count == 1)
    #expect(r.channels[0].name == "[2001:db8::1]")
}

/// A file address has no host, and its path may hold anything: the name is a fixed one.
@Test func fileURLWithoutTitleGetsAFixedName() {
    let r = M3UParser.parse("""
    #EXTM3U
    #EXTINF:-1,
    file:///Users/someone/secret/a.ts
    """)
    #expect(r.channels.count == 1)
    #expect(r.channels[0].name == "Unnamed channel")
}

@Test func ftpLineIsSkipped() {
    let r = M3UParser.parse("""
    #EXTM3U
    #EXTINF:-1,Files
    ftp://example.invalid/a.ts
    """)
    #expect(r.channels.isEmpty)
    #expect(r.skippedCount == 1)
}

@Test func bareNonURLLineIsSkipped() {
    let r = M3UParser.parse("""
    #EXTM3U
    just some text
    """)
    #expect(r.channels.isEmpty)
    #expect(r.skippedCount == 1)
}

@Test func uppercaseSchemeIsAccepted() {
    let r = M3UParser.parse("""
    #EXTM3U
    #EXTINF:-1,Loud
    HTTP://example.invalid/loud
    """)
    #expect(r.skippedCount == 0)
    #expect(r.channels.map(\.streamURL) == ["HTTP://example.invalid/loud"])
}

@Test func nonURLLineIsSkipped() {
    let r = M3UParser.parse("""
    #EXTM3U
    #EXTINF:-1,Bad
    not a url
    """)
    #expect(r.channels.isEmpty)
    #expect(r.skippedCount == 1)
}

@Test func duplicateURLsAreBothKept() {
    let r = M3UParser.parse("""
    #EXTM3U
    #EXTINF:-1,One
    https://example.invalid/same
    #EXTINF:-1,Two
    https://example.invalid/same
    """)
    #expect(r.channels.count == 2)
    #expect(r.channels.map(\.name) == ["One", "Two"])
}

@Test func missingHeaderStillParses() {
    let r = M3UParser.parse("""
    #EXTINF:-1,NoHeader
    rtsp://example.invalid/cam
    """)
    #expect(r.channels.count == 1)
    #expect(r.channels[0].streamURL == "rtsp://example.invalid/cam")
    #expect(r.skippedCount == 0)
}

@Test func emptyInput() {
    let r = M3UParser.parse("")
    #expect(r.channels.isEmpty)
    #expect(r.skippedCount == 0)
}

// The parse speed check is in PerformanceTests (`largePlaylistParsesQuickly`), which runs in a
// release build only.

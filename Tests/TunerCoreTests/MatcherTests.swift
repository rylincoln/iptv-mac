import Testing
@testable import TunerCore

private func cand(_ ref: Int64, _ id: String, _ names: [String] = [], programmes: Bool = true) -> MatchCandidate {
    MatchCandidate(ref: ref, id: id, displayNames: names, hasProgrammes: programmes)
}

private func query(_ id: Int64, name: String, tvgID: String? = nil, tvgName: String? = nil) -> MatchQuery {
    MatchQuery(channelID: id, tvgID: tvgID, name: name, tvgName: tvgName)
}

@Test func normalize() {
    #expect(NameNormalizer.normalize("US: ESPN") == "espn")
    #expect(NameNormalizer.normalize("USA :  Fox  Sports 1 HD") == "fox sports 1")
    #expect(NameNormalizer.normalize(": NBA TV") == "nba tv")
    #expect(NameNormalizer.normalize("(PLUTO France) Diane, femme flic") == "pluto france diane femme flic")
    #expect(NameNormalizer.normalize("HD") == "hd")
}

@Test func idBeatsName() {
    let guide = [cand(1, "espn.us", ["Other"]), cand(2, "x", ["ESPN"])]
    let r = Matcher.match([query(10, name: "ESPN", tvgID: "espn.us")], against: guide)
    #expect(r[10] == Match(guideRef: 1, kind: .id))
}

@Test func exactNameWhenIDEmpty() {
    let guide = [cand(1, "a", ["ESPN"])]
    let r = Matcher.match([query(10, name: "ESPN", tvgID: nil)], against: guide)
    #expect(r[10] == Match(guideRef: 1, kind: .name))
}

@Test func nameMatchesGuideIDUsedAsName() {
    let guide = [cand(1, "USA  TELEMUNDO")]
    let r = Matcher.match([query(10, name: "USA  TELEMUNDO")], against: guide)
    #expect(r[10] == Match(guideRef: 1, kind: .name))
}

@Test func normalizedNameFallback() {
    let guide = [cand(1, "g1", ["US: ESPN"])]
    let r = Matcher.match([query(10, name: "USA: Espn HD")], against: guide)
    #expect(r[10] == Match(guideRef: 1, kind: .normalizedName))
}

@Test func ambiguityPrefersCandidateWithProgrammes() {
    let guide = [cand(1, "a", ["ESPN"], programmes: false), cand(2, "b", ["ESPN"], programmes: true)]
    let r = Matcher.match([query(10, name: "ESPN")], against: guide)
    #expect(r[10] == Match(guideRef: 2, kind: .name))
}

@Test func ambiguityWithoutTiebreakIsNoMatch() {
    let guide = [cand(1, "a", ["ESPN"]), cand(2, "b", ["ESPN"])]
    #expect(Matcher.match([query(10, name: "ESPN")], against: guide)[10] == nil)
    // None has programmes and more than one candidate: no match either, and later rules are not tried.
    let guide2 = [cand(1, "a", ["ESPN"], programmes: false), cand(2, "b", ["ESPN"], programmes: false),
                  cand(3, "c", ["US: ESPN"])]
    #expect(Matcher.match([query(11, name: "ESPN")], against: guide2)[11] == nil)
}

@Test func unmatchedChannelIsAbsent() {
    let guide = [cand(1, "a", ["BBC One"])]
    let r = Matcher.match([query(10, name: "Nothing", tvgID: "zzz", tvgName: "Nope")], against: guide)
    #expect(r.isEmpty)
}

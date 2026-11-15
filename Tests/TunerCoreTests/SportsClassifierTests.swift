import Testing
@testable import TunerCore

@Test func sportsGroup() {
    #expect(SportsClassifier.isSportsGroup("US Sports"))
    #expect(!SportsClassifier.isSportsGroup("United States"))
    #expect(!SportsClassifier.isSportsGroup(nil))
}

@Test func sportsCategory() {
    #expect(SportsClassifier.isSportsCategory(["Sports talk"]))
    #expect(SportsClassifier.isSportsCategory(["Series", "Football"]))
    #expect(SportsClassifier.isSportsCategory(["Fußball"]))
    #expect(!SportsClassifier.isSportsCategory(["News"]))
    #expect(!SportsClassifier.isSportsCategory([]))
}

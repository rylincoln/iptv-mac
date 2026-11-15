import Foundation
import Testing
@testable import TunerCore

private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

@Suite struct StoreTimeTests {
    @Test func wholeSecondsTowardZeroByDefault() {
        #expect(Store.unixSeconds(date(1_800_000_000.9)) == 1_800_000_000)
        #expect(Store.unixSeconds(date(-1.9)) == -1)
        #expect(Store.unixSeconds(date(1.1), rounding: .up) == 2)
    }

    @Test func aTimeThatIsNotANumberIsZero() {
        #expect(Store.unixSeconds(date(.nan)) == 0)
        #expect(Store.unixSeconds(date(.nan), rounding: .up) == 0)
    }

    @Test func infiniteAndHugeTimesAreHeldAtTheLimit() {
        #expect(Store.unixSeconds(date(.infinity)) == Store.unixSecondsLimit)
        #expect(Store.unixSeconds(date(-.infinity)) == -Store.unixSecondsLimit)
        #expect(Store.unixSeconds(date(.greatestFiniteMagnitude), rounding: .up) == Store.unixSecondsLimit)
        // Room left for the store's own arithmetic on a stored time (a week ahead, a day back).
        #expect(Store.unixSecondsLimit < Int64.max - 7 * 86_400)
    }

    /// Every store call that takes a time, given one that is not finite, answers instead of trapping.
    @Test func nonFiniteTimesNeverTrap() throws {
        let store = try Store.inMemory()
        let playlist = try store.addSource(kind: .playlist, location: "http://example.invalid/list")
        try store.replaceChannels(sourceID: playlist, with: [
            ParsedChannel(name: "Alpha", tvgID: "alpha", groupTitle: "Sports", streamURL: "http://example.invalid/a"),
        ])
        let guide = try store.addSource(kind: .guide, location: "http://example.invalid/guide")
        for seconds in [Double.nan, .infinity, -.infinity] {
            let t = date(seconds)
            try store.replaceGuide(sourceID: guide, now: t) { writer in
                try writer.add(ParsedGuideChannel(id: "alpha", displayNames: ["Alpha"]))
                try writer.add(ParsedProgramme(channelID: "alpha", start: t, stop: t, title: "Football"))
                try writer.add(ParsedProgramme(channelID: "alpha", start: date(0), stop: t, title: "Football"))
            }
            _ = try store.search("football", at: t)
            _ = try store.nowPlaying(at: t)
            _ = try store.upcoming(guideRef: 1, after: t, limit: 3)
            _ = try store.channels(in: .sports, at: t)
            try store.recordWatched(streamURL: "http://example.invalid/a", name: "Alpha", at: t)
            try store.recordRefresh(
                sourceID: playlist, etag: nil, itemCount: 1, skippedCount: 0, error: nil, at: t, retryAt: t)
            _ = try store.sources()
        }
    }
}

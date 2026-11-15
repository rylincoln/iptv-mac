import Foundation
import Testing
@testable import TunerCore

@Suite struct ContinuousDateTests {
    /// Far from today, so a date read from the wall clock could never pass for one of these.
    private let wallStart = Date(timeIntervalSince1970: 1_000)
    private let start = ContinuousClock.now

    @Test func startsAtTheWallClocksTime() {
        #expect(ContinuousDate(wallStart: wallStart, start: start).date(at: start) == wallStart)
    }

    @Test func advancesWithTheContinuousClock() {
        let clock = ContinuousDate(wallStart: wallStart, start: start)
        #expect(clock.date(at: start + .seconds(90)) == wallStart.addingTimeInterval(90))
        #expect(clock.date(at: start + .seconds(-30)) == wallStart.addingTimeInterval(-30))
        let fraction = clock.date(at: start + .milliseconds(1_500)).timeIntervalSince(wallStart)
        #expect(abs(fraction - 1.5) < 1e-9)
        // A night asleep is counted, so a sleep still shows as a long gap between ticks.
        #expect(clock.date(at: start + .seconds(8 * 3600)) == wallStart.addingTimeInterval(8 * 3600))
    }

    /// Only the continuous clock moves it: the wall clock is read once, when it is made, so setting
    /// the wall clock later changes nothing.
    @Test func ignoresTheWallClockAfterItIsMade() {
        let clock = ContinuousDate(wallStart: wallStart, start: start)
        let later = start + .seconds(5)
        #expect(clock.date(at: later) == clock.date(at: later))
        #expect(clock.date(at: later) == wallStart.addingTimeInterval(5))
    }

    @Test func nowNeverGoesBackAndStartsNearTheWallClock() {
        let clock = ContinuousDate()
        #expect(abs(clock.now().timeIntervalSinceNow) < 5)
        var previous = clock.now()
        for _ in 0..<1_000 {
            let next = clock.now()
            #expect(next >= previous)
            previous = next
        }
    }
}

import Testing
@testable import TunerCore

private enum Read: Hashable, Sendable { case rows, search }

/// `#expect` cannot call a mutating method, so each call is made here and its answer checked.
private extension OptimisticWrites<Read> {
    mutating func ending() -> Set<Read>? { end() }
    mutating func asking(_ read: Read) -> Bool { mayRead(read) }
    mutating func checking(_ read: Read, since ticket: Ticket) -> Freshness { check(read, since: ticket) }
    mutating func using(_ read: Read, since ticket: Ticket, replacingShown: Bool) -> Use {
        use(read, since: ticket, replacingShown: replacingShown)
    }
}

private typealias Use = OptimisticWrites<Read>.Use

@Suite struct OptimisticWritesTests {
    @Test func withNoWriteEveryReadIsCurrent() {
        var writes = OptimisticWrites<Read>()
        let ticket = writes.ticket
        let freshness = writes.checking(.rows, since: ticket)
        #expect(freshness == .current)
        let may = writes.asking(.search)
        #expect(may)
        let ended = writes.ending()
        #expect(ended == nil)
    }

    @Test func aReadThatCanWaitIsHeldUntilTheLastWriteEnds() {
        var writes = OptimisticWrites<Read>()
        writes.begin()
        writes.begin()
        let mayRows = writes.asking(.rows)
        let maySearch = writes.asking(.search)
        #expect(!mayRows && !maySearch)
        let first = writes.ending()
        #expect(first == nil)  // one write is still unfinished
        let last = writes.ending()
        #expect(last == [.rows, .search])
        let mayAfter = writes.asking(.rows)
        #expect(mayAfter)
    }

    @Test func heldReadsAreGivenOnce() {
        var writes = OptimisticWrites<Read>()
        writes.begin()
        _ = writes.asking(.rows)
        let first = writes.ending()
        #expect(first == [.rows])
        writes.begin()
        let second = writes.ending()
        #expect(second == [])
    }

    /// It may have read the store before the write was made, and would show the change undone.
    @Test func aReadThatComesBackWhileAWriteIsUnfinishedIsHeld() {
        var writes = OptimisticWrites<Read>()
        let startedBefore = writes.ticket
        writes.begin()
        let before = writes.checking(.rows, since: startedBefore)
        #expect(before == .heldUntilWritten)
        let startedDuring = writes.ticket
        let during = writes.checking(.search, since: startedDuring)
        #expect(during == .heldUntilWritten)
        let ended = writes.ending()
        #expect(ended == [.rows, .search])
    }

    /// Every write it overlapped has ended, so nothing will read it again: it must be read again now.
    @Test func aReadThatAWriteEndedDuringIsReadAgainNow() {
        var writes = OptimisticWrites<Read>()
        let startedBefore = writes.ticket
        writes.begin()
        let first = writes.ending()
        #expect(first == [])
        let before = writes.checking(.rows, since: startedBefore)
        #expect(before == .readAgainNow)

        writes.begin()
        let startedDuring = writes.ticket
        let second = writes.ending()
        #expect(second == [])
        let during = writes.checking(.rows, since: startedDuring)
        #expect(during == .readAgainNow)
    }

    @Test func aReadStartedAfterTheWritesEndedIsCurrent() {
        var writes = OptimisticWrites<Read>()
        writes.begin()
        _ = writes.ending()
        let ticket = writes.ticket
        let freshness = writes.checking(.rows, since: ticket)
        #expect(freshness == .current)
    }

    /// A write that failed holds a read of what the store has instead, for when every write has ended.
    @Test func aHeldReadIsGivenWhenTheLastWriteEnds() {
        var writes = OptimisticWrites<Read>()
        writes.begin()
        writes.begin()
        writes.hold(.rows)
        let first = writes.ending()
        #expect(first == nil)
        let last = writes.ending()
        #expect(last == [.rows])
    }

    @Test func aReadNoWriteRanDuringIsShown() {
        var writes = OptimisticWrites<Read>()
        let ticket = writes.ticket
        let again = writes.using(.rows, since: ticket, replacingShown: true)
        #expect(again == Use(show: true, readAgain: false))
        let new = writes.using(.rows, since: ticket, replacingShown: false)
        #expect(new == Use(show: true, readAgain: false))
    }

    /// A read of what is shown, out when the change was made, would put the change back: it is not
    /// shown, and is made again once the write has ended.
    @Test func aReadOfWhatIsShownIsNotShownWhileAWriteIsUnfinished() {
        var writes = OptimisticWrites<Read>()
        let startedBefore = writes.ticket
        writes.begin()
        let use = writes.using(.rows, since: startedBefore, replacingShown: true)
        #expect(use == Use(show: false, readAgain: false))
        let ended = writes.ending()
        #expect(ended == [.rows])
    }

    /// Something new, a section just chosen or text just typed, has nothing else to show it: it is
    /// shown, and made again once the write has ended.
    @Test func aReadOfSomethingNewIsShownWhileAWriteIsUnfinished() {
        var writes = OptimisticWrites<Read>()
        let startedBefore = writes.ticket
        writes.begin()
        let use = writes.using(.search, since: startedBefore, replacingShown: false)
        #expect(use == Use(show: true, readAgain: false))
        let ended = writes.ending()
        #expect(ended == [.search])
    }

    @Test func aReadAWriteEndedDuringIsMadeAgainNowAndShownOnlyIfNew() {
        var writes = OptimisticWrites<Read>()
        let ticket = writes.ticket
        writes.begin()
        _ = writes.ending()
        let again = writes.using(.rows, since: ticket, replacingShown: true)
        #expect(again == Use(show: false, readAgain: true))
        let new = writes.using(.rows, since: ticket, replacingShown: false)
        #expect(new == Use(show: true, readAgain: true))
        writes.begin()
        let ended = writes.ending()
        #expect(ended == [])  // nothing was held: these are read again at once instead
    }

    @Test func endingMoreWritesThanBegunChangesNothing() {
        var writes = OptimisticWrites<Read>()
        let none = writes.ending()
        #expect(none == nil)
        #expect(writes.unfinished == 0)
        writes.begin()
        #expect(writes.unfinished == 1)
        let last = writes.ending()
        #expect(last == [])
        let extra = writes.ending()
        #expect(extra == nil)
        #expect(writes.unfinished == 0)
        let may = writes.asking(.rows)
        #expect(may)
    }
}

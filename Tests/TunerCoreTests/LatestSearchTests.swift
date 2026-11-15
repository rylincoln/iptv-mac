import Testing
@testable import TunerCore

/// Reads that finish only when the test says so.
@MainActor private final class Reads {
    private(set) var started: [String] = []
    private var pending: [(text: String, finish: CheckedContinuation<String?, Never>)] = []

    func read(_ text: String) -> LatestSearch<String>.Read {
        { [self] in
            started.append(text)
            return await withCheckedContinuation { pending.append((text, $0)) }
        }
    }

    /// Finishes the oldest read still running; `failing` makes it a failed read.
    func finish(failing: Bool = false) async {
        let next = pending.removeFirst()
        next.finish.resume(returning: failing ? nil : "found \(next.text)")
        await settle()
    }
}

/// A pause that ends when the test says so, and then throws if the search was cancelled meanwhile.
@MainActor private final class Pause {
    private var waiters: [CheckedContinuation<Void, Never>] = []

    nonisolated func sleep(_: Duration) async throws {
        await withCheckedContinuation { waiter in
            Task { @MainActor in waiters.append(waiter) }
        }
        try Task.checkCancellation()
    }

    func end() async {
        let all = waiters
        waiters = []
        for waiter in all { waiter.resume() }
        await settle()
    }
}

/// Lets every task that can run, run.
@MainActor private func settle() async {
    for _ in 0..<100 { await Task.yield() }
}

@MainActor @Suite struct LatestSearchTests {
    private let reads = Reads()
    private let pause = Pause()
    private let search: LatestSearch<String>
    private let found = Box()

    @MainActor final class Box { var values: [String] = [] }

    init() {
        let pause = self.pause
        search = LatestSearch(sleep: { try await pause.sleep($0) })
    }

    private func start(_ text: String) async {
        search.search(text, after: .seconds(1), read: reads.read(text)) { [found] in found.values.append($0) }
        await settle()
    }

    private func refresh(_ text: String) async {
        search.refresh(text, read: reads.read(text)) { [found] in found.values.append($0) }
        await settle()
    }

    @Test func aSearchReadsAfterThePauseAndDeliversWhatItFound() async {
        await start("a")
        #expect(reads.started.isEmpty)
        #expect(search.isSearching)
        await pause.end()
        #expect(reads.started == ["a"])
        await reads.finish()
        #expect(found.values == ["found a"])
        #expect(!search.isSearching)
    }

    @Test func textChangedDuringThePauseStartsOver() async {
        await start("a")
        await start("ab")
        await pause.end()
        #expect(reads.started == ["ab"])
        await reads.finish()
        #expect(found.values == ["found ab"])
    }

    @Test func aReadRunningIsWaitedForAndItsResultsDropped() async {
        await start("a")
        await pause.end()
        await start("ab")
        await pause.end()
        #expect(reads.started == ["a"])  // never two at once
        await reads.finish()
        #expect(reads.started == ["a", "ab"])
        #expect(found.values.isEmpty)
        await reads.finish()
        #expect(found.values == ["found ab"])
    }

    @Test func aFailedReadDeliversNothingAndEndsTheSearch() async {
        await start("a")
        await pause.end()
        await reads.finish(failing: true)
        #expect(found.values.isEmpty)
        #expect(!search.isSearching)
    }

    @Test func cancelDropsASearchWaitingAndOneReading() async {
        await start("a")
        search.cancel()
        #expect(!search.isSearching)
        await pause.end()
        #expect(reads.started.isEmpty)

        await start("b")
        await pause.end()
        search.cancel()
        await reads.finish()
        #expect(found.values.isEmpty)
    }

    @Test func aRefreshReadsAtOnceForTheTextShown() async {
        await start("a")
        await pause.end()
        await reads.finish()
        await refresh("a")
        #expect(reads.started == ["a", "a"])
        #expect(!search.isSearching)
        await reads.finish()
        #expect(found.values == ["found a", "found a"])
    }

    @Test func aRefreshDoesNothingWhileASearchWaitsOrRuns() async {
        await start("a")
        await refresh("a")
        await pause.end()
        await refresh("a")
        #expect(reads.started == ["a"])
        await reads.finish()
        #expect(found.values == ["found a"])
    }

    @Test func aRefreshForOtherTextOrAfterCancelDoesNothing() async {
        await start("a")
        await pause.end()
        await reads.finish()
        await refresh("b")
        search.cancel()
        await refresh("a")
        #expect(reads.started == ["a"])
    }

    @Test func aSearchForNewTextCancelsARefresh() async {
        await start("a")
        await pause.end()
        await reads.finish()
        await refresh("a")
        await start("ab")
        await reads.finish()  // the refresh's read: dropped
        #expect(found.values == ["found a"])
        await pause.end()
        await reads.finish()
        #expect(found.values == ["found a", "found ab"])
    }

    @Test func theFoundCallbackMayAskForARefresh() async {
        search.search("a", after: .seconds(1), read: reads.read("a")) { [search, reads, found] value in
            found.values.append(value)
            search.refresh("a", read: reads.read("a")) { found.values.append($0 + " again") }
        }
        await settle()
        await pause.end()
        await reads.finish()
        #expect(reads.started == ["a", "a"])
        await reads.finish()
        #expect(found.values == ["found a", "found a again"])
    }
}

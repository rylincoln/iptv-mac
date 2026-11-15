import Synchronization
import Testing
@testable import TunerCore

/// Shut until opened; then everyone waiting, or arriving later, goes on.
private actor Latch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

private final class Counter: Sendable {
    private let count = Mutex(0)

    /// The count after this one.
    @discardableResult func increment() -> Int { count.withLock { $0 += 1; return $0 } }
    var value: Int { count.withLock { $0 } }
}

private struct Failure: Error, Equatable {}

/// Waits until `condition` holds, or until the test is cancelled by the suite's time limit.
private func waitUntil(_ condition: () -> Bool) async {
    while !condition(), !Task.isCancelled { try? await Task.sleep(for: .milliseconds(1)) }
}

/// Sleeps until cancelled, noting that it was.
private func sleepUntilCancelled(noting cancels: Counter) async throws -> Int {
    do {
        try await Task.sleep(for: .seconds(3600))
    } catch {
        cancels.increment()
        throw error
    }
    return 0
}

@Suite(.timeLimit(.minutes(1))) struct SharedWorkTests {
    @Test func callersAskingWhileItRunsShareOneRun() async throws {
        let shared = SharedWork<String, Int>()
        let runs = Counter()
        let release = Latch()
        let work: @Sendable () async throws -> Int = {
            runs.increment()
            await release.wait()
            return 7
        }
        let first = Task { try await shared.value(for: "a", work: work) }
        let second = Task { try await shared.value(for: "a", work: work) }
        await waitUntil { shared.waiterCount(for: "a") == 2 }
        await release.open()
        #expect(try await first.value == 7)
        #expect(try await second.value == 7)
        #expect(runs.value == 1)
        #expect(shared.inFlightCount == 0)
    }

    @Test func aCallerCancelledAloneLeavesAtOnceAndTheOthersStillGetTheValue() async throws {
        let shared = SharedWork<String, Int>()
        let runs = Counter()
        let cancels = Counter()
        let release = Latch()
        let work: @Sendable () async throws -> Int = {
            runs.increment()
            await release.wait()
            if Task.isCancelled { cancels.increment() }
            return 7
        }
        let first = Task { try await shared.value(for: "a", work: work) }
        let second = Task { try await shared.value(for: "a", work: work) }
        await waitUntil { shared.waiterCount(for: "a") == 2 }
        first.cancel()
        // Answered while the work is still held up.
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(shared.waiterCount(for: "a") == 1)
        await release.open()
        #expect(try await second.value == 7)
        #expect(runs.value == 1)
        #expect(cancels.value == 0)
    }

    @Test func theWorkIsCancelledOnceEveryCallerIsCancelled() async throws {
        let shared = SharedWork<String, Int>()
        let cancels = Counter()
        let work: @Sendable () async throws -> Int = { try await sleepUntilCancelled(noting: cancels) }
        let first = Task { try await shared.value(for: "a", work: work) }
        let second = Task { try await shared.value(for: "a", work: work) }
        await waitUntil { shared.waiterCount(for: "a") == 2 }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(cancels.value == 0)
        second.cancel()
        await #expect(throws: CancellationError.self) { try await second.value }
        await waitUntil { cancels.value == 1 }
        #expect(shared.inFlightCount == 0)
    }

    @Test func aCallAfterEveryCallerLeftStartsAgainRatherThanJoiningTheCancelledRun() async throws {
        let shared = SharedWork<String, Int>()
        let runs = Counter()
        let cancels = Counter()
        let work: @Sendable () async throws -> Int = {
            if runs.increment() == 1 { return try await sleepUntilCancelled(noting: cancels) }
            return 5
        }
        let first = Task { try await shared.value(for: "a", work: work) }
        await waitUntil { shared.waiterCount(for: "a") == 1 }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(try await shared.value(for: "a", work: work) == 5)
        #expect(runs.value == 2)
    }

    @Test func aKeyIsForgottenOnceItsWorkEnds() async throws {
        let shared = SharedWork<String, Int>()
        let runs = Counter()
        let work: @Sendable () async throws -> Int = { runs.increment() }
        #expect(try await shared.value(for: "a", work: work) == 1)
        #expect(shared.inFlightCount == 0)
        #expect(try await shared.value(for: "a", work: work) == 2)
        #expect(shared.inFlightCount == 0)
    }

    @Test func differentKeysRunApart() async throws {
        let shared = SharedWork<String, String>()
        let runs = Counter()
        let release = Latch()
        let a = Task {
            try await shared.value(for: "a") { runs.increment(); await release.wait(); return "A" }
        }
        let b = Task {
            try await shared.value(for: "b") { runs.increment(); await release.wait(); return "B" }
        }
        await waitUntil { shared.inFlightCount == 2 }
        await release.open()
        #expect(try await a.value == "A")
        #expect(try await b.value == "B")
        #expect(runs.value == 2)
    }

    @Test func anErrorReachesEveryCaller() async throws {
        let shared = SharedWork<String, Int>()
        let release = Latch()
        let work: @Sendable () async throws -> Int = {
            await release.wait()
            throw Failure()
        }
        let first = Task { try await shared.value(for: "a", work: work) }
        let second = Task { try await shared.value(for: "a", work: work) }
        await waitUntil { shared.waiterCount(for: "a") == 2 }
        await release.open()
        await #expect(throws: Failure.self) { try await first.value }
        await #expect(throws: Failure.self) { try await second.value }
        #expect(shared.inFlightCount == 0)
    }

    @Test func aCallerCancelledBeforeAskingStartsNothing() async throws {
        let shared = SharedWork<String, Int>()
        let runs = Counter()
        let go = Latch()
        let caller = Task {
            await go.wait()
            return try await shared.value(for: "a") { runs.increment() }
        }
        caller.cancel()
        await go.open()
        await #expect(throws: CancellationError.self) { try await caller.value }
        #expect(runs.value == 0)
        #expect(shared.inFlightCount == 0)
    }
}

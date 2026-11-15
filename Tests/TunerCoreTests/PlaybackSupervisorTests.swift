import Foundation
import Testing
@testable import TunerCore

private let urlA = "http://example.invalid/a"
private let urlB = "http://example.invalid/b"

// MARK: - Doubles

@MainActor final class TestClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

@MainActor final class FakePlayer: Player {
    struct PlayCall { var url: URL; var bufferMs: Int; var at: Date }
    let clock: TestClock
    var plays: [PlayCall] = []
    var stopCount = 0
    var volume = 100
    var state: PlayerState = .idle
    var stats: PlayerStats = .zero

    init(clock: TestClock) { self.clock = clock }

    func play(url: URL, bufferMs: Int) {
        // Shared recorder: every test in this file fails if a URL is replayed within one second.
        if let last = plays.last(where: { $0.url == url }), clock.now.timeIntervalSince(last.at) < 1 {
            Issue.record("play(url:) called twice for the same URL within one second")
        }
        plays.append(PlayCall(url: url, bufferMs: bufferMs, at: clock.now))
    }

    func stop() { stopCount += 1 }
}

final class FakeMemory: BufferMemory, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Int] = [:]
    init(_ initial: [String: Int] = [:]) { values = initial }
    func bufferMs(forStreamURL url: String) -> Int? { lock.withLock { values[url] } }
    func setBufferMs(_ ms: Int, forStreamURL url: String) { lock.withLock { values[url] = ms } }
}

@MainActor final class Rig {
    let clock = TestClock()
    let player: FakePlayer
    let memory: FakeMemory
    let supervisor: PlaybackSupervisor
    var log: [(status: PlaybackSupervisor.Status, at: Date)] = []

    init(policy: SupervisorPolicy = .default, remembered: Int? = nil) {
        player = FakePlayer(clock: clock)
        memory = FakeMemory(remembered.map { [urlA: $0] } ?? [:])
        let clock = clock
        supervisor = PlaybackSupervisor(player: player, memory: memory, now: { clock.now }, policy: policy)
        supervisor.onStatusChange = { [unowned self] status in log.append((status, self.clock.now)) }
    }

    var statuses: [PlaybackSupervisor.Status] { log.map(\.status) }
    var status: PlaybackSupervisor.Status { supervisor.status }

    func bump() {
        player.stats.positionMs += 1000
        player.stats.displayedPictures += 25
        player.stats.decodedAudioBlocks += 40
    }

    /// Advance the clock, optionally make the stream progress and set the player state, then tick.
    func tick(after dt: TimeInterval = 1, progress: Bool = false, state: PlayerState? = nil) {
        clock.advance(dt)
        if let state { player.state = state }
        if progress { bump() }
        supervisor.tick()
    }

    func run(_ seconds: Int, step: TimeInterval = 1, progress: Bool = false, state: PlayerState? = nil) {
        var elapsed = 0.0
        while elapsed < Double(seconds) {
            tick(after: step, progress: progress, state: state)
            elapsed += step
        }
    }

    /// play(streamURL:) then a first picture.
    func startPlaying(_ url: String = urlA) {
        supervisor.play(streamURL: url)
        tick(progress: true, state: .playing)
    }

    /// Stall a playing stream: freeze it for `stallAfter`.
    func freeze(seconds: Int = 4) { run(seconds, state: .playing) }

    /// From a stalled/failed state, let the retry fire and the stream come back.
    func recover() {
        tick()  // the retry delay (1 s for attempt 1) elapses
        tick(progress: true, state: .playing)
    }

    /// Never progress until the supervisor gives up.
    func driveToUnavailable() {
        supervisor.play(streamURL: urlA)
        player.state = .opening
        var guardTicks = 0
        while status != .unavailable && guardTicks < 1000 { tick(); guardTicks += 1 }
    }
}

@MainActor func minSpacingPerURL(_ plays: [FakePlayer.PlayCall]) -> TimeInterval {
    var minimum = TimeInterval.infinity
    var lastByURL: [URL: Date] = [:]
    for call in plays {
        if let last = lastByURL[call.url] { minimum = min(minimum, call.at.timeIntervalSince(last)) }
        lastByURL[call.url] = call.at
    }
    return minimum
}

// MARK: - Tests

@MainActor @Suite struct PlaybackSupervisorTests {
    @Test func startsWithFirstBufferStep() {
        let rig = Rig()
        rig.supervisor.play(streamURL: urlA)
        #expect(rig.player.plays.count == 1)
        #expect(rig.player.plays[0].bufferMs == 1000)
        #expect(rig.player.plays[0].url.absoluteString == urlA)
        #expect(rig.status == .starting)
        #expect(rig.supervisor.currentBufferMs == 1000)
        #expect(rig.supervisor.reconnectCount == 0)
    }

    @Test func usesRememberedBuffer() {
        let rig = Rig(remembered: 4000)
        rig.supervisor.play(streamURL: urlA)
        #expect(rig.player.plays[0].bufferMs == 4000)
        #expect(rig.supervisor.currentBufferMs == 4000)
    }

    @Test func becomesPlayingOnFirstProgress() {
        let rig = Rig()
        rig.supervisor.play(streamURL: urlA)
        rig.tick(state: .buffering)
        #expect(rig.status == .starting)
        // audio alone is progress: a stream often joins mid-GOP with no picture yet
        rig.player.stats.decodedAudioBlocks += 3
        rig.tick(state: .buffering)
        #expect(rig.status == .playing)
    }

    @Test func startTimeoutTriggersReconnectAfterOneSecond() {
        let rig = Rig()
        rig.supervisor.play(streamURL: urlA)
        rig.player.state = .opening
        rig.run(11)
        #expect(rig.status == .starting)
        rig.tick()  // 12 s with no progress
        #expect(rig.status == .reconnecting(attempt: 1))
        #expect(rig.player.stopCount >= 1)
        #expect(rig.player.plays.count == 1)
        rig.tick(after: 0.9)
        #expect(rig.player.plays.count == 1)
        rig.tick(after: 0.1)
        #expect(rig.player.plays.count == 2)
        #expect(rig.player.plays[1].bufferMs == 1000)
        #expect(rig.supervisor.reconnectCount == 1)
    }

    @Test func errorBeforeProgressIsAFailedStartAndKeepsBuffer() {
        let rig = Rig(remembered: 2000)
        rig.supervisor.play(streamURL: urlA)
        rig.tick(state: .error)
        #expect(rig.status == .reconnecting(attempt: 1))
        #expect(rig.memory.bufferMs(forStreamURL: urlA) == 2000)
        #expect(rig.supervisor.currentBufferMs == 2000)
        rig.tick(state: .opening)
        #expect(rig.player.plays.count == 2)
        #expect(rig.player.plays[1].bufferMs == 2000)
    }

    @Test func failedStartTimeoutDoesNotTouchStoredBuffer() {
        let rig = Rig()
        rig.supervisor.play(streamURL: urlA)
        rig.run(12, state: .opening)
        #expect(rig.status == .reconnecting(attempt: 1))
        #expect(rig.memory.bufferMs(forStreamURL: urlA) == nil)
    }

    @Test func stallReconnectsAndStepsBufferUp() {
        let rig = Rig()
        rig.startPlaying()
        #expect(rig.status == .playing)
        rig.run(3, state: .playing)
        #expect(rig.status == .playing)
        rig.tick(state: .playing)  // 4 s frozen
        #expect(rig.status == .reconnecting(attempt: 1))
        #expect(rig.memory.bufferMs(forStreamURL: urlA) == 2000)
        #expect(rig.supervisor.currentBufferMs == 2000)
        #expect(rig.player.stopCount >= 1)
        rig.tick()
        #expect(rig.player.plays.count == 2)
        #expect(rig.player.plays[1].bufferMs == 2000)
    }

    @Test func endedWhilePlayingIsAStall() {
        let rig = Rig()
        rig.startPlaying()
        rig.tick(state: .ended)
        #expect(rig.status == .reconnecting(attempt: 1))
        #expect(rig.memory.bufferMs(forStreamURL: urlA) == 2000)
    }

    @Test func bufferSaturatesAtLastStep() {
        let rig = Rig(remembered: 4000)
        rig.startPlaying()
        rig.freeze()
        #expect(rig.memory.bufferMs(forStreamURL: urlA) == 8000)
        rig.recover()
        #expect(rig.player.plays[1].bufferMs == 8000)
        #expect(rig.status == .playing)
        rig.freeze()
        #expect(rig.status == .reconnecting(attempt: 2))
        #expect(rig.memory.bufferMs(forStreamURL: urlA) == 8000)
        #expect(rig.supervisor.currentBufferMs == 8000)
        rig.run(2)
        #expect(rig.player.plays.last?.bufferMs == 8000)
    }

    @Test func threeRebuffersInAMinuteIsAStutter() {
        let rig = Rig()
        rig.startPlaying()
        for round in 1...3 {
            rig.tick(progress: true, state: .buffering)
            if round < 3 {
                #expect(rig.status == .playing)
                rig.tick(progress: true, state: .playing)
            }
        }
        #expect(rig.status == .reconnecting(attempt: 1))
        #expect(rig.memory.bufferMs(forStreamURL: urlA) == 2000)
        #expect(rig.player.plays.count == 1)
        rig.tick()
        #expect(rig.player.plays.count == 2)
        #expect(rig.player.plays[1].bufferMs == 2000)
        rig.tick(progress: true, state: .playing)
        rig.run(10, progress: true, state: .playing)
        #expect(rig.player.plays.count == 2)  // restarted once
        #expect(rig.status == .playing)
    }

    @Test func rebuffersSpreadOverMoreThanAMinuteAreNotAStutter() {
        let rig = Rig()
        rig.startPlaying()
        for _ in 1...3 {
            rig.tick(progress: true, state: .buffering)
            rig.tick(progress: true, state: .playing)
            rig.run(30, progress: true, state: .playing)
        }
        #expect(rig.status == .playing)
        #expect(rig.player.plays.count == 1)
        #expect(rig.memory.bufferMs(forStreamURL: urlA) == nil)
    }

    @Test func retriesFollowTheDelaySchedule() {
        let rig = Rig()
        rig.driveToUnavailable()
        let failures = rig.log.filter {
            if case .reconnecting = $0.status { return true } else { return false }
        }
        #expect(failures.count == 5)
        let delays: [TimeInterval] = [1, 2, 5, 10, 20]
        // play #1 is the original; play #n+1 follows failure n by delays[n-1]
        for n in 1...5 {
            #expect(failures[n - 1].status == .reconnecting(attempt: n))
            let gap = rig.player.plays[n].at.timeIntervalSince(failures[n - 1].at)
            #expect(gap == delays[n - 1])
        }
    }

    @Test func givesUpAfterFiveAttemptsAndStopsConnecting() {
        let rig = Rig()
        rig.driveToUnavailable()
        #expect(rig.status == .unavailable)
        #expect(rig.player.plays.count == 6)
        let stops = rig.player.stopCount
        rig.run(120, state: .opening)
        #expect(rig.player.plays.count == 6)
        #expect(rig.status == .unavailable)
        #expect(rig.player.stopCount == stops)
        #expect(rig.supervisor.reconnectCount == 6)
    }

    @Test func retryFromUnavailableStartsOver() {
        let rig = Rig()
        rig.driveToUnavailable()
        rig.supervisor.retry()
        #expect(rig.status == .starting)
        #expect(rig.player.plays.count == 7)
        rig.run(12, state: .opening)
        #expect(rig.status == .reconnecting(attempt: 1))
    }

    @Test func retryIsIgnoredOutsideUnavailable() {
        let rig = Rig()
        rig.startPlaying()
        rig.supervisor.retry()
        #expect(rig.player.plays.count == 1)
        #expect(rig.status == .playing)
    }

    @Test func stablePlaybackResetsAttemptCount() {
        let rig = Rig()
        rig.startPlaying()
        rig.freeze()
        #expect(rig.status == .reconnecting(attempt: 1))
        rig.recover()
        #expect(rig.status == .playing)
        rig.run(60, progress: true, state: .playing)
        rig.freeze()
        #expect(rig.status == .reconnecting(attempt: 1))
    }

    @Test func recoveryWithoutStablePeriodKeepsCounting() {
        let rig = Rig()
        rig.startPlaying()
        rig.freeze()
        rig.recover()
        rig.run(20, progress: true, state: .playing)
        rig.freeze()
        #expect(rig.status == .reconnecting(attempt: 2))
    }

    @Test func longCleanPlaybackStepsBufferDownWithoutRestart() {
        let rig = Rig(remembered: 4000)
        rig.startPlaying()
        rig.run(1790, step: 5, progress: true, state: .playing)
        #expect(rig.memory.bufferMs(forStreamURL: urlA) == 4000)
        rig.run(20, step: 5, progress: true, state: .playing)
        #expect(rig.memory.bufferMs(forStreamURL: urlA) == 2000)
        #expect(rig.supervisor.currentBufferMs == 2000)
        #expect(rig.player.plays.count == 1)
        #expect(rig.status == .playing)
        rig.run(3600, step: 5, progress: true, state: .playing)
        #expect(rig.memory.bufferMs(forStreamURL: urlA) == 1000)  // saturates at the first step
        #expect(rig.player.plays.count == 1)
    }

    @Test func wakeGapIsNotAStall() {
        let rig = Rig()
        rig.startPlaying()
        rig.clock.advance(7200)
        rig.player.state = .playing
        rig.supervisor.tick()
        #expect(rig.status == .playing)
        #expect(rig.supervisor.reconnectCount == 0)
        #expect(rig.player.plays.count == 1)
        #expect(rig.memory.bufferMs(forStreamURL: urlA) == nil)
        rig.run(3, state: .playing)  // timers restarted at the wake tick
        #expect(rig.status == .playing)
        rig.tick(state: .playing)
        #expect(rig.status == .reconnecting(attempt: 1))  // a stream lost in sleep is still caught afterwards...
        #expect(rig.memory.bufferMs(forStreamURL: urlA) == nil)  // ...but is not billed to the buffer
    }

    /// Fails four times, recovers to .playing (not yet stable), returns the buffer in force.
    private func rigRecoveredAfterFourFailures() -> (Rig, Int) {
        let rig = Rig()
        rig.startPlaying()
        for delay in [1, 2, 5, 10] {
            rig.freeze()
            rig.run(delay, state: .playing)  // retry play fires on the last of these ticks
            rig.tick(progress: true, state: .playing)
        }
        #expect(rig.status == .playing)
        return (rig, rig.supervisor.currentBufferMs)
    }

    @Test func wakeWhilePlayingWithEndedStreamKeepsBufferAndBudget() {
        let (rig, before) = rigRecoveredAfterFourFailures()
        let saved = rig.memory.bufferMs(forStreamURL: urlA)
        let plays = rig.player.plays.count
        rig.clock.advance(7200)
        rig.player.state = .playing
        rig.supervisor.tick()
        #expect(rig.status == .playing)
        rig.tick(state: .ended)
        #expect(rig.status == .reconnecting(attempt: 1))
        #expect(rig.memory.bufferMs(forStreamURL: urlA) == saved)
        #expect(rig.supervisor.currentBufferMs == before)
        rig.tick()
        #expect(rig.player.plays.count == plays + 1)
        #expect(rig.player.plays.last?.bufferMs == before)
    }

    @Test func wakeWhilePlayingWithFrozenStreamKeepsBufferAndBudget() {
        let (rig, before) = rigRecoveredAfterFourFailures()
        let saved = rig.memory.bufferMs(forStreamURL: urlA)
        let plays = rig.player.plays.count
        rig.clock.advance(7200)
        rig.player.state = .playing
        rig.supervisor.tick()
        rig.run(3, state: .playing)
        #expect(rig.status == .playing)
        rig.tick(state: .playing)  // 4 s frozen after the wake
        #expect(rig.status == .reconnecting(attempt: 1))
        #expect(rig.memory.bufferMs(forStreamURL: urlA) == saved)
        rig.tick()
        #expect(rig.player.plays.count == plays + 1)
        #expect(rig.player.plays.last?.bufferMs == before)
    }

    @Test func stallAfterPostWakeProgressStillStepsBufferUp() {
        let rig = Rig()
        rig.startPlaying()
        rig.clock.advance(7200)
        rig.player.state = .playing
        rig.supervisor.tick()
        rig.tick(progress: true, state: .playing)  // the stream survived the sleep
        rig.freeze()
        #expect(rig.status == .reconnecting(attempt: 1))
        #expect(rig.memory.bufferMs(forStreamURL: urlA) == 2000)
        rig.tick()
        #expect(rig.player.plays.last?.bufferMs == 2000)
    }

    @Test func wakeFromUnavailableRetriesFromAttemptOne() {
        let rig = Rig()
        rig.driveToUnavailable()
        rig.clock.advance(7200)
        rig.supervisor.tick()
        #expect(rig.status == .reconnecting(attempt: 1))
        #expect(rig.player.plays.count == 6)
        rig.tick()
        #expect(rig.player.plays.count == 7)
    }

    @Test func wakeMidRetryRestartsFromAttemptOne() {
        let rig = Rig()
        rig.supervisor.play(streamURL: urlA)
        rig.run(12, state: .opening)  // fail 1
        rig.run(1, state: .opening)  // attempt 2 play
        rig.run(12, state: .opening)  // fail 2
        #expect(rig.status == .reconnecting(attempt: 2))
        rig.clock.advance(7200)
        rig.supervisor.tick()
        #expect(rig.status == .reconnecting(attempt: 1))
        let before = rig.player.plays.count
        rig.tick()
        #expect(rig.player.plays.count == before + 1)
    }

    @Test func playNewChannelAbandonsPendingRetry() {
        let rig = Rig()
        rig.supervisor.play(streamURL: urlA)
        rig.run(12, state: .opening)
        #expect(rig.status == .reconnecting(attempt: 1))
        rig.supervisor.play(streamURL: urlB)
        #expect(rig.status == .starting)
        #expect(rig.supervisor.reconnectCount == 0)
        #expect(rig.player.plays.last?.url.absoluteString == urlB)
        #expect(rig.player.plays.last?.bufferMs == 1000)
        let count = rig.player.plays.count
        rig.run(5, progress: true, state: .playing)
        #expect(rig.player.plays.count == count)
        #expect(rig.player.plays.filter { $0.url.absoluteString == urlA }.count == 1)
        #expect(rig.status == .playing)
    }

    @Test func stopCancelsEverything() {
        let rig = Rig()
        rig.supervisor.play(streamURL: urlA)
        rig.run(12, state: .opening)
        #expect(rig.status == .reconnecting(attempt: 1))
        let stops = rig.player.stopCount
        rig.supervisor.stop()
        #expect(rig.status == .idle)
        #expect(rig.player.stopCount == stops + 1)
        let plays = rig.player.plays.count
        rig.run(60, state: .opening)
        #expect(rig.player.plays.count == plays)
        #expect(rig.status == .idle)
    }

    @Test func sameURLPlayedAgainWithinOneSecondIsDeferred() {
        let rig = Rig()
        rig.supervisor.play(streamURL: urlA)
        rig.supervisor.stop()
        rig.supervisor.play(streamURL: urlA)  // same instant
        #expect(rig.status == .starting)
        #expect(rig.player.plays.count == 1)
        rig.tick(after: 0.5)
        #expect(rig.player.plays.count == 1)
        rig.tick(after: 0.5)
        #expect(rig.player.plays.count == 2)
    }

    @Test func unparseableURLIsUnavailableWithoutPlaying() {
        let rig = Rig()
        rig.supervisor.play(streamURL: "")
        #expect(rig.status == .unavailable)
        #expect(rig.player.plays.isEmpty)
        #expect(rig.player.stopCount >= 1)
        rig.supervisor.retry()
        rig.run(30)
        #expect(rig.player.plays.isEmpty)
        #expect(rig.status == .unavailable)
    }

    @Test func neverTwoPlayCallsWithinOneSecond() {
        var scenarios: [(String, SupervisorPolicy, (Rig) -> Void)] = []
        scenarios.append(("start timeouts to unavailable, retry, again", .default, { rig in
            rig.driveToUnavailable()
            rig.supervisor.retry()
            rig.run(200, state: .opening)
        }))
        scenarios.append(("stall, recover, stall", .default, { rig in
            rig.startPlaying()
            rig.freeze()
            rig.recover()
            rig.freeze()
            rig.run(10, state: .opening)
        }))
        scenarios.append(("error loop", .default, { rig in
            rig.supervisor.play(streamURL: urlA)
            rig.run(120, state: .error)
        }))
        scenarios.append(("stutter", .default, { rig in
            rig.startPlaying()
            for _ in 1...3 {
                rig.tick(progress: true, state: .buffering)
                rig.tick(progress: true, state: .playing)
            }
            rig.run(10, progress: true, state: .playing)
        }))
        scenarios.append(("wake restarts", .default, { rig in
            rig.driveToUnavailable()
            rig.clock.advance(7200); rig.supervisor.tick()
            rig.run(30, state: .opening)
            rig.clock.advance(7200); rig.supervisor.tick()
            rig.run(30, state: .opening)
        }))
        scenarios.append(("replay of the same URL", .default, { rig in
            rig.supervisor.play(streamURL: urlA)
            rig.supervisor.play(streamURL: urlA)
            rig.supervisor.stop()
            rig.supervisor.play(streamURL: urlA)
            rig.run(30, state: .opening)
        }))
        var fast = SupervisorPolicy()
        fast.retryDelays = [0, 0.2, 0.5]
        fast.startTimeout = 0.1
        scenarios.append(("policy with sub-second delays", fast, { rig in
            rig.supervisor.play(streamURL: urlA)
            rig.run(60, step: 0.1, state: .error)
        }))

        for (name, policy, scenario) in scenarios {
            let rig = Rig(policy: policy)
            scenario(rig)
            #expect(rig.player.plays.count >= 2, "\(name) must have reconnected")
            #expect(minSpacingPerURL(rig.player.plays) >= 1, "\(name)")
        }
    }

    @Test func statusChangeCallbackFiresOncePerChange() {
        let rig = Rig()
        rig.supervisor.play(streamURL: urlB)
        rig.supervisor.play(streamURL: urlA)  // still .starting: no event
        rig.tick(state: .opening)  // no change: no event
        rig.tick(progress: true, state: .playing)
        rig.run(5, progress: true, state: .playing)
        rig.freeze()
        rig.run(3)  // retry fires, still reconnecting(1): no event
        rig.tick(progress: true, state: .playing)
        rig.supervisor.stop()
        rig.supervisor.stop()  // already idle: no event
        #expect(rig.statuses == [.starting, .playing, .reconnecting(attempt: 1), .playing, .idle])
    }
}

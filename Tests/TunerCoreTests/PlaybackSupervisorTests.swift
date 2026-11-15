import Foundation
import Testing
@testable import TunerCore

private let urlA = "http://example.invalid/a"
private let urlB = "http://example.invalid/b"

// MARK: - Doubles

// Nested in the suite, so that a double of the same name in another test file cannot clash.
extension PlaybackSupervisorTests {
    @MainActor final class TestClock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        /// The total by which the wall clock has been set (`setWallClock`), as opposed to time passing.
        private(set) var adjustment: TimeInterval = 0
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
        /// Sets the wall clock back (negative) or forward, with no time passing.
        func setWallClock(by seconds: TimeInterval) {
            now = now.addingTimeInterval(seconds)
            adjustment += seconds
        }
    }

    @MainActor final class FakePlayer: Player {
        struct PlayCall { var url: URL; var bufferMs: Int; var at: Date; var adjustment: TimeInterval }
        let clock: TestClock
        var plays: [PlayCall] = []
        var stopCount = 0
        var volume = 100
        var state: PlayerState = .idle
        var stats: PlayerStats = .zero

        init(clock: TestClock) { self.clock = clock }

        func play(url: URL, bufferMs: Int) {
            // Shared recorder: every test in this file fails if a URL is replayed within one second of
            // real time (the wall clock's difference, less any setting of the clock in between).
            if let last = plays.last(where: { $0.url == url }),
               clock.now.timeIntervalSince(last.at) - (clock.adjustment - last.adjustment) < 1 {
                Issue.record("play(url:) called twice for the same URL within one second")
            }
            plays.append(PlayCall(url: url, bufferMs: bufferMs, at: clock.now, adjustment: clock.adjustment))
        }

        func stop() { stopCount += 1 }

        /// The shortest real time between two play calls for the same URL.
        var minSpacingPerURL: TimeInterval {
            var minimum = TimeInterval.infinity
            var lastByURL: [URL: PlayCall] = [:]
            for call in plays {
                if let last = lastByURL[call.url] {
                    minimum = min(minimum, call.at.timeIntervalSince(last.at) - (call.adjustment - last.adjustment))
                }
                lastByURL[call.url] = call
            }
            return minimum
        }
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

    @Test func chronicStutterAtTheTopBufferStepKeepsPlaying() {
        let rig = Rig(remembered: 4000)
        rig.startPlaying()
        // Below the top step a stutter still restarts the stream once, a step up...
        for round in 1...3 {
            rig.tick(progress: true, state: .buffering)
            if round < 3 { rig.tick(progress: true, state: .playing) }
        }
        #expect(rig.status == .reconnecting(attempt: 1))
        #expect(rig.supervisor.currentBufferMs == 8000)
        rig.recover()
        #expect(rig.status == .playing)
        let plays = rig.player.plays.count
        // ...but at the top step a restart cannot add buffer. Five minutes of a rebuffer every 12 s
        // are ridden out: no restart, no failure counted, never "unavailable".
        for _ in 1...25 {
            rig.tick(progress: true, state: .buffering)
            rig.tick(progress: true, state: .playing)
            rig.run(10, progress: true, state: .playing)
        }
        #expect(rig.status == .playing)
        #expect(!rig.statuses.contains(.unavailable))
        #expect(rig.player.plays.count == plays)
        #expect(rig.supervisor.reconnectCount == 1)
        #expect(rig.memory.bufferMs(forStreamURL: urlA) == 8000)
        // A real stall at the top step is still caught.
        rig.freeze()
        #expect(rig.status == .reconnecting(attempt: 1))
        rig.tick()
        #expect(rig.player.plays.count == plays + 1)
        #expect(rig.player.plays.last?.bufferMs == 8000)
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
        #expect(rig.supervisor.reconnectCount == 5)
    }

    /// End to end: a playing stream loses the network, every reconnect fails to start, the supervisor
    /// gives up, and from then on nothing is opened or stopped, however long it is left.
    @Test func networkLostWhilePlayingEndsUnavailableAndStopsConnecting() {
        let rig = Rig()
        rig.startPlaying()
        rig.run(30, progress: true, state: .playing)
        #expect(rig.status == .playing)
        rig.freeze()  // the network goes: the picture stops
        #expect(rig.status == .reconnecting(attempt: 1))
        var guardTicks = 0
        while rig.status != .unavailable && guardTicks < 1000 { rig.tick(state: .opening); guardTicks += 1 }
        let reconnecting = (1...5).map { PlaybackSupervisor.Status.reconnecting(attempt: $0) }
        #expect(rig.statuses == [.starting, .playing] + reconnecting + [.unavailable])
        #expect(rig.player.plays.count == 6)
        #expect(rig.supervisor.reconnectCount == 5)
        // The stall stepped the buffer up once; the failed starts after it left it alone.
        #expect(rig.player.plays.dropFirst().allSatisfy { $0.bufferMs == 2000 })
        #expect(rig.memory.bufferMs(forStreamURL: urlA) == 2000)
        #expect(rig.player.minSpacingPerURL >= 1)
        let stops = rig.player.stopCount
        rig.run(600, state: .opening)
        #expect(rig.status == .unavailable)
        #expect(rig.player.plays.count == 6)
        #expect(rig.player.stopCount == stops)
    }

    /// Reconnects actually made: a failure still waiting out its delay is not one yet, and the
    /// failure that gives up is never one.
    @Test func reconnectCountCountsOnlyReconnectsMade() {
        let rig = Rig()
        rig.supervisor.play(streamURL: urlA)
        rig.run(12, state: .opening)
        #expect(rig.status == .reconnecting(attempt: 1))
        #expect(rig.supervisor.reconnectCount == 0)
        rig.tick(state: .opening)
        #expect(rig.player.plays.count == 2)
        #expect(rig.supervisor.reconnectCount == 1)
        var guardTicks = 0
        while rig.status != .unavailable && guardTicks < 1000 { rig.tick(state: .opening); guardTicks += 1 }
        #expect(rig.player.plays.count == 6)
        #expect(rig.supervisor.reconnectCount == 5)
        // A wake from unavailable schedules attempt 1 again; it counts once its play call is made.
        rig.clock.advance(7200)
        rig.supervisor.tick()
        #expect(rig.status == .reconnecting(attempt: 1))
        #expect(rig.supervisor.reconnectCount == 5)
        rig.tick()
        #expect(rig.player.plays.count == 7)
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
        #expect(rig.supervisor.currentBufferMs == 4000)  // the live stream was opened at 4000
        #expect(rig.player.plays.count == 1)
        #expect(rig.status == .playing)
        rig.run(3600, step: 5, progress: true, state: .playing)
        #expect(rig.memory.bufferMs(forStreamURL: urlA) == 1000)  // saturates at the first step
        #expect(rig.player.plays.count == 1)
    }

    /// A step down is for the next play call; the live stream keeps the buffer it was opened with, and a
    /// stall steps up from that, not from the lowered value.
    @Test func stallAfterAStepDownReplaysOneStepAboveTheBufferThatStalled() {
        let rig = Rig(remembered: 4000)
        rig.startPlaying()
        rig.run(1810, step: 5, progress: true, state: .playing)  // thirty clean minutes: one step down
        #expect(rig.memory.bufferMs(forStreamURL: urlA) == 2000)
        #expect(rig.supervisor.currentBufferMs == 4000)
        rig.freeze()
        #expect(rig.status == .reconnecting(attempt: 1))
        #expect(rig.memory.bufferMs(forStreamURL: urlA) == 8000)
        #expect(rig.supervisor.currentBufferMs == 8000)
        rig.tick()
        #expect(rig.player.plays.count == 2)
        #expect(rig.player.plays.last?.bufferMs == 8000)
    }

    /// Opened at the top step and since stepped down: a restart could not add buffer to the live
    /// stream, so a stutter is ridden out, and a real stall remembers the top step again.
    @Test func stutterAfterAStepDownAtTheTopStepIsRiddenOut() {
        let rig = Rig(remembered: 8000)
        rig.startPlaying()
        rig.run(1810, step: 5, progress: true, state: .playing)
        #expect(rig.memory.bufferMs(forStreamURL: urlA) == 4000)
        #expect(rig.supervisor.currentBufferMs == 8000)
        for _ in 1...3 {
            rig.tick(progress: true, state: .buffering)
            rig.tick(progress: true, state: .playing)
        }
        #expect(rig.status == .playing)
        #expect(rig.player.plays.count == 1)
        rig.freeze()
        #expect(rig.status == .reconnecting(attempt: 1))
        #expect(rig.memory.bufferMs(forStreamURL: urlA) == 8000)
        rig.tick()
        #expect(rig.player.plays.last?.bufferMs == 8000)
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

    /// The wall clock set forward by less than a wake, with no time passing: progress is seen first,
    /// so a stream that is still progressing is not failed.
    @Test func forwardClockStepWhileProgressingIsNotAStall() {
        let rig = Rig()
        rig.startPlaying()
        rig.clock.setWallClock(by: 20)
        rig.tick(after: 0, progress: true, state: .playing)
        #expect(rig.status == .playing)
        #expect(rig.player.plays.count == 1)
        #expect(rig.memory.bufferMs(forStreamURL: urlA) == nil)
        rig.run(5, progress: true, state: .playing)
        #expect(rig.status == .playing)
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

    /// After a wake, rebuffering with no progress is the sleep's doing, as a stall then would be: the
    /// stream is restarted, but its buffer is not stepped up. With a tick a second the default policy
    /// stalls first; ticks bunched closer together (a late timer catching up) reach the storm.
    @Test func rebufferStormAfterAWakeWithNoProgressIsNotBilled() {
        let rig = Rig()
        rig.startPlaying()
        rig.clock.advance(7200)
        rig.player.state = .playing
        rig.supervisor.tick()
        for _ in 1...2 {
            rig.tick(after: 0.5, state: .buffering)
            rig.tick(after: 0.5, state: .playing)
        }
        rig.tick(after: 0.5, state: .buffering)  // the third rebuffer, 2.5 s after the wake
        #expect(rig.status == .reconnecting(attempt: 1))
        #expect(rig.memory.bufferMs(forStreamURL: urlA) == nil)
        #expect(rig.supervisor.currentBufferMs == 1000)
        rig.tick()
        #expect(rig.player.plays.count == 2)
        #expect(rig.player.plays.last?.bufferMs == 1000)
    }

    @Test func rebufferStormAfterPostWakeProgressIsStillAStutter() {
        let rig = Rig()
        rig.startPlaying()
        rig.clock.advance(7200)
        rig.player.state = .playing
        rig.supervisor.tick()
        rig.tick(progress: true, state: .playing)  // the stream survived the sleep
        for round in 1...3 {
            rig.tick(progress: true, state: .buffering)
            if round < 3 { rig.tick(progress: true, state: .playing) }
        }
        #expect(rig.status == .reconnecting(attempt: 1))
        #expect(rig.memory.bufferMs(forStreamURL: urlA) == 2000)
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

    /// Given up, nothing is open for a sleep to have cut off: a clock set back must not start another
    /// round of reconnects. A real wake, a long forward gap, still does.
    @Test func clockSetBackWhileUnavailableDoesNotRetry() {
        let rig = Rig()
        rig.driveToUnavailable()
        rig.clock.setWallClock(by: -3600)
        rig.tick()
        #expect(rig.status == .unavailable)
        rig.run(120)
        #expect(rig.player.plays.count == 6)
        rig.clock.advance(7200)
        rig.supervisor.tick()
        #expect(rig.status == .reconnecting(attempt: 1))
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

    @Test func clockSetBackWhilePlayingStillCatchesAStall() {
        let rig = Rig()
        rig.startPlaying()
        rig.clock.setWallClock(by: -3600)
        rig.tick(state: .playing)  // read as a wake: nothing counted
        #expect(rig.status == .playing)
        #expect(rig.supervisor.reconnectCount == 0)
        rig.run(3, state: .playing)
        #expect(rig.status == .playing)
        rig.tick(state: .playing)  // 4 s frozen since the clock was set back
        #expect(rig.status == .reconnecting(attempt: 1))
        rig.tick()
        #expect(rig.player.plays.count == 2)
        #expect(rig.player.minSpacingPerURL >= 1)
    }

    @Test func clockSetBackMidRetryDoesNotPostponeTheRetry() {
        let rig = Rig()
        rig.supervisor.play(streamURL: urlA)
        rig.run(12, state: .opening)
        #expect(rig.status == .reconnecting(attempt: 1))
        rig.clock.setWallClock(by: -3600)
        rig.tick(state: .opening)  // read as a wake: attempt 1 again, a second from now
        #expect(rig.status == .reconnecting(attempt: 1))
        #expect(rig.player.plays.count == 1)
        rig.tick(state: .opening)
        #expect(rig.player.plays.count == 2)
        // Sustained failure still ends in "unavailable", and then nothing more is opened.
        var guardTicks = 0
        while rig.status != .unavailable && guardTicks < 1000 { rig.tick(state: .opening); guardTicks += 1 }
        #expect(rig.status == .unavailable)
        let plays = rig.player.plays.count
        rig.run(120, state: .opening)
        #expect(rig.player.plays.count == plays)
        #expect(rig.player.minSpacingPerURL >= 1)
    }

    @Test func clockSetBackWhileAPlayIsDeferredDoesNotPostponeIt() {
        let rig = Rig()
        rig.supervisor.play(streamURL: urlA)
        rig.supervisor.stop()
        rig.supervisor.play(streamURL: urlA)  // same instant: deferred by a second
        #expect(rig.player.plays.count == 1)
        rig.clock.setWallClock(by: -3600)
        rig.tick(after: 0.5)  // read as a wake: the play is due a second from now
        rig.tick(after: 0.5)
        #expect(rig.player.plays.count == 1)
        rig.tick(after: 0.5)
        #expect(rig.player.plays.count == 2)
        #expect(rig.status == .starting)
        #expect(rig.player.minSpacingPerURL >= 1)
    }

    @Test func sameChannelPlayedAgainAfterTheClockWasSetBackIsNotPostponed() {
        let rig = Rig()
        rig.startPlaying()
        rig.supervisor.stop()
        rig.clock.setWallClock(by: -3600)
        rig.supervisor.play(streamURL: urlA)  // a second after the last play by the clock now
        #expect(rig.player.plays.count == 1)
        rig.tick()
        #expect(rig.player.plays.count == 2)
        #expect(rig.player.minSpacingPerURL >= 1)
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
            #expect(rig.player.minSpacingPerURL >= 1, "\(name)")
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

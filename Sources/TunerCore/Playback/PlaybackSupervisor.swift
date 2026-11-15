import Foundation

/// Keeps one live stream alive without the owner touching anything: watchdog, reconnect with
/// back-off and a per-channel adaptive buffer. A pure state machine driven only by `tick()`;
/// it owns no timers, registers no callbacks, and reads the time only through `now`.
@MainActor public final class PlaybackSupervisor {
    public enum Status: Equatable, Sendable { case idle, starting, playing, reconnecting(attempt: Int), unavailable }

    private enum Failure { case failedStart, stall, stutter, lostInSleep }

    /// The least time between a play call and the one before it, when both are for the same stream,
    /// whatever the policy says. Only the last play call is remembered, not one per stream: switching to
    /// another channel plays at once, and A, B, A goes straight back to A. Every reconnect is of the
    /// stream played last, so a reconnect always comes at least this long after the play call before it,
    /// whichever stream that was.
    private static let minPlaySpacing: TimeInterval = 1

    private let player: Player
    private let memory: BufferMemory
    private let now: () -> Date
    private let policy: SupervisorPolicy

    public private(set) var status: Status = .idle
    /// Reconnects made since the channel was chosen: play calls after a failure. A failure still
    /// waiting out its delay is not one yet, and the failure that gives up is never one.
    public private(set) var reconnectCount = 0
    /// The buffer the live stream was opened with. Between a failure and the reconnect, and while
    /// unavailable, the one the next play call will open with.
    public private(set) var currentBufferMs: Int
    public var onStatusChange: ((Status) -> Void)?

    private var streamURL: String?
    private var url: URL?
    private var nextBufferMs: Int                // what the next play call opens with; remembered
    private var failures = 0                     // consecutive failed attempts
    private var nextPlayAt: Date?                // a play call is due at this time
    private var lastPlayAt: Date?
    private var lastPlayedURL: String?
    private var lastTickAt: Date?
    private var baseline = PlayerStats.zero      // stats at the previous tick
    private var previousState = PlayerState.idle
    private var attemptStartedAt = Date.distantPast
    private var lastProgressAt = Date.distantPast
    private var hasProgressed = false           // progress seen since the last play call
    private var stableSince: Date?
    private var stepDownSince: Date?
    private var rebufferTimes: [Date] = []
    private var postWake = false                 // woke while playing; no progress seen since

    /// `now` times everything: the start and stall timers, the retry delays, the spacing of play calls,
    /// and the gap between ticks that reveals a sleep. Given the wall clock, a step of the clock is read
    /// as time passing. A step back, or forward past `wakeGap`, is taken for a wake and costs nothing
    /// (when unavailable, only the forward one restarts the retries).
    /// Progress is checked before any timer, so a stream that is progressing is never failed by a step.
    /// But a forward step between `stallAfter` and `wakeGap`, landing on a tick that saw no progress,
    /// fails the stream as a stall (and steps its buffer up), and one past `startTimeout` during a start
    /// fails the start: by `now` alone that cannot be told from the real thing. A `now` that is never set
    /// and counts time asleep (one read from `ContinuousClock`) has no such limit, and still shows a
    /// sleep as a gap.
    public init(player: Player, memory: BufferMemory, now: @escaping () -> Date, policy: SupervisorPolicy = .default) {
        self.player = player
        self.memory = memory
        self.now = now
        self.policy = policy
        currentBufferMs = policy.bufferStepsMs.first ?? 1000
        nextBufferMs = currentBufferMs
    }

    // MARK: Commands

    public func play(streamURL: String) {
        let time = now()
        noteClock(time)
        self.streamURL = streamURL
        failures = 0
        reconnectCount = 0
        nextPlayAt = nil
        lastTickAt = time
        currentBufferMs = memory.bufferMs(forStreamURL: streamURL) ?? policy.bufferStepsMs.first ?? 1000
        nextBufferMs = currentBufferMs
        guard let parsed = URL(string: streamURL) else {
            url = nil
            player.stop()
            setStatus(.unavailable)
            return
        }
        url = parsed
        beginAttempt(.starting, at: time)
    }

    public func stop() {
        player.stop()
        streamURL = nil
        url = nil
        nextPlayAt = nil
        failures = 0
        resetRun()
        setStatus(.idle)
    }

    /// Only meaningful from `.unavailable`.
    public func retry() {
        guard status == .unavailable, url != nil else { return }
        let time = now()
        noteClock(time)
        failures = 0
        beginAttempt(.starting, at: time)
    }

    // MARK: Tick

    public func tick() {
        let time = now()
        noteClock(time)
        defer { lastTickAt = time }

        switch status {
        case .idle:
            return
        case .unavailable:
            // Only a sleep starts over here. Nothing is open for a clock set back to have cut off, and no
            // timer waits on it: taken for a wake, it would only start another round of reconnects.
            if isLongGap(at: time) { restartFromAttemptOne(at: time) }
            return
        case .starting, .playing, .reconnecting:
            break
        }

        if isWake(at: time) {
            if status == .starting || status == .playing {
                forgetProgress(at: time)
                // A play call waiting out its spacing is due by this clock, never by one set back.
                if let due = nextPlayAt { nextPlayAt = min(due, earliest(time)) }
                if status == .playing {
                    postWake = true  // the connection is probably dead; not the stream's fault
                    failures = 0
                }
            } else {
                restartFromAttemptOne(at: time)
            }
            return
        }

        if let due = nextPlayAt {
            if time >= due { startPlayCall(at: time) }
            return
        }

        observe(at: time)
    }

    // MARK: Watching a live attempt

    private func observe(at time: Date) {
        let state = player.state
        let stats = player.stats
        let progressed = stats.positionMs > baseline.positionMs
            || stats.displayedPictures > baseline.displayedPictures
            || stats.decodedAudioBlocks > baseline.decodedAudioBlocks
        baseline = stats
        let wasPlaying = previousState == .playing
        previousState = state

        if status == .playing, wasPlaying, state == .buffering, noteRebuffer(at: time) {
            guard isAtTopBufferStep else {
                // Woken with no progress since: the sleep's doing, as a stall would be, not the buffer's.
                fail(postWake ? .lostInSleep : .stutter, at: time)
                return
            }
            // A restart could not add buffer here; it would only cost a connection and an attempt.
            // Ride it out: a stream that stops progressing is still caught as a stall.
            rebufferTimes.removeAll(keepingCapacity: true)
            // But a storm is not clean playback: undo a step down taken meanwhile (at the top step this
            // puts the next and remembered buffer back to the live one), and count the clean interval
            // for the next step down from now.
            moveBuffer(by: 1)
            stepDownSince = time
        }

        if progressed {
            postWake = false
            lastProgressAt = time
            if !hasProgressed {
                hasProgressed = true
                stableSince = time
                stepDownSince = time
                setStatus(.playing)
            }
            if failures > 0, let since = stableSince, time.timeIntervalSince(since) >= policy.stableAfter {
                failures = 0
            }
            if let since = stepDownSince, time.timeIntervalSince(since) >= policy.stepDownAfter {
                stepDownSince = time
                moveBuffer(by: -1)
            }
            return
        }

        if hasProgressed {
            if state == .error || state == .ended || time.timeIntervalSince(lastProgressAt) >= policy.stallAfter {
                fail(postWake ? .lostInSleep : .stall, at: time)
            }
        } else if state == .error || state == .ended
                    || time.timeIntervalSince(attemptStartedAt) >= policy.startTimeout {
            fail(.failedStart, at: time)
        }
    }

    /// Records a playing-to-buffering transition. True when it is the one that makes a stutter.
    private func noteRebuffer(at time: Date) -> Bool {
        rebufferTimes.removeAll { time.timeIntervalSince($0) >= policy.rebufferWindow }
        rebufferTimes.append(time)
        return rebufferTimes.count >= policy.rebufferLimit
    }

    // MARK: Failure, retry, give up

    private func fail(_ kind: Failure, at time: Date) {
        player.stop()
        if kind == .stall || kind == .stutter { moveBuffer(by: 1) }
        resetRun()
        failures += 1
        scheduleRetry(at: time)
    }

    /// Moves to `.reconnecting(failures)` and the delay for that attempt, or gives up. The stream is
    /// stopped by now, so the buffer in force is the one the next play call opens with.
    private func scheduleRetry(at time: Date) {
        currentBufferMs = nextBufferMs
        guard failures >= 1, failures <= policy.retryDelays.count else {
            nextPlayAt = nil
            setStatus(.unavailable)
            return
        }
        setStatus(.reconnecting(attempt: failures))
        nextPlayAt = earliest(time.addingTimeInterval(policy.retryDelays[failures - 1]))
    }

    private func restartFromAttemptOne(at time: Date) {
        guard url != nil, !policy.retryDelays.isEmpty else { return }
        player.stop()
        resetRun()
        forgetProgress(at: time)
        failures = 1
        scheduleRetry(at: time)
    }

    // MARK: Play calls

    /// Begins an attempt: plays now, or as soon as the one-second spacing allows.
    private func beginAttempt(_ newStatus: Status, at time: Date) {
        resetRun()
        setStatus(newStatus)
        let due = earliest(time)
        if due > time {
            player.stop()  // never two streams: the previous one is gone while we wait
            nextPlayAt = due
        } else {
            startPlayCall(at: time)
        }
    }

    private func startPlayCall(at time: Date) {
        nextPlayAt = nil
        guard let url else { return }
        resetRun()
        if case .reconnecting = status { reconnectCount += 1 }
        lastPlayAt = time
        lastPlayedURL = streamURL
        attemptStartedAt = time
        lastProgressAt = time
        currentBufferMs = nextBufferMs
        player.play(url: url, bufferMs: currentBufferMs)
        baseline = player.stats
    }

    /// `time`, or `minPlaySpacing` after the last play call if that call was for this same stream.
    private func earliest(_ time: Date) -> Date {
        guard let last = lastPlayAt, lastPlayedURL == streamURL else { return time }
        return max(time, last.addingTimeInterval(Self.minPlaySpacing))
    }

    /// Called with each reading of the clock. A previous play call stamped after `time` means the wall
    /// clock has been set back since; how long ago that call really was is unknown, so it is taken as
    /// just now. The one-second spacing then counts from `time` instead of waiting for the clock to
    /// catch up, and is still at least a second of real time.
    private func noteClock(_ time: Date) {
        if let last = lastPlayAt, last > time { lastPlayAt = time }
    }

    // MARK: Buffer

    /// No step is above the buffer the live stream was opened with, so a restart could not add any.
    private var isAtTopBufferStep: Bool {
        !policy.bufferStepsMs.contains { $0 > currentBufferMs }
    }

    /// Sets, and remembers, the buffer for the next play call; the live stream keeps its own. Up: one
    /// step above the buffer the stream that failed was opened with, or that buffer again at the top
    /// step, so a step down taken meanwhile is undone. Down: one step below the next play call's buffer.
    private func moveBuffer(by direction: Int) {
        let steps = policy.bufferStepsMs
        let target: Int?
        if direction > 0 {
            target = steps.first { $0 > currentBufferMs } ?? currentBufferMs
        } else {
            target = steps.last { $0 < nextBufferMs }
        }
        guard let target, target != nextBufferMs, let streamURL else { return }
        nextBufferMs = target
        memory.setBufferMs(target, forStreamURL: streamURL)
    }

    // MARK: Bookkeeping

    /// A tick long after the last, or one stamped before it: a wall clock set back is read as a wake
    /// too, or every timer would wait for the clock to catch up.
    private func isWake(at time: Date) -> Bool {
        guard let last = lastTickAt else { return false }
        return time < last || isLongGap(at: time)
    }

    /// A tick long after the last: the Mac slept.
    private func isLongGap(at time: Date) -> Bool {
        guard let last = lastTickAt else { return false }
        return time.timeIntervalSince(last) > policy.wakeGap
    }

    /// Forgets the progress baseline and every timer; the next tick starts fresh.
    private func forgetProgress(at time: Date) {
        baseline = player.stats
        previousState = player.state
        attemptStartedAt = time
        lastProgressAt = time
        stableSince = hasProgressed ? time : nil
        stepDownSince = hasProgressed ? time : nil
        rebufferTimes.removeAll(keepingCapacity: true)
    }

    private func resetRun() {
        hasProgressed = false
        postWake = false
        stableSince = nil
        stepDownSince = nil
        previousState = .idle
        rebufferTimes.removeAll(keepingCapacity: true)
    }

    private func setStatus(_ newStatus: Status) {
        guard newStatus != status else { return }
        status = newStatus
        onStatusChange?(newStatus)
    }
}

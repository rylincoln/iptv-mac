import Foundation

/// Keeps one live stream alive without the owner touching anything: watchdog, reconnect with
/// back-off and a per-channel adaptive buffer. A pure state machine driven only by `tick()`;
/// it owns no timers, registers no callbacks, and reads the time only through `now`.
@MainActor public final class PlaybackSupervisor {
    public enum Status: Equatable, Sendable { case idle, starting, playing, reconnecting(attempt: Int), unavailable }

    private enum Failure { case failedStart, stall, stutter, lostInSleep }

    /// Spacing between two `player.play` calls for the same stream, whatever the policy says.
    private static let minPlaySpacing: TimeInterval = 1

    private let player: Player
    private let memory: BufferMemory
    private let now: () -> Date
    private let policy: SupervisorPolicy

    public private(set) var status: Status = .idle
    public private(set) var reconnectCount = 0
    public private(set) var currentBufferMs: Int
    public var onStatusChange: ((Status) -> Void)?

    private var streamURL: String?
    private var url: URL?
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

    public init(player: Player, memory: BufferMemory, now: @escaping () -> Date, policy: SupervisorPolicy = .default) {
        self.player = player
        self.memory = memory
        self.now = now
        self.policy = policy
        currentBufferMs = policy.bufferStepsMs.first ?? 1000
    }

    // MARK: Commands

    public func play(streamURL: String) {
        let time = now()
        self.streamURL = streamURL
        failures = 0
        reconnectCount = 0
        nextPlayAt = nil
        lastTickAt = time
        currentBufferMs = memory.bufferMs(forStreamURL: streamURL) ?? policy.bufferStepsMs.first ?? 1000
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
        failures = 0
        beginAttempt(.starting, at: now())
    }

    // MARK: Tick

    public func tick() {
        let time = now()
        defer { lastTickAt = time }

        switch status {
        case .idle:
            return
        case .unavailable:
            if isWake(at: time) { restartFromAttemptOne(at: time) }
            return
        case .starting, .playing, .reconnecting:
            break
        }

        if isWake(at: time) {
            if status == .starting || status == .playing {
                forgetProgress(at: time)
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
                fail(.stutter, at: time)
                return
            }
            // A restart could not add buffer here; it would only cost a connection and an attempt.
            // Ride it out: a stream that stops progressing is still caught as a stall.
            rebufferTimes.removeAll(keepingCapacity: true)
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
        reconnectCount += 1
        scheduleRetry(at: time)
    }

    /// Moves to `.reconnecting(failures)` and the delay for that attempt, or gives up.
    private func scheduleRetry(at time: Date) {
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
        reconnectCount += 1
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
        lastPlayAt = time
        lastPlayedURL = streamURL
        attemptStartedAt = time
        lastProgressAt = time
        player.play(url: url, bufferMs: currentBufferMs)
        baseline = player.stats
    }

    /// Never sooner than one second after the previous play call for the same stream.
    private func earliest(_ time: Date) -> Date {
        guard let last = lastPlayAt, lastPlayedURL == streamURL else { return time }
        return max(time, last.addingTimeInterval(Self.minPlaySpacing))
    }

    // MARK: Buffer

    /// No step is above the buffer in force, so stepping up would not change it.
    private var isAtTopBufferStep: Bool {
        !policy.bufferStepsMs.contains { $0 > currentBufferMs }
    }

    private func moveBuffer(by direction: Int) {
        let steps = policy.bufferStepsMs
        let next: Int?
        if direction > 0 {
            next = steps.first { $0 > currentBufferMs }
        } else {
            next = steps.last { $0 < currentBufferMs }
        }
        guard let next, next != currentBufferMs, let streamURL else { return }
        currentBufferMs = next
        memory.setBufferMs(next, forStreamURL: streamURL)
    }

    // MARK: Bookkeeping

    private func isWake(at time: Date) -> Bool {
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

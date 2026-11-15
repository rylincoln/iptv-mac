import Foundation

/// Works out what one play call is doing from the engine's events and its counters.
///
/// The engine's own state cannot be trusted as "is it playing": on a healthy live stream it sticks
/// at buffering for the whole session. So a reading says `.playing` while the counters are actually
/// advancing, `.buffering` only when the engine says buffering and nothing has advanced since the
/// previous reading, and `.ended` / `.error` as the engine reports them, for good.
///
/// Nothing but an Opening is taken until one has been: an event that arrives before it belongs to
/// the stream being left.
public struct PlaybackProgress: Sendable {
    public enum Event: Equatable, Sendable { case opening, buffering, running, ended, error }

    /// Readings closer together than this reuse the previous verdict, so two in a row never look
    /// like a stall.
    public static let minSampleInterval: TimeInterval = 0.5

    /// An Opening was taken, so the engine has made its input and its counters mean something.
    public private(set) var hasOpened = false
    private var lastEvent: Event?
    private var sample = PlayerStats.zero  // counters at the previous reading
    private var sampledAt: TimeInterval
    private var advancing = false
    private var hasAdvanced = false

    /// `uptime`: when the play call was made, on the clock `state(at:…)` is given.
    public init(startedAt uptime: TimeInterval) {
        sampledAt = uptime
    }

    public mutating func take(_ event: Event) {
        if lastEvent == .ended || lastEvent == .error { return }  // final for this play call
        guard hasOpened || event == .opening else { return }
        lastEvent = event
        if event == .opening { hasOpened = true }
    }

    /// A reading. It compares the counters with those of the previous reading, so each one moves the
    /// window the next is judged over. `counters` and `enginePlaying` are asked for only when a new
    /// sample is due.
    public mutating func state(
        at uptime: TimeInterval, counters: () -> PlayerStats, enginePlaying: () -> Bool
    ) -> PlayerState {
        switch lastEvent {
        case nil: return .opening
        case .ended: return .ended
        case .error: return .error
        case .opening, .buffering, .running: break
        }
        if uptime - sampledAt >= Self.minSampleInterval {
            let current = counters()
            let moved = current.positionMs > sample.positionMs
                || current.displayedPictures > sample.displayedPictures
                || current.decodedAudioBlocks > sample.decodedAudioBlocks
            advancing = moved && enginePlaying()
            if advancing { hasAdvanced = true }
            sample = current
            sampledAt = uptime
        }
        if advancing { return .playing }
        if lastEvent == .buffering { return .buffering }
        return hasAdvanced ? .playing : .opening
    }
}

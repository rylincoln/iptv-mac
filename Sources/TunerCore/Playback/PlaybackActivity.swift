import Foundation

/// What the process must hold while playback is in a given state.
public enum PlaybackActivity: Equatable, Sendable {
    /// Keeps App Nap from spacing the supervisor's ticks apart; the display and the Mac may sleep.
    case avoidAppNap
    /// As `avoidAppNap`, and the display stays on.
    case keepDisplayAwake

    /// Nil when nothing needs holding. The supervisor reads a long gap between ticks as the Mac having
    /// slept, so any status that is ticking, `.unavailable` included, must not be napped.
    public static func needed(for status: PlaybackSupervisor.Status) -> PlaybackActivity? {
        switch status {
        case .idle: return nil
        case .starting, .playing, .reconnecting: return .keepDisplayAwake
        case .unavailable: return .avoidAppNap
        }
    }
}

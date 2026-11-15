import Foundation

/// Dates that setting the wall clock cannot move, for timing playback (`PlaybackSupervisor`'s `now`).
/// The first is the wall clock's time when this is made; after that only `ContinuousClock` moves them.
/// That clock is never set and keeps counting while the Mac sleeps, so a sleep still shows as a long
/// gap between ticks. Once the wall clock is set they drift from it, so they are for measuring time,
/// never for showing or storing it.
public struct ContinuousDate: Sendable {
    private let wallStart: Date
    private let start: ContinuousClock.Instant

    public init(wallStart: Date = Date(), start: ContinuousClock.Instant = .now) {
        self.wallStart = wallStart
        self.start = start
    }

    public func now() -> Date { date(at: .now) }

    func date(at instant: ContinuousClock.Instant) -> Date {
        let elapsed = start.duration(to: instant).components
        return wallStart.addingTimeInterval(Double(elapsed.seconds) + Double(elapsed.attoseconds) * 1e-18)
    }
}

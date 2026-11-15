import Foundation

/// Which failed downloads say that the host itself cannot be reached, and for how long that is
/// believed. Used for logos: a host taken as unreachable is not asked for any logo meanwhile.
public enum UnreachableHost {
    /// How long a host is taken as unreachable after such a failure.
    public static let memory: Duration = .seconds(10 * 60)

    /// `memory` when `error` says the host cannot be found, cannot be connected to, or cannot be spoken
    /// to securely: a retry minutes later would most likely fail the same way. Nil for every other
    /// failure, which says nothing lasting about the host (a timeout, including a transfer slower than
    /// the session allows; a connection lost; being offline; a cancel), so the next request tries again.
    public static func memory(for error: any Error) -> Duration? {
        guard let code = (error as? URLError)?.code else { return nil }
        switch code {
        case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost,
             .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .clientCertificateRejected, .clientCertificateRequired:
            return memory
        default:
            return nil
        }
    }
}

/// A set whose members each lapse at their own time. Bounded: when full, lapsed members are dropped
/// first, and if none have lapsed it starts again empty, so a forgotten member is at worst tried once
/// more.
public struct ExpiringSet<Element: Hashable & Sendable>: Sendable {
    public let limit: Int
    private var expiries: [Element: ContinuousClock.Instant] = [:]

    public init(limit: Int) { self.limit = max(1, limit) }

    public var count: Int { expiries.count }

    /// Holds `element` for `duration` from `now`, or for longer if it was already held longer.
    public mutating func insert(_ element: Element, at now: ContinuousClock.Instant, for duration: Duration) {
        let expiry = now + duration
        if let held = expiries[element] {
            expiries[element] = max(held, expiry)
            return
        }
        if expiries.count >= limit { expiries = expiries.filter { now < $0.value } }
        if expiries.count >= limit { expiries.removeAll(keepingCapacity: true) }
        expiries[element] = expiry
    }

    /// True while `element` is held at `now`.
    public func contains(_ element: Element, at now: ContinuousClock.Instant) -> Bool {
        guard let expiry = expiries[element] else { return false }
        return now < expiry
    }
}

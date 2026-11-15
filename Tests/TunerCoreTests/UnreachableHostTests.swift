import Foundation
import Testing
@testable import TunerCore

private struct OtherFailure: Error {}

@Suite struct UnreachableHostTests {
    @Test func aHostThatCannotBeFoundOrReachedIsRememberedForTenMinutes() {
        #expect(UnreachableHost.memory == .seconds(600))
        let codes: [URLError.Code] = [
            .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost,
            .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
            .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
            .clientCertificateRejected, .clientCertificateRequired,
        ]
        for code in codes {
            #expect(UnreachableHost.memory(for: URLError(code)) == .seconds(600), "\(code.rawValue)")
        }
    }

    /// URLSession can hand back its errors as `NSError`s.
    @Test func theSameFailureAsAnNSErrorIsRemembered() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)
        #expect(UnreachableHost.memory(for: error) == .seconds(600))
    }

    /// Including a logo slower than the session's whole-transfer limit, which fails as timed out.
    @Test func aPassingFailureIsNotRemembered() {
        let codes: [URLError.Code] = [
            .timedOut, .networkConnectionLost, .notConnectedToInternet, .cancelled,
            .badServerResponse, .cannotLoadFromNetwork, .dataNotAllowed, .unknown,
        ]
        for code in codes {
            #expect(UnreachableHost.memory(for: URLError(code)) == nil, "\(code.rawValue)")
        }
        #expect(UnreachableHost.memory(for: CancellationError()) == nil)
        #expect(UnreachableHost.memory(for: OtherFailure()) == nil)
        #expect(UnreachableHost.memory(for: NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED))) == nil)
    }
}

@Suite struct ExpiringSetTests {
    private let t0 = ContinuousClock.now

    @Test func aMemberIsHeldUntilItsTimeIsUp() {
        var set = ExpiringSet<String>(limit: 8)
        set.insert("a", at: t0, for: .seconds(600))
        #expect(set.contains("a", at: t0))
        #expect(set.contains("a", at: t0 + .milliseconds(599_999)))
        #expect(!set.contains("a", at: t0 + .seconds(600)))
        #expect(!set.contains("a", at: t0 + .seconds(3600)))
        #expect(!set.contains("b", at: t0))
    }

    @Test func insertingAgainKeepsTheLaterTime() {
        var set = ExpiringSet<String>(limit: 8)
        set.insert("a", at: t0, for: .seconds(600))
        set.insert("a", at: t0 + .seconds(300), for: .seconds(600))
        #expect(set.contains("a", at: t0 + .seconds(800)))
        set.insert("a", at: t0, for: .seconds(10))
        #expect(set.contains("a", at: t0 + .seconds(800)))
        #expect(set.count == 1)
    }

    @Test func whenFullLapsedMembersGoFirst() {
        var set = ExpiringSet<String>(limit: 3)
        set.insert("a", at: t0, for: .seconds(10))
        set.insert("b", at: t0, for: .seconds(1000))
        set.insert("c", at: t0, for: .seconds(1000))
        set.insert("d", at: t0 + .seconds(20), for: .seconds(600))
        #expect(set.count == 3)
        for member in ["b", "c", "d"] { #expect(set.contains(member, at: t0 + .seconds(20))) }
    }

    @Test func whenFullOfLiveMembersItStartsAgainEmpty() {
        var set = ExpiringSet<String>(limit: 3)
        for member in ["a", "b", "c"] { set.insert(member, at: t0, for: .seconds(600)) }
        set.insert("d", at: t0, for: .seconds(600))
        #expect(set.count == 1)
        #expect(set.contains("d", at: t0))
        #expect(!set.contains("a", at: t0))
    }

    @Test func neverHoldsMoreThanItsLimit() {
        var set = ExpiringSet<Int>(limit: 5)
        for member in 0..<100 {
            set.insert(member, at: t0 + .seconds(member), for: .seconds(3))
            #expect(set.count <= 5)
        }
    }
}

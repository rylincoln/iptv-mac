import Testing
@testable import TunerCore

@Suite struct PlayerStatsTests {
    @Test func aNormalBitrateIsKept() {
        #expect(PlayerStats.sanitisedKbps(4_500.5) == 4_500.5)
        #expect(PlayerStats.sanitisedKbps(0) == 0)
        #expect(PlayerStats.sanitisedKbps(1_000_000) == 1_000_000)
    }

    @Test func notANumberAndInfinitiesReadAsZero() {
        #expect(PlayerStats.sanitisedKbps(.nan) == 0)
        #expect(PlayerStats.sanitisedKbps(.signalingNaN) == 0)
        #expect(PlayerStats.sanitisedKbps(.infinity) == 0)
        #expect(PlayerStats.sanitisedKbps(-.infinity) == 0)
    }

    @Test func aNegativeBitrateReadsAsZero() {
        #expect(PlayerStats.sanitisedKbps(-1) == 0)
        #expect(PlayerStats.sanitisedKbps(-.greatestFiniteMagnitude) == 0)
    }

    @Test func aHugeBitrateIsHeldToAGigabitPerSecond() {
        #expect(PlayerStats.sanitisedKbps(1_000_000.5) == 1_000_000)
        #expect(PlayerStats.sanitisedKbps(.greatestFiniteMagnitude) == 1_000_000)
    }

    /// The overlay rounds the reading to a whole number; that must never trap.
    @Test func everyReadingConvertsToAnInteger() {
        for raw in [Double.nan, .infinity, -.infinity, -5, 1e300, 2_345.6] {
            let kbps = PlayerStats.sanitisedKbps(raw)
            #expect(Int(exactly: kbps.rounded()) != nil)
        }
    }
}

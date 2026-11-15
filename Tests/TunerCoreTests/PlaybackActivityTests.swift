import Testing
@testable import TunerCore

@Suite struct PlaybackActivityTests {
    @Test func idleNeedsNothing() {
        #expect(PlaybackActivity.needed(for: .idle) == nil)
    }

    @Test func liveStatusesKeepTheDisplayAwake() {
        #expect(PlaybackActivity.needed(for: .starting) == .keepDisplayAwake)
        #expect(PlaybackActivity.needed(for: .playing) == .keepDisplayAwake)
        #expect(PlaybackActivity.needed(for: .reconnecting(attempt: 1)) == .keepDisplayAwake)
        #expect(PlaybackActivity.needed(for: .reconnecting(attempt: 5)) == .keepDisplayAwake)
    }

    @Test func unavailableOnlyAvoidsAppNap() {
        #expect(PlaybackActivity.needed(for: .unavailable) == .avoidAppNap)
    }
}

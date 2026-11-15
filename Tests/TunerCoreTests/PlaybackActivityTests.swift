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

    @Test func hostIsTheHostNameAlone() {
        #expect(StreamHost.name(of: "http://user:secret@example.invalid:8080/live/a/b.ts?token=x") == "example.invalid")
        #expect(StreamHost.name(of: "https://Example.INVALID/x") == "example.invalid")
    }

    @Test func noHostGivesNil() {
        #expect(StreamHost.name(of: "not a url") == nil)
        #expect(StreamHost.name(of: "file:///tmp/a.ts") == nil)
        #expect(StreamHost.name(of: "") == nil)
    }
}

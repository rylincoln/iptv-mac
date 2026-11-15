import Testing
@testable import TunerCore

/// The host is shown with the stream's statistics. Everything else in a stream address may be a
/// credential, so anything that is not plainly a host gives nil.
@Suite struct StreamHostTests {
    @Test func hostIsTheHostNameAlone() {
        #expect(StreamHost.name(of: "http://user:secret@example.invalid:8080/live/a/b.ts?token=x") == "example.invalid")
        #expect(StreamHost.name(of: "https://Example.INVALID/x") == "example.invalid")
        #expect(StreamHost.name(of: "HTTP://example.invalid") == "example.invalid")
        #expect(StreamHost.name(of: "http://a-b.example.invalid?x=1") == "a-b.example.invalid")
        #expect(StreamHost.name(of: "http://192.0.2.1:8080/a") == "192.0.2.1")
        #expect(StreamHost.name(of: "http://user:pw@[2001:DB8::1]:8080/a") == "[2001:db8::1]")
    }

    @Test func noHostGivesNil() {
        #expect(StreamHost.name(of: "not a url") == nil)
        #expect(StreamHost.name(of: "file:///tmp/a.ts") == nil)
        #expect(StreamHost.name(of: "") == nil)
        #expect(StreamHost.name(of: "http://user:pw@/a") == nil)
        #expect(StreamHost.name(of: "http://:8080/a") == nil)
    }

    /// A password holding an unencoded "/", "?" or "#" ends the authority early: what comes before it
    /// is the user name, never the host.
    @Test func unencodedSlashInAPasswordGivesNil() {
        #expect(StreamHost.name(of: "http://user:12/34@example.invalid/live/a") == nil)
        #expect(StreamHost.name(of: "http://user:pa/ss@example.invalid/live/a") == nil)
        #expect(StreamHost.name(of: "http://user:12?34@example.invalid/a") == nil)
        #expect(StreamHost.name(of: "http://user:12#34@example.invalid/a") == nil)
    }

    /// A host is never decoded or guessed at: one that is percent-encoded, or holds anything but
    /// letters, digits, dots and hyphens, or has a port that is not digits, gives nil.
    @Test func encodedOrUnusualHostGivesNil() {
        #expect(StreamHost.name(of: "http://ex%61mple.invalid/a") == nil)
        #expect(StreamHost.name(of: "http://user%40example.invalid/a") == nil)
        #expect(StreamHost.name(of: "http://exa_mple.invalid/a") == nil)
        #expect(StreamHost.name(of: "http://exämple.invalid/a") == nil)
        #expect(StreamHost.name(of: "http://example.invalid:80a/a") == nil)
        #expect(StreamHost.name(of: "http://[2001:db8::1%25en0]/a") == nil)
        #expect(StreamHost.name(of: "http://[2001:db8::1]x/a") == nil)
    }
}

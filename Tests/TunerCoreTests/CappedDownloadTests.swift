import Foundation
import Synchronization
import Testing
@testable import TunerCore

private struct Reply: Sendable {
    var status = 200
    var headers = ["Content-Type": "image/png"]
    var chunks: [Data] = []
    /// Fails the transfer with this after the chunks, instead of finishing it.
    var failure: URLError?
    /// Leaves the transfer open after the chunks, as a server that stops sending would. The session
    /// passes on nothing of a response, not even its status, until it has 512 bytes of the body or
    /// the end of it, so a transfer left open sends more than that.
    var hangs = false
}

/// Routes by URL path, so parallel tests with distinct paths never interfere. Notes which paths it
/// started and which it was told to stop, as a real connection would be closed.
private final class ChunkStub: URLProtocol {
    static let replies = Mutex<[String: Reply]>([:])
    static let started = Mutex<Set<String>>([])
    static let stopped = Mutex<Set<String>>([])

    static func url(_ path: String, _ reply: Reply) -> URL {
        replies.withLock { $0[path] = reply }
        return URL(string: "http://example.invalid\(path)")!
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func stopLoading() {
        let path = request.url?.path ?? ""
        Self.stopped.withLock { _ = $0.insert(path) }
    }

    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.started.withLock { _ = $0.insert(path) }
        let reply = Self.replies.withLock { $0[path] } ?? Reply(status: 404)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in reply.chunks { client?.urlProtocol(self, didLoad: chunk) }
        if let failure = reply.failure {
            client?.urlProtocol(self, didFailWithError: failure)
        } else if !reply.hangs {
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

private func stubSession(wholeTransferLimit: TimeInterval = 60) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ChunkStub.self]
    configuration.timeoutIntervalForResource = wholeTransferLimit
    return URLSession(configuration: configuration)
}

private func bytes(_ count: Int, _ value: UInt8 = 7) -> Data { Data(repeating: value, count: count) }

/// Waits until `condition` holds, or until the test is cancelled by the suite's time limit.
private func waitUntil(_ condition: () -> Bool) async {
    while !condition(), !Task.isCancelled { try? await Task.sleep(for: .milliseconds(1)) }
}

/// The limit the tests download under.
private let limit = 4096

@Suite(.timeLimit(.minutes(1))) struct CappedDownloadTests {
    @Test func aBodyArrivingInChunksIsPutBackTogether() async throws {
        let chunks = [bytes(1000, 1), bytes(2000, 2), bytes(96, 3)]
        let url = ChunkStub.url("/chunks", Reply(chunks: chunks))
        let body = try await CappedDownload.body(from: url, session: stubSession(), limit: limit)
        #expect(body == chunks.reduce(Data(), +))
    }

    @Test func aBodyOfExactlyTheLimitIsKept() async throws {
        let url = ChunkStub.url("/exact", Reply(chunks: [bytes(3000), bytes(1096)]))
        #expect(try await CappedDownload.body(from: url, session: stubSession(), limit: limit) == bytes(limit))
    }

    @Test func oneByteOverTheLimitRefusesTheBodyAndStopsTheTransfer() async throws {
        let url = ChunkStub.url("/over", Reply(chunks: [bytes(3000), bytes(1097)], hangs: true))
        #expect(try await CappedDownload.body(from: url, session: stubSession(), limit: limit) == nil)
        await waitUntil { ChunkStub.stopped.withLock { $0.contains("/over") } }
    }

    @Test func aDeclaredLengthOverTheLimitIsRefusedBeforeAnyBody() async throws {
        let url = ChunkStub.url("/declared", Reply(
            headers: ["Content-Type": "image/png", "Content-Length": "4097"], chunks: [bytes(1000)], hangs: true))
        #expect(try await CappedDownload.body(from: url, session: stubSession(), limit: limit) == nil)
        await waitUntil { ChunkStub.stopped.withLock { $0.contains("/declared") } }
    }

    @Test func aResponseThatIsNotASuccessIsRefused() async throws {
        let url = ChunkStub.url("/missing", Reply(status: 404, chunks: [bytes(3)]))
        #expect(try await CappedDownload.body(from: url, session: stubSession(), limit: limit) == nil)
        let moved = ChunkStub.url("/moved", Reply(status: 304))
        #expect(try await CappedDownload.body(from: moved, session: stubSession(), limit: limit) == nil)
    }

    @Test func anEmptySuccessIsAnEmptyBody() async throws {
        let url = ChunkStub.url("/empty", Reply())
        #expect(try await CappedDownload.body(from: url, session: stubSession(), limit: limit) == Data())
    }

    @Test func aFailedTransferThrowsItsOwnError() async throws {
        let url = ChunkStub.url("/nohost", Reply(chunks: [bytes(2)], failure: URLError(.cannotFindHost)))
        let error = await #expect(throws: URLError.self) {
            try await CappedDownload.body(from: url, session: stubSession(), limit: limit)
        }
        #expect(error?.code == .cannotFindHost)
    }

    /// A logo slower than the session's whole-transfer limit fails as timed out: a failed transfer,
    /// which `UnreachableHost` does not remember.
    @Test func aTransferSlowerThanTheSessionAllowsTimesOut() async throws {
        let url = ChunkStub.url("/slow", Reply(chunks: [bytes(2)], hangs: true))
        let error = await #expect(throws: URLError.self) {
            try await CappedDownload.body(from: url, session: stubSession(wholeTransferLimit: 0.2), limit: limit)
        }
        #expect(error?.code == .timedOut)
        #expect(UnreachableHost.memory(for: error ?? URLError(.unknown)) == nil)
    }

    @Test func cancellingTheCallerCancelsTheTransfer() async throws {
        let url = ChunkStub.url("/cancel", Reply(chunks: [bytes(2)], hangs: true))
        let session = stubSession()
        let download = Task { try await CappedDownload.body(from: url, session: session, limit: limit) }
        await waitUntil { ChunkStub.started.withLock { $0.contains("/cancel") } }
        download.cancel()
        await #expect(throws: CancellationError.self) { try await download.value }
        await waitUntil { ChunkStub.stopped.withLock { $0.contains("/cancel") } }
    }

    @Test func aCallerCancelledBeforeAskingStartsNoTransfer() async throws {
        let url = ChunkStub.url("/early", Reply(chunks: [bytes(2)]))
        let session = stubSession()
        let download = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CappedDownload.body(from: url, session: session, limit: limit)
        }
        await #expect(throws: CancellationError.self) { try await download.value }
        #expect(!ChunkStub.started.withLock { $0.contains("/early") })
    }
}

import Foundation
import Synchronization
import Testing
import zlib
@testable import TunerCore

// MARK: - Stub transport

private struct StubResponse: Sendable {
    var status = 200
    var headers: [String: String] = [:]
    var body = Data()
}

/// Routes by URL path, so parallel tests with distinct paths never interfere.
private final class StubProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) -> StubResponse
    static let routes = Mutex<[String: Handler]>([:])

    static func route(_ path: String, _ handler: @escaping Handler) {
        routes.withLock { $0[path] = handler }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let handler = Self.routes.withLock { $0[request.url?.path ?? ""] }
        let stub = handler?(request) ?? StubResponse(status: 404)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func stubSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    return URLSession(configuration: configuration)
}

// MARK: - Fixtures

private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

private let playlistText = """
    #EXTM3U
    #EXTINF:-1 tvg-id="one.example" group-title="News",One
    http://example.invalid/stream/1
    #EXTINF:-1 group-title="Sport",Two
    http://example.invalid/stream/2
    #EXTINF:-1,Broken
    """

private func xmltvDate(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyyMMddHHmmss"
    return f.string(from: date) + " +0000"
}

private func guideXML(channel: String = "one.example", title: String = "Evening News") -> String {
    let start = xmltvDate(fixedNow)
    let stop = xmltvDate(fixedNow.addingTimeInterval(3600))
    return """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <channel id="\(channel)"><display-name>One</display-name></channel>
          <programme start="\(start)" stop="\(stop)" channel="\(channel)"><title>\(title)</title></programme>
          <programme start="\(start)" channel="\(channel)"><title>No stop</title></programme>
        </tv>
        """
}

private func gzip(_ data: Data) -> Data {
    var stream = z_stream()
    deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 16 + MAX_WBITS, 8, Z_DEFAULT_STRATEGY,
                  ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    defer { deflateEnd(&stream) }
    var input = [UInt8](data)
    var output = [UInt8](repeating: 0, count: Int(deflateBound(&stream, UInt(input.count))) + 64)
    var written = 0
    input.withUnsafeMutableBufferPointer { inBuf in
        output.withUnsafeMutableBufferPointer { outBuf in
            stream.next_in = inBuf.baseAddress
            stream.avail_in = UInt32(inBuf.count)
            stream.next_out = outBuf.baseAddress
            stream.avail_out = UInt32(outBuf.count)
            deflate(&stream, Z_FINISH)
            written = outBuf.count - Int(stream.avail_out)
        }
    }
    return Data(output[0..<written])
}

private func withTempFile<T>(_ data: Data, _ body: (String) async throws -> T) async throws -> T {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("import-test-\(UUID().uuidString)")
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    return try await body(url.path)
}

private func service(_ store: Store, session: URLSession = .shared) -> ImportService {
    ImportService(store: store, session: session, now: { fixedNow })
}

private func source(_ store: Store, _ id: Int64) throws -> SourceRow {
    try #require(try store.sources().first { $0.id == id })
}

// MARK: - Tests

@Suite struct ImportServiceTests {
    @Test func importsPlaylistFromFile() async throws {
        let store = try Store.inMemory()
        try await withTempFile(Data(playlistText.utf8)) { path in
            let id = try store.addSource(kind: .playlist, location: path)
            let outcome = try await service(store).importPlaylist(sourceID: id)
            #expect(outcome == .imported(items: 2, skipped: 1))
            let row = try source(store, id)
            #expect(row.itemCount == 2)
            #expect(row.skippedCount == 1)
            #expect(row.lastError == nil)
            #expect(row.lastRefreshAt == fixedNow)
            #expect(try store.channels(in: .all, at: fixedNow).map(\.name) == ["One", "Two"])
        }
    }

    @Test func importsGuideFromFile() async throws {
        let store = try Store.inMemory()
        try await withTempFile(Data(guideXML().utf8)) { path in
            let id = try store.addSource(kind: .guide, location: path)
            let outcome = try await service(store).importGuide(sourceID: id)
            #expect(outcome == .imported(items: 1, skipped: 1))
            #expect(try source(store, id).lastError == nil)
        }
    }

    @Test func importsGuideFromURLAndStoresETag() async throws {
        let store = try Store.inMemory()
        let body = Data(guideXML().utf8)
        StubProtocol.route("/guide-etag") { _ in StubResponse(headers: ["ETag": "\"v1\""], body: body) }
        let id = try store.addSource(kind: .guide, location: "https://example.invalid/guide-etag?token=SECRET")
        let outcome = try await service(store, session: stubSession()).importGuide(sourceID: id)
        #expect(outcome == .imported(items: 1, skipped: 1))
        let row = try source(store, id)
        #expect(row.etag == "\"v1\"")
        #expect(row.itemCount == 1)
    }

    @Test func sendsIfNoneMatchAndHandles304() async throws {
        let store = try Store.inMemory()
        let body = Data(playlistText.utf8)
        StubProtocol.route("/list-304") { request in
            if request.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"" {
                return StubResponse(status: 304)
            }
            return StubResponse(headers: ["ETag": "\"v1\""], body: body)
        }
        let id = try store.addSource(kind: .playlist, location: "https://example.invalid/list-304")
        let first = ImportService(store: store, session: stubSession(), now: { fixedNow })
        #expect(try await first.importPlaylist(sourceID: id) == .imported(items: 2, skipped: 1))

        let later = fixedNow.addingTimeInterval(600)
        let second = ImportService(store: store, session: stubSession(), now: { later })
        #expect(try await second.importPlaylist(sourceID: id) == .notModified)
        let row = try source(store, id)
        #expect(row.lastRefreshAt == later)
        #expect(row.etag == "\"v1\"")
        #expect(row.itemCount == 2)
        #expect(try store.channels(in: .all, at: fixedNow).count == 2)
    }

    @Test func http500KeepsOldDataAndRecordsError() async throws {
        let store = try Store.inMemory()
        let id = try store.addSource(kind: .playlist, location: "https://example.invalid/list-500")
        try store.replaceChannels(sourceID: id, with: [ParsedChannel(name: "Old", streamURL: "http://example.invalid/old")])
        StubProtocol.route("/list-500") { _ in StubResponse(status: 500) }
        await #expect(throws: ImportError.http(status: 500)) {
            try await service(store, session: stubSession()).importPlaylist(sourceID: id)
        }
        #expect(try source(store, id).lastError == "HTTP 500")
        #expect(try store.channels(in: .all, at: fixedNow).map(\.name) == ["Old"])
    }

    @Test func htmlErrorPageIsNotAPlaylist() async throws {
        let store = try Store.inMemory()
        let id = try store.addSource(kind: .playlist, location: "https://example.invalid/list-html")
        try store.replaceChannels(sourceID: id, with: [ParsedChannel(name: "Old", streamURL: "http://example.invalid/old")])
        StubProtocol.route("/list-html") { _ in
            StubResponse(body: Data("<html><body>Service unavailable</body></html>".utf8))
        }
        await #expect(throws: ImportError.notAPlaylist) {
            try await service(store, session: stubSession()).importPlaylist(sourceID: id)
        }
        #expect(try source(store, id).lastError == "Not a playlist")
        #expect(try store.channels(in: .all, at: fixedNow).map(\.name) == ["Old"])
    }

    @Test func emptyGuideIsNotAGuide() async throws {
        let store = try Store.inMemory()
        let id = try store.addSource(kind: .guide, location: "https://example.invalid/guide-empty")
        try store.replaceGuide(sourceID: id, now: fixedNow) { writer in
            try writer.add(ParsedGuideChannel(id: "old", displayNames: ["Old"]))
        }
        StubProtocol.route("/guide-empty") { _ in StubResponse(body: Data("<tv></tv>".utf8)) }
        await #expect(throws: ImportError.notAGuide) {
            try await service(store, session: stubSession()).importGuide(sourceID: id)
        }
        #expect(try source(store, id).lastError == "Not a guide")
        // The old guide channel survives the rolled-back transaction.
        try store.replaceChannels(sourceID: id, with: [ParsedChannel(name: "Old", tvgID: "old", streamURL: "http://example.invalid/old")])
        #expect(try store.channels(in: .all, at: fixedNow).first?.guideRef != nil)
    }

    @Test func gzippedGuideIsDecompressed() async throws {
        let store = try Store.inMemory()
        let compressed = gzip(Data(guideXML().utf8))
        #expect(compressed.prefix(2) == Data([0x1F, 0x8B]))
        StubProtocol.route("/guide.xml.gz") { _ in StubResponse(body: compressed) }
        let id = try store.addSource(kind: .guide, location: "https://example.invalid/guide.xml.gz")
        let outcome = try await service(store, session: stubSession()).importGuide(sourceID: id)
        #expect(outcome == .imported(items: 1, skipped: 1))
        try await withTempFile(compressed) { path in
            let local = try store.addSource(kind: .guide, location: path)
            #expect(try await service(store).importGuide(sourceID: local) == .imported(items: 1, skipped: 1))
        }
    }

    @Test func latin1PlaylistDecodes() async throws {
        let store = try Store.inMemory()
        let text = "#EXTM3U\n#EXTINF:-1,Caf\u{E9} TV\nhttp://example.invalid/stream/1\n"
        let data = try #require(text.data(using: .isoLatin1))
        try await withTempFile(data) { path in
            let id = try store.addSource(kind: .playlist, location: path)
            _ = try await service(store).importPlaylist(sourceID: id)
            #expect(try store.channels(in: .all, at: fixedNow).map(\.name) == ["Caf\u{E9} TV"])
        }
    }

    @Test func lastErrorNeverContainsTheLocation() async throws {
        let store = try Store.inMemory()
        let cases: [(String, @Sendable (URLRequest) -> StubResponse)] = [
            ("/secret-500", { _ in StubResponse(status: 500) }),
            ("/secret-html", { _ in StubResponse(body: Data("<html></html>".utf8)) }),
            ("/secret-redirect", { _ in
                StubResponse(status: 302, headers: ["Location": "https://example.invalid/moved?token=SECRET"])
            }),
        ]
        for (path, handler) in cases {
            StubProtocol.route(path, handler)
            let id = try store.addSource(kind: .playlist, location: "https://example.invalid\(path)?token=SECRET")
            await #expect(throws: (any Error).self) {
                try await service(store, session: stubSession()).importPlaylist(sourceID: id)
            }
            let error = try #require(try source(store, id).lastError)
            #expect(!error.contains("SECRET"))
            #expect(!error.contains("example.invalid"))
        }
    }

    @Test func missingFileThrowsUnreadable() async throws {
        let store = try Store.inMemory()
        let id = try store.addSource(kind: .playlist, location: "/nonexistent/\(UUID().uuidString)/list.m3u")
        await #expect(throws: ImportError.unreadable) {
            try await service(store).importPlaylist(sourceID: id)
        }
        #expect(try source(store, id).lastError == "Could not read file")
    }
}

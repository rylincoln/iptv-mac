import Foundation

public enum ImportOutcome: Equatable, Sendable {
    case imported(items: Int, skipped: Int)
    case notModified
}

public enum ImportError: Error, Equatable {
    case http(status: Int)
    /// The provider answered "too many requests" (HTTP 429). It is not asked again before `until`.
    case rateLimited(until: Date)
    case notAPlaylist
    case notAGuide
    /// A gzipped guide inflated past `Gunzip.defaultLimit`.
    case tooLarge
    /// The decompressed guide could not be written: the disk is full, say.
    case cannotWrite
    case unreadable
}

/// Fetches a source (file path or http(s) URL), parses it and loads it into the store.
/// Locations carry account tokens, so nothing recorded or thrown here ever includes one.
public struct ImportService: Sendable {
    private let store: Store
    private let session: URLSession
    private let now: @Sendable () -> Date
    /// Where a gzipped guide is decompressed to, for the length of its import.
    private let temporaryDirectory: URL
    /// The most a gzipped guide may inflate to.
    private let decompressedLimit: Int64

    public init(
        store: Store, session: URLSession = .shared, now: @escaping @Sendable () -> Date = Date.init,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.init(
            store: store, session: session, now: now, temporaryDirectory: temporaryDirectory,
            decompressedLimit: Gunzip.defaultLimit)
    }

    init(
        store: Store, session: URLSession = .shared, now: @escaping @Sendable () -> Date = Date.init,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory, decompressedLimit: Int64
    ) {
        self.store = store
        self.session = session
        self.now = now
        self.temporaryDirectory = temporaryDirectory
        self.decompressedLimit = decompressedLimit
    }

    /// Deletes guides left decompressed in `directory` by an import that never finished (the app quit
    /// or crashed part way). Touches only files named as `importGuide` names them. Run it before any
    /// import starts, never while one runs.
    public static func removeLeftoverFiles(in directory: URL = FileManager.default.temporaryDirectory) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where isTemporaryName(name) {
            let path = directory.appendingPathComponent(name).path
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                continue
            }
            try? manager.removeItem(atPath: path)
        }
    }

    public func importPlaylist(sourceID: Int64) async throws -> ImportOutcome {
        try await run(sourceID: sourceID) { file in
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
                throw ImportError.unreadable
            }
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
            let result = M3UParser.parse(text)
            guard !result.channels.isEmpty else { throw ImportError.notAPlaylist }
            try store.replaceChannels(sourceID: sourceID, with: result.channels)
            return (result.channels.count, result.skippedCount, true)
        }
    }

    public func importGuide(sourceID: Int64) async throws -> ImportOutcome {
        try await run(sourceID: sourceID) { file in
            var parseFile = file
            var decompressed: URL?
            defer { if let decompressed { try? FileManager.default.removeItem(at: decompressed) } }
            if try Self.isGzip(file) {
                let out = temporaryURL()
                decompressed = out
                do {
                    try Gunzip.inflate(from: file, to: out, limit: decompressedLimit)
                } catch let failure as Gunzip.Failure {
                    throw Self.importError(for: failure)
                }
                parseFile = out
                try Task.checkCancellation()
            }
            var summary = XMLTVSummary(channels: 0, programmes: 0, skipped: 0)
            let stored = try store.replaceGuide(sourceID: sourceID, now: now()) { writer in
                // Parsing is the longest phase, so each item checks for cancellation: a cancel then
                // rolls the transaction back, and the old guide stays.
                var passThrough: Error?
                do {
                    summary = try XMLTVParser.parse(
                        fileAt: parseFile,
                        onChannel: {
                            do { try Task.checkCancellation(); try writer.add($0) } catch { passThrough = error; throw error }
                        },
                        onProgramme: {
                            do { try Task.checkCancellation(); try writer.add($0) } catch { passThrough = error; throw error }
                        })
                } catch {
                    // A cancellation or a store failure passes through; anything else is a document
                    // that is not XMLTV.
                    throw passThrough ?? ImportError.notAGuide
                }
                // Thrown inside the transaction so the old guide stays.
                if summary.channels == 0 && summary.programmes == 0 { throw ImportError.notAGuide }
            }
            // What was stored: not programmes that had already ended a day ago. A programme whose
            // channel the guide never declared is skipped, as is one the parser could not read.
            // A guide cut off part way keeps what parsed, but not its ETag: a later refresh must
            // download it whole, not be told it is unchanged.
            return (stored.programmes, summary.skipped + stored.programmesWithoutChannel, summary.complete)
        }
    }

    // MARK: - Shared flow

    /// `work` loads the fetched file and says whether it read all of it; only then is the response's
    /// ETag kept.
    private func run(
        sourceID: Int64, work: (URL) throws -> (items: Int, skipped: Int, complete: Bool)
    ) async throws -> ImportOutcome {
        guard let source = try store.sources().first(where: { $0.id == sourceID }) else {
            throw ImportError.unreadable
        }
        // Inside a wait the provider set: the same answer, without asking it again.
        if let retryAt = source.retryAt, retryAt > now() { throw ImportError.rateLimited(until: retryAt) }
        do {
            let fetched = try await fetch(source)
            defer { if let temp = fetched.temporary { try? FileManager.default.removeItem(at: temp) } }
            // Cancelled while downloading: nothing is loaded, and the download is deleted.
            try Task.checkCancellation()
            guard let file = fetched.file else {
                try store.recordRefresh(
                    sourceID: sourceID, etag: source.etag, itemCount: source.itemCount,
                    skippedCount: source.skippedCount, error: nil, at: now())
                return .notModified
            }
            let (items, skipped, complete) = try work(file)
            try store.recordRefresh(
                sourceID: sourceID, etag: complete ? fetched.etag : nil, itemCount: items,
                skippedCount: skipped, error: nil, at: now())
            return .imported(items: items, skipped: skipped)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            var retryAt: Date?
            if case ImportError.rateLimited(let until) = error { retryAt = until }
            try? store.recordRefresh(
                sourceID: sourceID, etag: source.etag, itemCount: source.itemCount,
                skippedCount: source.skippedCount, error: Self.message(for: error), at: now(),
                retryAt: retryAt)
            throw error
        }
    }

    private struct Fetched {
        var file: URL?          // nil means not modified
        var temporary: URL?     // a download to delete afterwards
        var etag: String?
    }

    private func fetch(_ source: SourceRow) async throws -> Fetched {
        let location = source.location
        let lower = location.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else {
            let path = lower.hasPrefix("file://") ? (URL(string: location)?.path ?? location) : location
            guard FileManager.default.isReadableFile(atPath: path) else { throw ImportError.unreadable }
            return Fetched(file: URL(fileURLWithPath: path), temporary: nil, etag: nil)
        }
        guard let url = URL(string: location) else { throw ImportError.unreadable }
        var request = URLRequest(url: url)
        if let etag = source.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }

        let downloaded: URL
        let response: URLResponse
        do {
            (downloaded, response) = try await session.download(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ImportError.unreadable
        }
        guard let http = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: downloaded)
            throw ImportError.unreadable
        }
        if http.statusCode == 304 {
            try? FileManager.default.removeItem(at: downloaded)
            return Fetched(file: nil, temporary: nil, etag: source.etag)
        }
        guard (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: downloaded)
            if http.statusCode == 429 {
                let asked = now()
                let wait = RetryAfter.wait(header: http.value(forHTTPHeaderField: "Retry-After"), now: asked)
                throw ImportError.rateLimited(until: asked.addingTimeInterval(wait))
            }
            throw ImportError.http(status: http.statusCode)
        }
        return Fetched(file: downloaded, temporary: downloaded, etag: http.value(forHTTPHeaderField: "ETag"))
    }

    // MARK: - Helpers

    /// Fixed strings only: never the location, a redirect target or a system error description.
    private static func message(for error: Error) -> String {
        switch error as? ImportError {
        case .http(let status): return "HTTP \(status)"
        case .rateLimited: return "Provider is limiting requests"
        case .notAPlaylist: return "Not a playlist"
        case .notAGuide: return "Not a guide"
        case .tooLarge: return "Guide too large"
        case .cannotWrite: return "Could not write to disk"
        case .unreadable: return "Could not load"  // a missing file, or a failed download
        case nil: return "Import failed"
        }
    }

    private static func importError(for failure: Gunzip.Failure) -> ImportError {
        switch failure {
        case .corrupt: return .notAGuide
        case .tooLarge: return .tooLarge
        case .cannotRead: return .unreadable
        case .cannotWrite: return .cannotWrite
        }
    }

    private static func isGzip(_ file: URL) throws -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { throw ImportError.unreadable }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 2)) ?? Data()
        return head.count == 2 && head[head.startIndex] == 0x1F && head[head.startIndex + 1] == 0x8B
    }

    private static let temporaryPrefix = "tuner-"
    private static let temporarySuffix = ".xml"

    /// Deleted when the import ends, however it ends; `removeLeftoverFiles` sweeps up after one that
    /// never ended.
    private func temporaryURL() -> URL {
        temporaryDirectory.appendingPathComponent(
            "\(Self.temporaryPrefix)\(UUID().uuidString)\(Self.temporarySuffix)")
    }

    /// `tuner-<UUID>.xml`, as `temporaryURL` makes it, and nothing else.
    private static func isTemporaryName(_ name: String) -> Bool {
        guard name.hasPrefix(temporaryPrefix), name.hasSuffix(temporarySuffix) else { return false }
        let middle = name.dropFirst(temporaryPrefix.count).dropLast(temporarySuffix.count)
        return UUID(uuidString: String(middle)) != nil
    }
}

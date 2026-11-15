import Foundation

public enum ImportOutcome: Equatable, Sendable {
    case imported(items: Int, skipped: Int)
    case notModified
}

public enum ImportError: Error, Equatable {
    case http(status: Int)
    case notAPlaylist
    case notAGuide
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

    public init(
        store: Store, session: URLSession = .shared, now: @escaping @Sendable () -> Date = Date.init,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.store = store
        self.session = session
        self.now = now
        self.temporaryDirectory = temporaryDirectory
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
                do { try Gunzip.inflate(from: file, to: out) } catch { throw ImportError.notAGuide }
                parseFile = out
            }
            var summary = XMLTVSummary(channels: 0, programmes: 0, skipped: 0)
            try store.replaceGuide(sourceID: sourceID, now: now()) { writer in
                var storeError: Error?
                do {
                    summary = try XMLTVParser.parse(
                        fileAt: parseFile,
                        onChannel: { do { try writer.add($0) } catch { storeError = error; throw error } },
                        onProgramme: { do { try writer.add($0) } catch { storeError = error; throw error } })
                } catch {
                    // A store failure passes through; anything else is a document that is not XMLTV.
                    throw storeError ?? ImportError.notAGuide
                }
                // Thrown inside the transaction so the old guide stays.
                if summary.channels == 0 && summary.programmes == 0 { throw ImportError.notAGuide }
            }
            // A guide cut off part way keeps what parsed, but not its ETag: a later refresh must
            // download it whole, not be told it is unchanged.
            return (summary.programmes, summary.skipped, summary.complete)
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
        do {
            let fetched = try await fetch(source)
            defer { if let temp = fetched.temporary { try? FileManager.default.removeItem(at: temp) } }
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
            try? store.recordRefresh(
                sourceID: sourceID, etag: source.etag, itemCount: source.itemCount,
                skippedCount: source.skippedCount, error: Self.message(for: error), at: now())
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
            throw ImportError.http(status: http.statusCode)
        }
        return Fetched(file: downloaded, temporary: downloaded, etag: http.value(forHTTPHeaderField: "ETag"))
    }

    // MARK: - Helpers

    /// Fixed strings only: never the location, a redirect target or a system error description.
    private static func message(for error: Error) -> String {
        switch error as? ImportError {
        case .http(let status): return "HTTP \(status)"
        case .notAPlaylist: return "Not a playlist"
        case .notAGuide: return "Not a guide"
        case .unreadable: return "Could not load"  // a missing file, or a failed download
        case nil: return "Import failed"
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

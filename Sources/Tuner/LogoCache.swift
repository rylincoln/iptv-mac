import AppKit
import ImageIO
import Synchronization
import TunerCore

/// Channel logos for the list, small and already decoded.
///
/// Decoded thumbnails, at the size rows draw them, live in a bounded memory cache. The downloaded
/// bytes live in a 200 MB disk `URLCache`, so a relaunch does not fetch them again. Rows asking for a
/// URL already on its way (a channel's HD, FHD and SD variants share a logo) share its one download.
/// At most six downloads run at once; a download is cancelled, in the queue or on the wire, once every
/// row that asked for it has scrolled away.
/// A URL whose response is not a usable logo (not 2xx, too large, or not an image) is a miss and is
/// not tried again this session; one whose transfer failed (offline, timed out) is tried again when
/// its row next shows. Logo URLs come from the playlist and are never logged.
///
/// A download is bounded in memory and time, because the URLs are untrusted: the body is read as a
/// stream and the request is cancelled, closing the connection, as soon as the declared length or the
/// bytes received pass `maxDownloadBytes` (a miss); the whole transfer, however slowly it trickles, is
/// cut off after `timeoutIntervalForResource` (a failed transfer). Either way the download slot is freed.
final class LogoCache: @unchecked Sendable {  // NSCache, Mutex and the actor are thread-safe; the rest is immutable
    /// The size rows draw logos at.
    static let pointSize: CGFloat = 32

    /// Thumbnails are made for the sharpest screen attached at first use.
    @MainActor static let shared = LogoCache(scale: NSScreen.screens.map(\.backingScaleFactor).max() ?? 2)

    private static let memoryLimit = 400        // thumbnails of about 16 KB each
    private static let missLimit = 4_096
    private static let diskBytes = 200 * 1024 * 1024
    private static let maxDownloadBytes = 4 * 1024 * 1024
    private static let maxSourcePixels = 4096 * 4096

    private let images = NSCache<NSString, NSImage>()
    private let misses = Mutex(MissSet(limit: LogoCache.missLimit))
    /// The loads under way, one per URL; each URL is forgotten as its load ends.
    private let loads = SharedWork<String, NSImage?>()
    private let gate = DownloadGate(limit: 6)
    private let session: URLSession
    private let scale: CGFloat
    private let pixelSize: Int

    init(scale: CGFloat) {
        self.scale = scale
        pixelSize = Int((Self.pointSize * scale).rounded(.up))
        images.countLimit = Self.memoryLimit

        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Tuner/Logos", isDirectory: true)
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 0, diskCapacity: Self.diskBytes, directory: directory)
        configuration.requestCachePolicy = .returnCacheDataElseLoad  // logos rarely change; spare the network
        configuration.timeoutIntervalForRequest = 15   // the longest gap between packets
        configuration.timeoutIntervalForResource = 30  // the longest a whole logo may take
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration)
    }

    /// The thumbnail if it is in memory now; never waits.
    func cachedImage(for urlString: String) -> NSImage? {
        images.object(forKey: urlString as NSString)
    }

    /// The logo as a thumbnail `pointSize` across, or nil for no logo. Nil also when the calling task
    /// is cancelled or the transfer fails, neither of which is remembered as a miss.
    @concurrent func image(for urlString: String) async -> NSImage? {
        if let hit = images.object(forKey: urlString as NSString) { return hit }
        if misses.withLock({ $0.contains(urlString) }) { return nil }
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            recordMiss(urlString)
            return nil
        }
        do {
            return try await loads.value(for: urlString) { [self] in try await load(url, urlString: urlString) }
        } catch {
            return nil  // cancelled (the row went away), or the transfer failed: try again next time
        }
    }

    /// Downloads, decodes and keeps one logo, once for every row asking for it meanwhile. Throws when
    /// the transfer fails, or when it is cancelled because every row asking has gone.
    private func load(_ url: URL, urlString: String) async throws -> NSImage? {
        guard let data = try await download(url), let image = thumbnail(from: data) else {
            recordMiss(urlString)  // the server answered, with something that is not a usable logo
            return nil
        }
        images.setObject(image, forKey: urlString as NSString)
        return image
    }

    /// The body of a successful response, or nil for a response that is not 2xx or a body over the
    /// size cap. Throws when cancelled or when the transfer fails (no connection, a timeout), neither
    /// of which says anything about the logo. The download slot is released on every path.
    private func download(_ url: URL) async throws -> Data? {
        try await gate.acquire()
        let body: Data?
        do {
            body = try await fetch(url)
        } catch {
            await gate.release()
            throw error
        }
        await gate.release()
        return body
    }

    /// Reads at most `maxDownloadBytes`. Returning or throwing early drops the byte stream, which
    /// cancels the request and closes the connection.
    private func fetch(_ url: URL) async throws -> Data? {
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        let expected = http.expectedContentLength  // -1 when unknown
        if expected > Self.maxDownloadBytes { return nil }
        var data = Data()
        data.reserveCapacity(expected > 0 ? Int(expected) : 64 * 1024)
        for try await byte in bytes {
            if data.count >= Self.maxDownloadBytes { return nil }  // one more byte than the cap
            data.append(byte)
        }
        return data
    }

    /// Decodes straight to a thumbnail no larger than `pixelSize`, so a full-size logo is never held.
    private func thumbnail(from data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else { return nil }
        // A huge image would need a huge buffer to decode, even for a thumbnail.
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int {
            let pixels = width.multipliedReportingOverflow(by: height)
            if pixels.overflow || pixels.partialValue > Self.maxSourcePixels { return nil }
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale))
    }

    private func recordMiss(_ urlString: String) {
        misses.withLock { $0.insert(urlString) }
    }
}

/// URLs that failed this session. Bounded: when full it starts again empty, so a forgotten failure
/// is at worst tried once more.
private struct MissSet {
    let limit: Int
    private var members: Set<String> = []

    init(limit: Int) { self.limit = limit }

    func contains(_ urlString: String) -> Bool { members.contains(urlString) }

    mutating func insert(_ urlString: String) {
        if members.count >= limit { members.removeAll(keepingCapacity: true) }
        members.insert(urlString)
    }
}

/// Lets `limit` downloads run at once; the rest wait in order. A waiter whose task is cancelled leaves
/// the queue at once, so a fast scroll does not leave visible rows queued behind rows that are gone.
private actor DownloadGate {
    private let limit: Int
    private var running = 0
    private var waiters: [(id: UInt64, continuation: CheckedContinuation<Void, Error>)] = []
    private var nextID: UInt64 = 0

    init(limit: Int) { self.limit = limit }

    /// Returns holding a slot, which the caller must `release`; throws, holding none, if cancelled.
    func acquire() async throws {
        try Task.checkCancellation()
        if running < limit {
            running += 1
            return
        }
        let id = nextID
        nextID &+= 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Hands the slot to the next waiter, or frees it.
    func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancelWaiter(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }  // already given a slot
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

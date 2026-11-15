import Foundation
import Synchronization
import Testing
@testable import TunerCore

// Speed checks at the owner's real data size. They only run in a release build:
//   swift test -c release --filter PerformanceTests
// In a debug build the suite is disabled (the limits are release limits and debug timings are noise).

#if DEBUG
private let isReleaseBuild = false
#else
private let isReleaseBuild = true
#endif

// MARK: - Measuring

private func report(_ name: String, _ value: String) {
    print("PERF \(name) \(value)")
}

private func milliseconds(_ d: Duration) -> Double {
    Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}

@discardableResult
private func time(_ name: String, _ body: () throws -> Void) rethrows -> Double {
    let ms = milliseconds(try ContinuousClock().measure(body))
    report(name, String(format: "%.1f ms", ms))
    return ms
}

/// Median of `runs` timings of `body`, in milliseconds.
private func median(_ name: String, runs: Int, _ body: () throws -> Void) rethrows -> Double {
    var samples: [Double] = []
    for _ in 0..<runs { samples.append(milliseconds(try ContinuousClock().measure(body))) }
    samples.sort()
    let result = samples[samples.count / 2]
    report(name, String(format: "median %.2f ms (min %.2f, max %.2f, runs %d)",
                        result, samples[0], samples[samples.count - 1], runs))
    return result
}

/// Process physical footprint in bytes (what Activity Monitor calls Memory).
private func footprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
}

/// Samples the footprint every few milliseconds on a background thread and keeps the maximum.
private final class PeakSampler: Sendable {
    private let peak = Mutex(0)
    private let running = Mutex(true)
    private let finished = DispatchSemaphore(value: 0)

    init() {
        peak.withLock { $0 = footprint() }
        Thread.detachNewThread { [self] in
            while running.withLock({ $0 }) {
                let now = footprint()
                peak.withLock { $0 = max($0, now) }
                usleep(2000)
            }
            finished.signal()
        }
    }

    func stop() -> Int {
        running.withLock { $0 = false }
        finished.wait()
        let now = footprint()
        return peak.withLock { max($0, now) }
    }
}

private func megabytes(_ bytes: Int) -> Double { Double(bytes) / 1_048_576 }

// MARK: - Synthetic data

private struct Generator {
    var state: UInt64
    mutating func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(bound))
    }
}

private let words = [
    "All", "American", "Action", "Auto", "Atlantic", "Arena", "Academy", "Africa", "Animal", "Art",
    "Best", "Big", "Black", "Breaking", "Bay", "Beyond", "Classic", "College", "Football", "Championship",
    "City", "Cooking", "Crime", "Daily", "Dance", "Day", "Drama", "East", "Evening", "Extreme",
    "Family", "Final", "Game", "Golden", "Great", "Home", "House", "Hockey", "Inside", "Island",
    "Junior", "Late", "Live", "Love", "Magic", "Master", "Match", "Morning", "Movie", "Music",
    "National", "News", "Night", "Ocean", "Open", "Premier", "Prime", "Queen", "Race", "Report",
    "Road", "Rugby", "Soccer", "Special", "Sports", "Story", "Summer", "Super", "Talk", "Tonight",
    "Tour", "Triple", "United", "Valley", "Voice", "Weekend", "West", "Wild", "World", "Zone",
]

private func phrase(_ g: inout Generator, count: Int) -> String {
    (0..<count).map { _ in words[g.next(words.count)] }.joined(separator: " ")
}

/// About `bytes` bytes of prose, built from the vocabulary.
private func prose(_ g: inout Generator, bytes: Int) -> String {
    var text = ""
    while text.utf8.count < bytes { text += words[g.next(words.count)].lowercased() + " " }
    return text.trimmingCharacters(in: .whitespaces) + "."
}

private let groups = [
    "US| ENTERTAINMENT", "US| NEWS", "US| MOVIES", "US| KIDS", "US| MUSIC", "UK| GENERAL",
    "US| SPORTS ESPN", "US| NFL", "US| NBA", "US| COLLEGE FOOTBALL", "CA| GENERAL", "DE| GENERAL",
]

private struct Dataset {
    let m3uText: String
    let channels: [ParsedChannel]
    let guideChannels: [ParsedGuideChannel]
    let programmes: [ParsedProgramme]
    let now: Date

    static let channelCount = 5_000
    static let programmesPerChannel = 16

    /// 5,000 playlist channels and 80,000 programmes (16 on each of 5,000 guide channels) around `now`.
    init(now: Date) {
        self.now = now
        var g = Generator(state: 7)
        var text = "#EXTM3U\n"
        for i in 0..<Self.channelCount {
            let group = groups[i % groups.count]
            // Four in five carry the guide id; the rest can only be matched by name.
            let tvgID = i % 5 == 0 ? "" : " tvg-id=\"g\(i)\""
            let name = i % 7 == 0 ? "ESPN \(i)" : "\(words[g.next(words.count)]) Channel \(i)"
            text += "#EXTINF:-1\(tvgID) tvg-name=\"\(name)\" tvg-logo=\"http://example.invalid/logo/\(i).png\" group-title=\"\(group)\",\(name)\n"
            text += "http://example.invalid/live/\(i).ts\n"
        }
        m3uText = text
        channels = M3UParser.parse(text).channels

        var guide: [ParsedGuideChannel] = []
        var progs: [ParsedProgramme] = []
        progs.reserveCapacity(Self.channelCount * Self.programmesPerChannel)
        for i in 0..<Self.channelCount {
            let name = i % 7 == 0 ? "ESPN \(i)" : channels[i].name
            guide.append(ParsedGuideChannel(id: "g\(i)", displayNames: [name]))
            // Eight hours back to a week ahead: sixteen back-to-back slots, one of them on now.
            var start = now.addingTimeInterval(-3 * 3600 + TimeInterval(g.next(60)) * 60)
            for _ in 0..<Self.programmesPerChannel {
                let length = TimeInterval(30 + g.next(4) * 30) * 60
                let title = g.next(5) == 0 ? "College Football: \(phrase(&g, count: 2))" : phrase(&g, count: 3)
                progs.append(ParsedProgramme(
                    channelID: "g\(i)", start: start, stop: start.addingTimeInterval(length),
                    title: title,
                    subTitle: g.next(5) == 0 ? phrase(&g, count: 3) : nil,
                    desc: prose(&g, bytes: 300),
                    categories: g.next(4) == 0 ? ["Sports"] : []))
                start = start.addingTimeInterval(length + (i % 3 == 0 ? 3600 * 5 : 0))
            }
        }
        guideChannels = guide
        programmes = progs
    }
}

private func loadPlaylist(_ store: Store, _ data: Dataset) throws {
    let id = try store.addSource(kind: .playlist, location: "http://example.invalid/list.m3u")
    try store.replaceChannels(sourceID: id, with: data.channels)
}

private func loadGuide(_ store: Store, _ data: Dataset) throws {
    let id = try store.addSource(kind: .guide, location: "http://example.invalid/guide.xml")
    try store.replaceGuide(sourceID: id, now: data.now) { writer in
        for c in data.guideChannels { try writer.add(c) }
        for p in data.programmes { try writer.add(p) }
    }
}

/// Everything the suite shares, built once.
private struct Fixture: Sendable {
    let directory: URL
    let data: Dataset
    let store: Store          // playlist and guide loaded; read-only for the query tests

    @TaskLocal static var current: Fixture?

    func freshStore(_ name: String) throws -> Store {
        try Store(path: directory.appendingPathComponent("\(name).sqlite").path)
    }
}

private struct SharedFixture: SuiteTrait, TestScoping {
    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        guard isReleaseBuild else { return try await function() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tuner-perf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Dataset(now: Date())
        let store = try Store(path: directory.appendingPathComponent("shared.sqlite").path)
        try loadPlaylist(store, data)
        try loadGuide(store, data)
        try await Fixture.$current.withValue(Fixture(directory: directory, data: data, store: store)) {
            try await function()
        }
    }
}

private func fixture() throws -> Fixture {
    try #require(Fixture.current, "fixture missing")
}

// MARK: - The XMLTV file at real size

private func xmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
}

private func xmltvStamp(_ date: Date) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    return String(format: "%04d%02d%02d%02d%02d%02d +0000",
                  c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
}

/// About 4,100 channels and 80,000 programmes around `now`; written in chunks, never held whole.
private func writeGuideFile(to url: URL, now: Date) throws {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    var g = Generator(state: 99)
    var buffer = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<tv generator-info-name=\"synthetic\">\n"
    func flush(force: Bool = false) throws {
        if force || buffer.utf8.count > 1_000_000 {
            try handle.write(contentsOf: Data(buffer.utf8))
            buffer.removeAll(keepingCapacity: true)
        }
    }
    let channelCount = 4_100
    let perChannel = 80_000 / channelCount          // 19, with the remainder on the first channels
    let extra = 80_000 - perChannel * channelCount
    for i in 0..<channelCount {
        buffer += "<channel id=\"g\(i)\"><display-name>Channel \(i)</display-name>"
        buffer += "<icon src=\"http://example.invalid/icon/\(i).png\"/></channel>\n"
        try flush()
    }
    for i in 0..<channelCount {
        var start = now.addingTimeInterval(-3 * 3600 + TimeInterval(g.next(60)) * 60)
        for j in 0..<(perChannel + (i < extra ? 1 : 0)) {
            let stop = start.addingTimeInterval(TimeInterval(30 + g.next(4) * 30) * 60)
            buffer += "<programme start=\"\(xmltvStamp(start))\" stop=\"\(xmltvStamp(stop))\" channel=\"g\(i)\">"
            buffer += "<title lang=\"en\">\(xmlEscape(phrase(&g, count: 3)))</title>"
            if g.next(5) == 0 { buffer += "<sub-title lang=\"en\">\(xmlEscape(phrase(&g, count: 3)))</sub-title>" }
            buffer += "<desc lang=\"en\">\(xmlEscape(prose(&g, bytes: 300)))</desc>"
            if g.next(2) == 0 { buffer += "<category lang=\"en\">\(g.next(4) == 0 ? "Sports" : "Drama")</category>" }
            buffer += "</programme>\n"
            start = stop
            _ = j
            try flush()
        }
    }
    buffer += "</tv>\n"
    try flush(force: true)
}

private func gzip(_ file: URL, to out: URL) throws {
    FileManager.default.createFile(atPath: out.path, contents: nil)
    let output = try FileHandle(forWritingTo: out)
    defer { try? output.close() }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
    process.arguments = ["-c", file.path]
    process.standardOutput = output
    try process.run()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0, "gzip failed")
}

private func fileMegabytes(_ url: URL) -> Double {
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
    return megabytes(size ?? 0)
}

// MARK: - Tests

@Suite(.serialized, .enabled(if: isReleaseBuild, "performance limits are release-build limits"), SharedFixture())
struct PerformanceTests {
    @Test func playlistImportUnderOneSecond() throws {
        let f = try fixture()
        let store = try f.freshStore("playlist")
        let id = try store.addSource(kind: .playlist, location: "http://example.invalid/list.m3u")
        let ms = try time("playlistImport 5000 channels (parse + replaceChannels)") {
            let parsed = M3UParser.parse(f.data.m3uText)
            try store.replaceChannels(sourceID: id, with: parsed.channels)
        }
        #expect(ms < 1000)
    }

    @Test func guideImportUnderTenSeconds() throws {
        let f = try fixture()
        let store = try f.freshStore("guide")
        try loadPlaylist(store, f.data)
        let ms = try time("guideImport 80000 programmes (replaceGuide, match, index)") {
            try loadGuide(store, f.data)
        }
        #expect(ms < 10_000)
        #expect(try store.channels(in: .all, at: f.data.now).filter { $0.guideRef != nil }.count > 4_000)
    }

    @Test func allChannelsQueryUnder50ms() throws {
        let f = try fixture()
        var count = 0
        let ms = try median("allChannels query", runs: 5) {
            count = try f.store.channels(in: .all, at: f.data.now).count
        }
        #expect(count == Dataset.channelCount)
        #expect(ms < 50)
    }

    @Test func sportsQueryUnder50ms() throws {
        let f = try fixture()
        var count = 0
        let ms = try median("sports query", runs: 5) {
            count = try f.store.channels(in: .sports, at: f.data.now).count
        }
        #expect(count > 0)
        #expect(ms < 50)
    }

    @Test func nowPlayingUnder50ms() throws {
        let f = try fixture()
        var count = 0
        let ms = try median("nowPlaying query", runs: 5) {
            count = try f.store.nowPlaying(at: f.data.now).count
        }
        #expect(count > 0)
        #expect(ms < 50)
    }

    @Test func searchUnder50ms() throws {
        let f = try fixture()
        for term in ["foot", "college football", "espn"] {
            var total = 0
            let ms = try median("search \"\(term)\"", runs: 20) {
                let r = try f.store.search(term, at: f.data.now)
                total = r.onNow.count + r.later.count + r.channels.count
            }
            #expect(total > 0)
            #expect(ms < 50)
        }
    }

    @Test func searchOneLetterUnder50ms() throws {
        let f = try fixture()
        var total = 0
        let ms = try median("search \"a\" (worst case)", runs: 20) {
            let r = try f.store.search("a", at: f.data.now)
            total = r.onNow.count + r.later.count + r.channels.count
        }
        #expect(total > 0)
        #expect(ms < 50)
    }

    @Test func playlistReimportUnderOneSecond() throws {
        let f = try fixture()
        let store = try f.freshStore("reimport")
        try loadPlaylist(store, f.data)
        try loadGuide(store, f.data)
        let rows = try store.channels(in: .all, at: f.data.now)
        for row in rows.prefix(60) { try store.setFavourite(true, channelID: row.id) }
        for row in rows.suffix(40) { try store.recordWatched(channelID: row.id, at: f.data.now) }
        let id = try #require(try store.sources().first { $0.kind == .playlist }).id
        let ms = try time("playlistReimport 5000 channels over existing data") {
            let parsed = M3UParser.parse(f.data.m3uText)
            try store.replaceChannels(sourceID: id, with: parsed.channels)
        }
        #expect(ms < 1000)
        #expect(try store.channels(in: .favourites, at: f.data.now).count == 60)
    }

    // Peak memory growth ceilings (MB), about 1.5x the growth measured on the 38 MB file: the file is
    // streamed, so growth stays near the file size (SQLite cache and index rebuild), not a multiple of it.
    private func importGuideFile(
        _ name: String, file: URL, f: Fixture, secondsLimit: Double, memoryCeilingMB: Double
    ) async throws {
        let store = try f.freshStore("scale-\(name)")
        try loadPlaylist(store, f.data)
        let source = try store.addSource(kind: .guide, location: file.path)
        let service = ImportService(store: store)
        let before = footprint()
        let sampler = PeakSampler()
        let start = ContinuousClock.now
        let outcome = try await service.importGuide(sourceID: source)
        let ms = milliseconds(ContinuousClock.now - start)
        let peak = sampler.stop()
        let growth = megabytes(peak - before)
        report("guideScale \(name)", String(
            format: "%.0f ms, file %.1f MB, footprint before %.1f MB, peak %.1f MB, growth %.1f MB",
            ms, fileMegabytes(file), megabytes(before), megabytes(peak), growth))
        guard case .imported(let items, _) = outcome else { Issue.record("not imported"); return }
        #expect(items == 80_000)
        #expect(ms < secondsLimit * 1000)
        #expect(growth < memoryCeilingMB)
    }

    @Test func guideParseAndImportAtScale() async throws {
        let f = try fixture()
        let file = f.directory.appendingPathComponent("guide.xml")
        try writeGuideFile(to: file, now: Date())
        try await importGuideFile("plain", file: file, f: f, secondsLimit: 10, memoryCeilingMB: 100)
    }

    @Test func guideParseAndImportAtScaleGzipped() async throws {
        let f = try fixture()
        let file = f.directory.appendingPathComponent("guide-gz.xml")
        try writeGuideFile(to: file, now: Date())
        let gz = f.directory.appendingPathComponent("guide.xml.gz")
        try gzip(file, to: gz)
        try FileManager.default.removeItem(at: file)
        try await importGuideFile("gzip", file: gz, f: f, secondsLimit: 10, memoryCeilingMB: 110)
    }
}

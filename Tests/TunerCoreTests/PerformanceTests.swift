import Foundation
import Synchronization
import GRDB
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
    guard result == KERN_SUCCESS else {
        Issue.record("task_info failed (\(result)); memory numbers are not trustworthy")
        return 0
    }
    return Int(info.phys_footprint)
}

/// Footprint after asking malloc to return free pages, so heap left over from earlier work
/// cannot hide growth in the work being measured.
private func settledFootprint() -> Int {
    malloc_zone_pressure_relief(nil, 0)
    return footprint()
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

// A seeded pseudo-vocabulary of 25,000 distinct words. Words start with English-like first letters
// and common digraphs ("th", "co", "st"...), and are drawn with Zipf frequency (rank r has weight 1/r),
// so a short prefix expands to thousands of index terms, as in a real guide. The words the other
// tests search for sit at plausible ranks.
private let vocabularySize = 25_000

private let vocabulary: [String] = {
    var g = Generator(state: 12345)
    let starts: [Character: [String]] = [
        "t": ["th", "to", "tr", "ta", "te", "ti"], "a": ["an", "al", "ar", "at", "ab", "ac"],
        "o": ["on", "or", "ov", "of"], "i": ["in", "im", "is"], "s": ["st", "sp", "se", "sh", "su", "sa", "so"],
        "w": ["wh", "wa", "wi", "wo"], "c": ["co", "ch", "ca", "ce", "cr"], "b": ["be", "br", "bo", "ba"],
        "p": ["pr", "pa", "pe", "po", "pl"], "h": ["ha", "he", "ho", "hi"], "f": ["fo", "fr", "fi", "fa"],
        "m": ["ma", "me", "mo", "mi"], "d": ["de", "di", "do", "da"], "r": ["re", "ro", "ra"],
        "l": ["li", "le", "la", "lo"], "e": ["en", "ex", "el"], "n": ["no", "ne", "na"],
        "g": ["ga", "go", "gr", "ge"],
    ]
    // First-letter weights per thousand words, roughly English.
    let firstLetters = "tttttttttttttttt" + "aaaaaaaaaaaa" + "ssssssssssss" + "cccccccccc" + "pppppppppp"
        + "bbbbbbbb" + "mmmmmmmm" + "ffffffff" + "wwwwwwww" + "hhhhhhhh" + "oooooooo" + "iiiiiii"
        + "dddddd" + "rrrrrr" + "llllll" + "eeeee" + "nnnnn" + "gggg" + "ukjvyq"
    let first = Array(firstLetters)
    let vowels = Array("aeiouaeioe"), consonants = Array("tnrslcdmphbfgwy")
    var seen = Set<String>(), result: [String] = []
    while result.count < vocabularySize {
        let letter = first[g.next(first.count)]
        var word: String
        if let options = starts[letter], g.next(100) < 85 {
            word = options[g.next(options.count)]
        } else {
            word = String(letter) + String(vowels[g.next(vowels.count)])
        }
        for _ in 0..<(1 + g.next(6)) {
            word.append(g.next(2) == 0 ? consonants[g.next(consonants.count)] : vowels[g.next(vowels.count)])
        }
        if seen.insert(word).inserted { result.append(word) }
    }
    for (rank, word) in [(10, "news"), (15, "sports"), (40, "live"), (120, "college"), (150, "football"),
                         (300, "espn"), (500, "soccer"), (900, "footage")] {
        result[rank] = word
    }
    return result
}()

/// A Zipf-distributed word: rank r is drawn with probability proportional to 1/r.
private func zipfWord(_ g: inout Generator) -> String {
    let u = Double(g.next(1_000_000)) / 1_000_000
    return vocabulary[min(vocabularySize - 1, Int(pow(Double(vocabularySize), u)) - 1)]
}

private func capitalised(_ word: String) -> String { word.prefix(1).uppercased() + word.dropFirst() }

private func phrase(_ g: inout Generator, count: Int) -> String {
    (0..<count).map { _ in capitalised(zipfWord(&g)) }.joined(separator: " ")
}

/// About `bytes` bytes of prose, built from the vocabulary.
private func prose(_ g: inout Generator, bytes: Int) -> String {
    var text = ""
    while text.utf8.count < bytes { text += zipfWord(&g) + " " }
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
            let name = i % 7 == 0 ? "ESPN \(i)" : "\(capitalised(zipfWord(&g))) Channel \(i)"
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

/// About 4,100 channels and `programmes` programmes (80,000 by default) around `now`; written in chunks, never held whole.
private func writeGuideFile(to url: URL, now: Date, programmes: Int = 80_000) throws {
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
    let perChannel = programmes / channelCount          // 19 at 80,000, with the remainder on the first channels
    let extra = programmes - perChannel * channelCount
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
    // The memory tests are declared first so they run before the others have churned the heap, and
    // they return freed heap to the system before taking their baseline (see `settledFootprint`).

    /// Imports `file` into a fresh store and returns the peak growth in MB.
    @discardableResult
    private func importGuideFile(
        _ name: String, file: URL, f: Fixture, programmes: Int = 80_000, secondsLimit: Double = 10,
        memoryCeilingMB: Double? = nil
    ) async throws -> Double {
        let store = try f.freshStore("scale-\(name)")
        try loadPlaylist(store, f.data)
        let source = try store.addSource(kind: .guide, location: file.path)
        let service = ImportService(store: store)
        let before = settledFootprint()
        let sampler = PeakSampler()
        let start = ContinuousClock.now
        let outcome = try await service.importGuide(sourceID: source)
        let ms = milliseconds(ContinuousClock.now - start)
        let peak = sampler.stop()
        let growth = megabytes(peak - before)
        report("guideScale \(name)", String(
            format: "%.0f ms, file %.1f MB, footprint before %.1f MB, peak %.1f MB, growth %.1f MB",
            ms, fileMegabytes(file), megabytes(before), megabytes(peak), growth))
        try? FileManager.default.removeItem(at: f.directory.appendingPathComponent("scale-\(name).sqlite"))
        guard case .imported(let items, _) = outcome else { Issue.record("not imported"); return growth }
        #expect(items == programmes)
        #expect(ms < secondsLimit * 1000)
        if let memoryCeilingMB { #expect(growth < memoryCeilingMB) }
        return growth
    }

    /// Four times the data must not cost anything like four times the memory: that is what
    /// streaming means. A parser or writer that kept every programme would roughly quadruple it.
    private func checkMemoryDoesNotScale(gzipped: Bool) async throws {
        let f = try fixture()
        let label = gzipped ? "gzip" : "plain"
        var growth: [Int: Double] = [:]
        for programmes in [4_000, 40_000, 160_000] {   // the first is a warm-up
            var file = f.directory.appendingPathComponent("guide-\(programmes).xml")
            try writeGuideFile(to: file, now: Date(), programmes: programmes)
            if gzipped {
                let gz = f.directory.appendingPathComponent("guide-\(programmes).xml.gz")
                try gzip(file, to: gz)
                try FileManager.default.removeItem(at: file)
                file = gz
            }
            growth[programmes] = try await importGuideFile(
                "\(label)-n\(programmes)", file: file, f: f, programmes: programmes, secondsLimit: 40)
            try FileManager.default.removeItem(at: file)
        }
        let small = try #require(growth[40_000]), large = try #require(growth[160_000])
        report("memoryScaling \(label)", String(
            format: "growth 40k %.1f MB, 160k %.1f MB, ratio %.2f (limit 1.5)", small, large, large / max(small, 0.1)))
        #expect(large < small * 1.5)
    }

    @Test func guideImportMemoryDoesNotScaleWithFileSize() async throws {
        try await checkMemoryDoesNotScale(gzipped: false)
    }

    @Test func guideImportMemoryDoesNotScaleWithGzipFileSize() async throws {
        try await checkMemoryDoesNotScale(gzipped: true)
    }

    @Test func guideParseAndImportAtScale() async throws {
        let f = try fixture()
        let file = f.directory.appendingPathComponent("guide.xml")
        try writeGuideFile(to: file, now: Date())
        try await importGuideFile("plain", file: file, f: f, memoryCeilingMB: 13)
    }

    @Test func guideParseAndImportAtScaleGzipped() async throws {
        let f = try fixture()
        let file = f.directory.appendingPathComponent("guide-gz.xml")
        try writeGuideFile(to: file, now: Date())
        let gz = f.directory.appendingPathComponent("guide.xml.gz")
        try gzip(file, to: gz)
        try FileManager.default.removeItem(at: file)
        try await importGuideFile("gzip", file: gz, f: f, memoryCeilingMB: 13)
    }

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

    @Test func largePlaylistParsesQuickly() {
        var text = "#EXTM3U\n"
        for i in 0..<4000 {
            text += "#EXTINF:-1 tvg-id=\"id\(i)\" tvg-name=\"Name \(i)\" tvg-logo=\"https://example.invalid/\(i).png\" group-title=\"G\(i % 20)\",Name \(i)\nhttps://example.invalid/live/\(i)\n"
        }
        var result = M3UParseResult(channels: [], skippedCount: 0)
        let ms = time("playlistParse 4000 channels") { result = M3UParser.parse(text) }
        #expect(result.channels.count == 4000)
        #expect(ms < 100)
    }

    @Test func guideImportUnderTenSeconds() throws {
        let f = try fixture()
        let store = try f.freshStore("guide")
        try loadPlaylist(store, f.data)
        let ms = try time("guideImport 80000 programmes (replaceGuide, match, index)") {
            try loadGuide(store, f.data)
        }
        #expect(ms < 10_000)
        try store.db.writeWithoutTransaction { try $0.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
        let size = (try? FileManager.default.attributesOfItem(
            atPath: f.directory.appendingPathComponent("guide.sqlite").path)[.size] as? Int) ?? nil
        report("databaseFile after guide import", String(format: "%.1f MB", megabytes(size ?? 0)))
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

    @Test func searchTwoLetterPrefixUnder50ms() throws {
        let f = try fixture()
        for prefix in ["th", "co"] {
            let terms = vocabulary.filter { $0.hasPrefix(prefix) }.count
            var total = 0
            let ms = try median("search \"\(prefix)\" (\(terms) vocabulary words)", runs: 20) {
                let r = try f.store.search(prefix, at: f.data.now)
                total = r.onNow.count + r.later.count + r.channels.count
            }
            #expect(total > 0)
            #expect(ms < 50)
        }
    }

    @Test func playlistReimportUnderOneSecond() throws {
        let f = try fixture()
        let store = try f.freshStore("reimport")
        try loadPlaylist(store, f.data)
        try loadGuide(store, f.data)
        let rows = try store.channels(in: .all, at: f.data.now)
        for row in rows.prefix(60) { try store.setFavourite(true, streamURL: row.streamURL, name: row.name) }
        for row in rows.suffix(40) { try store.recordWatched(streamURL: row.streamURL, name: row.name, at: f.data.now) }
        let id = try #require(try store.sources().first { $0.kind == .playlist }).id
        let ms = try time("playlistReimport 5000 channels over existing data") {
            let parsed = M3UParser.parse(f.data.m3uText)
            try store.replaceChannels(sourceID: id, with: parsed.channels)
        }
        #expect(ms < 1000)
        #expect(try store.channels(in: .favourites, at: f.data.now).count == 60)
    }
}

# Tuner — Plan 1: Spikes and the Watchable App

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Settle the two engine/casting unknowns, then deliver a native three-pane Mac app that imports an M3U playlist and an XMLTV guide, lists channels with what is on now, searches channels and programmes, and plays through VLCKit with self-managing reconnects.

**Architecture:** One Swift package at the repo root. `TunerCore` is a pure library (parsing, matching, SQLite store, search, playback supervisor) with no UI and no VLCKit, fully covered by `swift test`. `Tuner` is a SwiftUI executable that depends on `TunerCore` and the vendored VLCKit binary and is wrapped into `Tuner.app` by a script. The app talks to playback only through the `Player` protocol defined in `TunerCore`.

**Tech Stack:** Swift 6.4 toolchain (Command Line Tools only; **full Xcode is not installed and is expected not to be needed — see Global Constraints**), SwiftPM, Swift Testing, SwiftUI + AppKit, GRDB.swift 7.x over system SQLite with FTS5, VLCKit 3.x prebuilt xcframework, `ffprobe` (already installed) for the format spike.

**Spec:** `docs/superpowers/specs/2026-11-14-iptv-mac-client-design.md` — read it first; section numbers below refer to it.

**This is plan 1 of 4.** It covers spec section 10's spikes and its first four build steps. Later plans, each written after this one lands: (2) Guide view — events and grid; (3) Sources screen and background refresh; (4) Google Cast, which depends on the spike results recorded here. Apple TV / AirPlay casting is deferred until the owner has an Apple TV on the network; it gets its own plan then and nothing here builds or tests it.

## Global Constraints

- The provider allows **two simultaneous connections**. Nothing in this plan may hold more than **one** stream open at a time: stop the current stream before opening the next, in spikes and in the app.
- Reconnects are spaced at least 1 second apart, always.
- Playlist files, stream URLs and guide URLs embed account credentials. Never commit them, never print or log a full URL (host name only), never put one in a test, a doc, a commit message or a spike note. `sample_files/` and `*.m3u*` are git-ignored; keep it that way.
- Test fixtures are synthetic, written inline in the tests. Use the host `example.invalid`.
- No AI attribution anywhere: no co-author trailers, no "generated with" lines, in commits, code or docs.
- Current macOS only: `platforms: [.macOS(.v26)]`. Apple silicon.
- Build with `swift build` / `swift test` only. Do not add an `.xcodeproj`. This Mac has Apple's Command Line Tools but not Xcode; that combination is expected to be enough but has not been proven for this project. If Task 2 cannot link VLCKit, or Task 4 cannot run `swift test`, for a reason that only Xcode would fix, stop and tell the owner rather than working around it.
- `TunerCore` must not import SwiftUI, AppKit or VLCKit.
- No settings UI for playback. No captions/audio-track UI. No casting code in this plan, and no AirPlay or `AVPlayer` code at all.
- Times are stored as UTC Unix seconds and displayed in the Mac's local time zone.
- Commit after every task with a short imperative subject prefixed by the area, e.g. `m3u: parse quoted attributes`.

## Review Focus

Each of these has a test in the task named.

1. **Playlist text as it arrives in the wild** — CRLF line endings, a UTF-8 BOM, blank lines, an `#EXTINF` with no URL after it, a comma inside a quoted attribute. Expect: every well-formed entry imported, bad ones counted and skipped, no crash. (Task 4)
2. **Guide programmes with bad times** — missing `stop`, `stop` not after `start`, a non-UTC offset such as `-0500`, an unparseable stamp. Expect: bad ones skipped and counted, offsets converted correctly. (Task 5)
3. **Search text with characters the full-text engine treats as syntax** — `texas a&m`, `"`, `-`, `*`, `:`, `(`, a lone space, emoji. Expect: no error, sensible or empty results. (Task 9)
4. **Re-importing a playlist that changed** — a favourite's stream URL replaced, a favourite removed altogether, two channels sharing a name, two entries sharing a URL. Expect: favourites and recents follow by URL then by unambiguous name, vanish quietly otherwise, and duplicates import without error. (Task 7)
5. **The Mac sleeping or losing network mid-play** — a long gap between supervisor ticks, or every retry failing for minutes. Expect: a wake-up gap does not count as a stall storm or burn the retry budget; sustained failure ends in "unavailable" and stops making connections. (Task 11)

---

## File Structure

```
Package.swift
scripts/fetch-vlckit.sh          downloads the pinned VLCKit xcframework into Vendor/
scripts/bundle.sh                wraps the built executable into build/Tuner.app
Vendor/                          git-ignored; VLCKit.xcframework lives here
Resources/Info.plist             app bundle plist
spikes/                          throwaway code, deleted in Task 3
docs/spikes/2026-11-spike-results.md
Sources/TunerCore/
  Models.swift                   ParsedChannel, ParsedGuideChannel, ParsedProgramme, row types, Section
  M3UParser.swift
  XMLTVParser.swift              XMLTVParser, XMLTVTime
  Matcher.swift                  NameNormalizer, Matcher, MatchKind
  SportsClassifier.swift
  Store/Store.swift              open, migrations, schema
  Store/Store+Channels.swift     playlist import, sections, favourites, recents, buffer memory
  Store/Store+Guide.swift        guide import, now/next, prune, rematch
  Store/Store+Search.swift
  ImportService.swift            fetch + parse + store, ETag handling
  Playback/Player.swift          Player protocol, PlayerState, PlayerStats
  Playback/PlaybackSupervisor.swift
Sources/Tuner/
  TunerApp.swift                 @main, window, menu commands
  AppModel.swift                 @Observable state: section, rows, selection, search, status
  VLCPlayer.swift                Player implementation on VLCKit
  VideoView.swift                NSViewRepresentable hosting the VLC drawable
  LogoCache.swift
  Views/SidebarView.swift
  Views/ChannelListView.swift
  Views/PlayerPaneView.swift
  Views/SearchResultsView.swift
  Views/StatsOverlay.swift
Tests/TunerCoreTests/            one file per source file above
```

---

## Part A — Spikes (throwaway)

Spike code gets no tests, lives in `spikes/`, and is deleted at the end of Task 3. Only the results file is kept. Task 2 needs the owner at the Mac with the Shield switched on; Task 1 does not. There is no Apple TV on the network, so nothing here touches AirPlay.

### Task 1: Spike — what format are the streams?

**Files:**
- Create: `docs/spikes/2026-11-spike-results.md`

- [ ] **Step 1: Copy the sample playlist into this repo's ignored folder**

```bash
mkdir -p sample_files && cp /Users/ry/repos/vlc/sample_files/*.m3u sample_files/ && git status --short
```
Expected: `sample_files/` does not appear in `git status`.

- [ ] **Step 2: Probe three channels, one at a time**

Pick the first entry, one from the "United States" group, and one whose URL path ends in digits (459 entries do). For each, run both commands and let each finish before the next starts:

```bash
curl -sS -m 15 -o /dev/null -D - -r 0-2047 "$URL" | grep -iE '^HTTP|content-type|location'
ffprobe -v error -rw_timeout 15000000 -show_entries format=format_name:stream=codec_type,codec_name,width,height,avg_frame_rate -of json "$URL"
```
Run them from a shell script that reads the URL from the playlist by line number, so no URL is typed into, or echoed by, the terminal.

- [ ] **Step 3: Record results**

In `docs/spikes/2026-11-spike-results.md`, under a heading "Stream format", write for each probe: which group it came from, HTTP status and content type, whether there was a redirect (host only), container (`hls` / `mpegts` / other), video and audio codec, resolution, frame rate. No URLs, no tokens.

- [ ] **Step 4: Commit**

```bash
git add docs/spikes .gitignore && git commit -m "spikes: record stream format probe"
```

### Task 2: Spike — VLCKit playback and Google Cast on this Mac

**Files:**
- Create: `scripts/fetch-vlckit.sh`, `spikes/vlckit/Package.swift`, `spikes/vlckit/Sources/main.swift`
- Modify: `.gitignore` (add `Vendor/`), `docs/spikes/2026-11-spike-results.md`

- [ ] **Step 1: Write `scripts/fetch-vlckit.sh`**

It downloads the newest **VLCKit 3.x macOS** release archive from VideoLAN's own distribution (`https://download.videolan.org/pub/cocoapods/prod/`, file name beginning `VLCKit-3.`; not MobileVLCKit, not a third-party mirror), verifies it against a SHA-256 pinned in the script, and unpacks so that `Vendor/VLCKit.xcframework` exists. If the release ships a plain `.framework` instead of an `.xcframework`, do not try to convert it (`xcodebuild` is not installed); reference the framework through `linkerSettings: [.unsafeFlags(["-F", "Vendor"]), .linkedFramework("VLCKit")]` and note that in the results file. The script is idempotent: a second run with the framework present and the checksum file matching does nothing.

- [ ] **Step 2: Minimal player**

`spikes/vlckit` is a SwiftPM executable depending on the vendored VLCKit. `main.swift` creates an `NSApplication` with `.regular` activation policy and one 960×540 window whose content view is the VLC drawable, plays the URL read from the file path given in `argv[1]` (a one-line text file, so the URL is never on the command line), and prints player state changes. Media option: `:network-caching=1000`.

Run: `swift run --package-path spikes/vlckit vlckit-spike /path/to/one-url.txt`
Expected: picture and sound within a few seconds.

- [ ] **Step 3: Read playback statistics**

Every second, print the playback position and the displayed-picture, decoded-audio and lost-picture counters from the media's statistics. Note the exact VLCKit property names that work; Task 12 needs them.

- [ ] **Step 4: Renderer discovery and cast**

Start every renderer discoverer VLCKit lists, print each renderer's name and type as it appears, and when `argv[2]` matches a renderer name, set it as the player's renderer before playing. macOS will ask for local-network access for the terminal; the owner allows it.

Expected: the Shield is listed; with its name passed, the channel plays on the TV. Stop the local stream before starting the cast run (one connection at a time).

- [ ] **Step 5: Stall behaviour**

While playing locally, turn Wi-Fi off for 20 seconds and back on. Record what the player reports (state changes, whether counters freeze, whether it recovers on its own). This calibrates the watchdog in Task 11.

- [ ] **Step 6: Record results and apply the spec's fallback rules**

Under "VLCKit and Google Cast" in the results file: VLCKit version and checksum, how it is linked, working statistics property names, time-to-picture, Shield found yes/no, cast worked yes/no, stall observations.

- If VLCKit 3.x will not link or render: repeat Steps 1–4 with the prebuilt VLCKit 4 package, and record which one works.
- If playback works but Cast discovery or casting does not: record it and continue; plan 4 will not be written until the owner has chosen what to do.
- Never start building libVLC from source.

- [ ] **Step 7: Commit**

```bash
git add scripts/fetch-vlckit.sh .gitignore docs/spikes && git commit -m "spikes: record VLCKit and Google Cast results"
```

### Task 3: Remove the spike code and report

**Files:**
- Modify: `docs/spikes/2026-11-spike-results.md`
- Delete: `spikes/`

- [ ] **Step 1: Add a note for the later Apple TV work**

Under a heading "Apple TV (deferred)" in the results file, one or two lines: given the container format found in Task 1, whether Apple's player is likely to accept these streams (HLS: likely; raw MPEG-TS: unlikely), and that it has not been tested because no Apple TV was available.

- [ ] **Step 2: Delete the spikes and commit**

```bash
rm -rf spikes
git add -A docs/spikes && git commit -m "spikes: finish results, remove spike code"
```

- [ ] **Step 3: STOP — report to the owner**

Summarise the results file in a few lines. Continue to Part B without waiting only if VLCKit playback worked (3.x or 4). If neither VLCKit plays the owner's streams, stop here entirely. If playback works but casting to the Shield did not, say so plainly; that does not block Part B.

---

## Part B — Core library

### Task 4: Package and the playlist parser

**Files:**
- Create: `Package.swift`, `Sources/TunerCore/Models.swift`, `Sources/TunerCore/M3UParser.swift`, `Tests/TunerCoreTests/M3UParserTests.swift`

**Interfaces — Produces:**

```swift
public struct ParsedChannel: Equatable, Sendable {
    public var name: String            // text after the last unquoted comma, trimmed
    public var tvgID: String?          // nil when absent or empty
    public var tvgName: String?
    public var logoURL: String?
    public var groupTitle: String?     // group-title attribute, else the last #EXTGRP before the URL
    public var streamURL: String
    public var extraAttributes: [String: String]   // every other key="value", verbatim
}
public struct M3UParseResult: Equatable, Sendable {
    public var channels: [ParsedChannel]
    public var skippedCount: Int       // #EXTINF with no URL, or a URL line that is not http(s)/file/rtsp/rtp/udp
}
public enum M3UParser { public static func parse(_ text: String) -> M3UParseResult }
```

- [ ] **Step 1: Create `Package.swift`**

Products: library `TunerCore`. Targets: `TunerCore` (Swift 6 language mode, depends on `GRDB` from `https://github.com/groue/GRDB.swift` `from: "7.0.0"`), test target `TunerCoreTests`. `platforms: [.macOS(.v26)]`. The `Tuner` executable target is added in Task 12.

- [ ] **Step 2: Write the failing tests** (Swift Testing, `import Testing`)

```swift
@Test func parsesStandardEntry() {
    let r = M3UParser.parse("""
    #EXTM3U
    #EXTINF:-1 tvg-id="espn.us" tvg-name="US: ESPN" tvg-logo="https://example.invalid/espn.png" group-title="US Sports",US: ESPN
    https://example.invalid/a/b/c
    """)
    #expect(r.skippedCount == 0)
    #expect(r.channels == [ParsedChannel(name: "US: ESPN", tvgID: "espn.us", tvgName: "US: ESPN",
        logoURL: "https://example.invalid/espn.png", groupTitle: "US Sports",
        streamURL: "https://example.invalid/a/b/c", extraAttributes: [:])])
}
@Test func emptyTvgIDBecomesNil()            // tvg-id="" → tvgID == nil
@Test func commaInsideQuotedAttribute()      // tvg-name="News, Weather" ,Local 5 → name "Local 5", tvgName "News, Weather"
@Test func unknownAttributesAreKept()        // catchup="default" tvg-chno="12" → extraAttributes
@Test func extgrpSuppliesGroupWhenAttributeMissing()
@Test func nameFallsBackToTvgNameThenURLHost() // "#EXTINF:-1," with empty title
@Test func crlfAndBOMAndBlankLines()         // "\u{FEFF}#EXTM3U\r\n\r\n#EXTINF…\r\nhttps://…\r\n" → 1 channel
@Test func extinfWithoutURLIsSkipped()       // two #EXTINF in a row → 1 channel, skippedCount 1
@Test func bareURLWithoutExtinfIsImported()  // name = last path component
@Test func nonURLLineIsSkipped()             // "not a url" after #EXTINF → skippedCount 1
@Test func duplicateURLsAreBothKept()
@Test func missingHeaderStillParses()        // no #EXTM3U line
@Test func emptyInput()                      // "" → no channels, skippedCount 0
```

- [ ] **Step 3: Run** `swift test --filter M3UParserTests` — expected: fails to compile (`M3UParser` undefined).

- [ ] **Step 4: Implement `M3UParser.parse`** — a single pass over lines with a small hand-written scanner for `key="value"` pairs; no regular expressions on the hot path (4,000+ lines must parse in well under 100 ms).

- [ ] **Step 5: Run** `swift test --filter M3UParserTests` — expected: all pass.

- [ ] **Step 6: Commit** — `git add Package.swift Sources Tests && git commit -m "m3u: add playlist parser"`

### Task 5: Guide parser

**Files:**
- Create: `Sources/TunerCore/XMLTVParser.swift`, `Tests/TunerCoreTests/XMLTVParserTests.swift`
- Modify: `Sources/TunerCore/Models.swift`

**Interfaces — Produces:**

```swift
public struct ParsedGuideChannel: Equatable, Sendable { public var id: String; public var displayNames: [String]; public var iconURL: String? }
public struct ParsedProgramme: Equatable, Sendable {
    public var channelID: String; public var start: Date; public var stop: Date
    public var title: String; public var subTitle: String?; public var desc: String?; public var categories: [String]
}
public struct XMLTVSummary: Equatable, Sendable { public var channels: Int; public var programmes: Int; public var skipped: Int }
public enum XMLTVTime { public static func parse(_ s: String) -> Date? }   // "YYYYMMDDHHMMSS", optional " ±HHMM"; no offset means UTC
public enum XMLTVParser {
    /// Streams the file; never holds the whole document in memory. Throws only if the file cannot be opened
    /// or the XML is broken before any element was delivered; a truncated tail ends the parse with what was read.
    public static func parse(fileAt url: URL,
                             onChannel: (ParsedGuideChannel) throws -> Void,
                             onProgramme: (ParsedProgramme) throws -> Void) throws -> XMLTVSummary
}
```

- [ ] **Step 1: Write the failing tests** (each writes its XML to a temp file)

```swift
@Test func timeUTC()            { #expect(XMLTVTime.parse("20261114170000 +0000") == Date(timeIntervalSince1970: 1_794_675_600)) }
@Test func timeNegativeOffset() { #expect(XMLTVTime.parse("20261114120000 -0500") == Date(timeIntervalSince1970: 1_794_675_600)) }
@Test func timeNoOffsetIsUTC()  { #expect(XMLTVTime.parse("20261114170000") == Date(timeIntervalSince1970: 1_794_675_600)) }
@Test func timeGarbageIsNil()   { #expect(XMLTVTime.parse("tomorrow") == nil); #expect(XMLTVTime.parse("") == nil) }
@Test func parsesChannelsAndProgrammes()   // 2 channels (one with icon, one with two display-names), 2 programmes;
                                           // checks every field incl. sub-title, two <category>, and "Texas A&amp;M" → "Texas A&M"
@Test func programmeMissingStopIsSkipped()        // summary.skipped == 1
@Test func programmeStopNotAfterStartIsSkipped()
@Test func programmeWithoutTitleIsSkipped()
@Test func programmeForUnknownChannelIsStillDelivered()   // the store decides, not the parser
@Test func truncatedFileDeliversWhatWasRead()     // cut mid-element after 1 good programme → 1 delivered, no throw
@Test func emptyTvElement()                       // <tv></tv> → all zeros
@Test func missingFileThrows()
```

- [ ] **Step 2: Run** `swift test --filter XMLTVParserTests` — expected: compile failure.

- [ ] **Step 3: Implement** on Foundation's `XMLParser(stream:)` with a delegate; `XMLTVTime.parse` by fixed-position digit arithmetic, not `DateFormatter` (67,000 programmes × 2 stamps).

- [ ] **Step 4: Run** `swift test --filter XMLTVParserTests` — expected: all pass.

- [ ] **Step 5: Commit** — `git commit -am "xmltv: add streaming guide parser"` (after `git add` of the new files)

### Task 6: Matching channels to the guide, and spotting sport

**Files:**
- Create: `Sources/TunerCore/Matcher.swift`, `Sources/TunerCore/SportsClassifier.swift`, `Tests/TunerCoreTests/MatcherTests.swift`, `Tests/TunerCoreTests/SportsClassifierTests.swift`

**Interfaces — Produces:**

```swift
public enum MatchKind: String, Sendable { case id, name, normalizedName }
public enum NameNormalizer { public static func normalize(_ s: String) -> String }
public struct MatchCandidate: Sendable { public var ref: Int64; public var id: String; public var displayNames: [String]; public var hasProgrammes: Bool }
public struct MatchQuery: Sendable { public var channelID: Int64; public var tvgID: String?; public var name: String; public var tvgName: String? }
public struct Match: Equatable, Sendable { public var guideRef: Int64; public var kind: MatchKind }
public enum Matcher { public static func match(_ channels: [MatchQuery], against guide: [MatchCandidate]) -> [Int64: Match] }
public enum SportsClassifier {
    public static func isSportsGroup(_ groupTitle: String?) -> Bool
    public static func isSportsCategory(_ categories: [String]) -> Bool
}
```

Rules, in order, first hit wins:

1. `tvgID` equals a guide `id` exactly → `.id`.
2. `name` or `tvgName` equals a guide display name, or a guide `id`, exactly → `.name`.
3. `NameNormalizer.normalize` of `name` or `tvgName` equals the normalised form of a display name or id → `.normalizedName`.

When a rule finds several guide channels, take the one with `hasProgrammes`; if that still leaves more than one, or none has programmes and there is more than one, there is **no match at this rule and the later rules are not tried**.

`normalize`: lowercase; remove one leading prefix matching `^\s*(us|usa)?\s*:\s*`; replace every run of non-letter, non-digit characters with one space; trim; drop one trailing token from `hd`, `fhd`, `uhd`, `sd`, `4k`.

`isSportsGroup`: group title contains "sport", case-insensitive. `isSportsCategory`: any category, lowercased, contains one of `sport`, `football`, `fußball`, `soccer`, `baseball`, `basketball`, `hockey`, `golf`, `tennis`, `rugby`, `cricket`, `boxing`, `wrestling`, `racing`, `motorsport`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func normalize() {
    #expect(NameNormalizer.normalize("US: ESPN") == "espn")
    #expect(NameNormalizer.normalize("USA :  Fox  Sports 1 HD") == "fox sports 1")
    #expect(NameNormalizer.normalize(": NBA TV") == "nba tv")
    #expect(NameNormalizer.normalize("(PLUTO France) Diane, femme flic") == "pluto france diane femme flic")
    #expect(NameNormalizer.normalize("HD") == "hd")          // never normalises to empty
}
@Test func idBeatsName()                       // tvgID hits guide A, name hits guide B → A, .id
@Test func exactNameWhenIDEmpty()              // → .name
@Test func nameMatchesGuideIDUsedAsName()      // guide id "USA  TELEMUNDO", channel name identical → .name
@Test func normalizedNameFallback()            // "USA: Espn HD" vs display name "US: ESPN" → .normalizedName
@Test func ambiguityPrefersCandidateWithProgrammes()
@Test func ambiguityWithoutTiebreakIsNoMatch() // two candidates, both with programmes → absent from result
@Test func unmatchedChannelIsAbsent()
@Test func sportsGroup()    { #expect(SportsClassifier.isSportsGroup("US Sports")); #expect(!SportsClassifier.isSportsGroup("United States")); #expect(!SportsClassifier.isSportsGroup(nil)) }
@Test func sportsCategory() { #expect(SportsClassifier.isSportsCategory(["Sports talk"])); #expect(SportsClassifier.isSportsCategory(["Series", "Football"])); #expect(!SportsClassifier.isSportsCategory(["News"])); #expect(!SportsClassifier.isSportsCategory([])) }
```

- [ ] **Step 2: Run** `swift test --filter "MatcherTests|SportsClassifierTests"` — expected: compile failure.
- [ ] **Step 3: Implement** with dictionaries built once per call (4,000 × 4,000 must not be quadratic).
- [ ] **Step 4: Run** the same filter — expected: all pass.
- [ ] **Step 5: Commit** — `matcher: link playlist channels to guide channels`

### Task 7: Store — channels, sections, favourites, recents

**Files:**
- Create: `Sources/TunerCore/Store/Store.swift`, `Sources/TunerCore/Store/Store+Channels.swift`, `Tests/TunerCoreTests/StoreChannelsTests.swift`
- Modify: `Sources/TunerCore/Models.swift`

**Interfaces — Consumes:** `ParsedChannel`, `SportsClassifier`.
**Produces:**

```swift
public enum SourceKind: String, Sendable { case playlist, guide }
public struct SourceRow: Equatable, Sendable {
    public var id: Int64; public var kind: SourceKind; public var location: String   // file path or URL string
    public var etag: String?; public var lastRefreshAt: Date?; public var lastError: String?
    public var itemCount: Int; public var skippedCount: Int
}
public enum Section: Hashable, Sendable { case recents, favourites, sports, all, group(String) }
public struct ChannelRow: Identifiable, Equatable, Sendable {
    public var id: Int64; public var name: String; public var logoURL: String?; public var groupTitle: String?
    public var streamURL: String; public var guideRef: Int64?; public var isFavourite: Bool
}
public final class Store: Sendable {
    public init(path: String) throws            // creates the file and parent folder, runs migrations
    public static func inMemory() throws -> Store
    public func addSource(kind: SourceKind, location: String) throws -> Int64   // returns the existing id if location is already present
    public func sources() throws -> [SourceRow]
    public func recordRefresh(sourceID: Int64, etag: String?, itemCount: Int, skippedCount: Int, error: String?, at: Date) throws
    public func replaceChannels(sourceID: Int64, with: [ParsedChannel]) throws  // one transaction
    public func channels(in: Section, at: Date) throws -> [ChannelRow]
    public func groups() throws -> [String]                                     // distinct group titles, sorted
    public func setFavourite(_ on: Bool, channelID: Int64) throws
    public func recordWatched(channelID: Int64, at: Date) throws
    public func bufferMs(forStreamURL: String) throws -> Int?
    public func setBufferMs(_ ms: Int, forStreamURL: String) throws
}
```

Schema (migration `v1`): `source`, `channel` (`sourceID`, `name`, `tvgID`, `tvgName`, `logoURL`, `groupTitle`, `streamURL`, `sortIndex`, `isSportsGroup`, `guideRef`, `matchKind`), `favourite(streamURL PRIMARY KEY, name, addedAt)`, `recent(streamURL PRIMARY KEY, name, lastWatchedAt)`, `channelPlayback(streamURL PRIMARY KEY, bufferMs)`, and an FTS5 table `channel_fts(name)` with `content='channel'`, created with raw SQL. Guide tables arrive in Task 8 as migration `v2`.

Behaviour:

- `replaceChannels` deletes that source's channels, inserts the new ones in playlist order, rebuilds `channel_fts`, then **reconciles followers**: any `favourite` or `recent` row whose `streamURL` no longer exists but whose `name` matches exactly one channel is repointed to that channel's URL; rows that match nothing, or more than one, are left in place and simply do not surface until a later import brings them back.
- Section ordering: `.recents` by `lastWatchedAt` descending, capped at 30; `.favourites` by name; `.all` and `.group` by `sortIndex`; `.sports` by `sortIndex` and, until Task 8, containing only `isSportsGroup` channels.
- A channel is identified to the outside world by its row `id` within one import, and by `streamURL` across imports.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func importAndListAll()                    // 3 parsed → .all returns 3 in playlist order
@Test func addSourceIsIdempotentPerLocation()
@Test func groupsAreDistinctAndSorted()
@Test func groupSection()
@Test func sportsSectionUsesGroupTitle()         // "US Sports" in, "United States" out
@Test func favouritesToggleAndSurviveReimport()  // same URLs re-imported → still favourite
@Test func favouriteFollowsRenamedURLByName()    // URL changed, name same and unique → still favourite, new URL
@Test func favouriteWithAmbiguousNameDoesNotFollow()   // two channels share the name → .favourites empty, no throw
@Test func favouriteOfRemovedChannelDisappearsQuietly()
@Test func recentsOrderedNewestFirstAndCappedAt30()
@Test func recordWatchedTwiceKeepsOneRow()
@Test func duplicateStreamURLsImport()           // two entries, same URL → both listed; favouriting one marks both
@Test func bufferMemoryRoundTrip()               // nil → set 2000 → 2000
@Test func reopeningFileKeepsData()              // on-disk store in a temp dir, close, reopen
@Test func replaceWithEmptyListClearsChannels()
```

- [ ] **Step 2: Run** `swift test --filter StoreChannelsTests` — expected: compile failure.
- [ ] **Step 3: Implement** on GRDB `DatabasePool` (`DatabaseQueue` for `inMemory`), WAL mode, with `DatabaseMigrator`.
- [ ] **Step 4: Run** — expected: all pass.
- [ ] **Step 5: Commit** — `store: add channels, sections, favourites, recents`

### Task 8: Store — guide data, now/next, sports by programme

**Files:**
- Create: `Sources/TunerCore/Store/Store+Guide.swift`, `Tests/TunerCoreTests/StoreGuideTests.swift`
- Modify: `Sources/TunerCore/Store/Store.swift` (migration `v2`), `Sources/TunerCore/Store/Store+Channels.swift` (`.sports`), `Sources/TunerCore/Models.swift`

**Interfaces — Consumes:** `ParsedGuideChannel`, `ParsedProgramme`, `Matcher`, `SportsClassifier`.
**Produces:**

```swift
public struct ProgrammeRow: Identifiable, Equatable, Sendable {
    public var id: Int64; public var guideRef: Int64; public var start: Date; public var stop: Date
    public var title: String; public var subTitle: String?; public var desc: String?; public var isSport: Bool
}
public protocol GuideWriter { func add(_ c: ParsedGuideChannel) throws; func add(_ p: ParsedProgramme) throws }
extension Store {
    /// One transaction: delete this source's guide data, run `load`, drop programmes that ended more than
    /// 24 hours before `now`, rebuild the programme search index, re-run matching for every channel.
    /// If `load` throws, nothing changes.
    public func replaceGuide(sourceID: Int64, now: Date, load: (GuideWriter) throws -> Void) throws
    public func rematch() throws                                  // also called at the end of replaceChannels
    public func nowPlaying(at: Date) throws -> [Int64: ProgrammeRow]        // keyed by guideRef
    public func upcoming(guideRef: Int64, after: Date, limit: Int) throws -> [ProgrammeRow]
}
```

Schema `v2`: `guideChannel(ref INTEGER PRIMARY KEY, sourceID, id, displayNames /* "\u{1F}"-joined */, iconURL)`, `programme(id, guideRef, start, stop, title, subTitle, desc, isSport)` with indexes on `(guideRef, start)` and `(start, stop)`, FTS5 `programme_fts(title, subTitle, desc)` with `content='programme'`. Programmes naming a channel id the feed never declared are dropped at insert.

`.sports` now returns channels where `isSportsGroup` **or** the channel's `guideRef` is airing an `isSport` programme at the given time.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func guideImportLinksByIDThenName()        // after replaceChannels + replaceGuide, ChannelRow.guideRef set for both kinds
@Test func importingPlaylistAfterGuideAlsoMatches()
@Test func nowPlayingPicksProgrammeSpanningNow() // start <= now < stop; boundary: at == stop returns the next one
@Test func nowPlayingEmptyWhenGapInSchedule()
@Test func upcomingIsOrderedAndLimited()
@Test func oldProgrammesArePruned()              // ended 25 h ago → gone; ended 23 h ago → kept
@Test func failedLoadKeepsPreviousGuide()        // load throws after adding rows → nowPlaying unchanged
@Test func replacingGuideRemovesStaleProgrammes()
@Test func programmeForUndeclaredChannelIsDropped()
@Test func sportsSectionIncludesChannelAiringSportNow()   // group "United States", category ["Football"] now → in .sports; an hour later → out
@Test func twoGuideSourcesCoexist()              // same channel id in two feeds does not collide
```

- [ ] **Step 2: Run** `swift test --filter StoreGuideTests` — expected: compile failure.
- [ ] **Step 3: Implement.** Insert with a prepared statement inside the one transaction; rebuild FTS with the `'rebuild'` command after the bulk insert rather than per row.
- [ ] **Step 4: Run** — expected: all pass.
- [ ] **Step 5: Commit** — `store: add guide import, now/next, sports by programme`

### Task 9: Search

**Files:**
- Create: `Sources/TunerCore/Store/Store+Search.swift`, `Tests/TunerCoreTests/StoreSearchTests.swift`
- Modify: `Sources/TunerCore/Models.swift`

**Interfaces — Produces:**

```swift
public struct ProgrammeHit: Identifiable, Equatable, Sendable { public var programme: ProgrammeRow; public var channel: ChannelRow; public var id: String }  // "\(programme.id)-\(channel.id)"
public struct SearchResults: Equatable, Sendable {
    public var onNow: [ProgrammeHit]     // start <= at < stop, ordered by channel sortIndex
    public var later: [ProgrammeHit]     // at < start <= at + 7 days, ordered by start
    public var channels: [ChannelRow]    // name matches, ordered by sortIndex
    public static let empty: SearchResults
}
extension Store { public func search(_ text: String, at: Date, limit: Int = 50) throws -> SearchResults }
enum FTSQuery { static func make(from text: String) -> String? }   // internal; nil means "no usable terms"
```

`FTSQuery.make`: split on whitespace; from each piece strip every character that is not a letter or digit (keeping letters of any script); drop empty pieces; emit each as `"piece"*` joined by spaces (implicit AND). `texas a&m` → `"texas"* "am"*`. Zero pieces → `nil` → `SearchResults.empty`. A programme matched on a guide channel that several playlist channels point at yields one hit per channel; a programme on a guide channel no playlist channel points at yields none. Each list is capped at `limit`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func ftsQuery() {
    #expect(FTSQuery.make(from: "tennessee") == "\"tennessee\"*")
    #expect(FTSQuery.make(from: "  texas a&m ") == "\"texas\"* \"am\"*")
    #expect(FTSQuery.make(from: "\"") == nil)
    #expect(FTSQuery.make(from: "- * : ( )") == nil)
    #expect(FTSQuery.make(from: " ") == nil)
    #expect(FTSQuery.make(from: "🏈") == nil)
    #expect(FTSQuery.make(from: "fußball") == "\"fußball\"*")
}
@Test func findsLiveProgrammeByTitlePrefix()     // "tenn" → onNow has the game, later empty
@Test func findsBySubtitleAndDescription()
@Test func separatesNowFromLater()
@Test func excludesFinishedAndFarFuture()        // ended a minute ago; starts in 8 days
@Test func findsChannelsByName()                 // "espn" → channels has ESPN and ESPN2
@Test func allTermsMustMatch()                   // "college basketball" does not return "College Football"
@Test func oneHitPerPlaylistChannel()            // two playlist channels on one guide channel → 2 hits
@Test func unlinkedGuideChannelYieldsNoHit()
@Test func respectsLimit()
@Test func syntaxCharactersNeverThrow()          // for each of: "\"", "a\"b", "-", "*", "NEAR(", "a:b", "(", "x OR", "🏈" → no throw
@Test func searchAfterReimportSeesNewData()      // index rebuilt by replaceChannels / replaceGuide
```

- [ ] **Step 2: Run** `swift test --filter StoreSearchTests` — expected: compile failure.
- [ ] **Step 3: Implement** with two `MATCH` queries (programmes, channels) bound as parameters.
- [ ] **Step 4: Run** — expected: all pass.
- [ ] **Step 5: Commit** — `search: add channel and programme search`

### Task 10: Importing from a file or a URL

**Files:**
- Create: `Sources/TunerCore/ImportService.swift`, `Tests/TunerCoreTests/ImportServiceTests.swift`

**Interfaces — Consumes:** `M3UParser`, `XMLTVParser`, `Store`.
**Produces:**

```swift
public enum ImportOutcome: Equatable, Sendable { case imported(items: Int, skipped: Int), notModified }
public enum ImportError: Error, Equatable { case http(status: Int), notAPlaylist, notAGuide, unreadable }
public struct ImportService: Sendable {
    public init(store: Store, session: URLSession = .shared, now: @escaping @Sendable () -> Date = Date.init)
    public func importPlaylist(sourceID: Int64) async throws -> ImportOutcome
    public func importGuide(sourceID: Int64) async throws -> ImportOutcome
}
```

Behaviour: the source's `location` is a file path or an `http(s)` URL. Remote fetches download to a temporary file, send `If-None-Match` when the source has an `etag`, and treat `304` as `.notModified`. A gzip-compressed guide body (first bytes `1f 8b`) is decompressed before parsing. Playlist text is decoded as UTF-8, falling back to ISO Latin-1. A playlist with zero channels throws `.notAPlaylist` and a guide with zero channels and zero programmes throws `.notAGuide`; in both cases the existing data is untouched. Every outcome, success or failure, is written with `Store.recordRefresh`; `lastError` holds a short message that **never contains the URL**. Temporary files are removed in all paths.

- [ ] **Step 1: Write the failing tests** (remote cases use a `URLProtocol` stub registered on an ephemeral `URLSessionConfiguration`)

```swift
@Test func importsPlaylistFromFile()
@Test func importsGuideFromFile()
@Test func importsGuideFromURLAndStoresETag()
@Test func sendsIfNoneMatchAndHandles304()            // second call → .notModified, data unchanged, lastRefreshAt updated
@Test func http500KeepsOldDataAndRecordsError()       // throws .http(status: 500); sources()[0].lastError non-nil
@Test func htmlErrorPageIsNotAPlaylist()              // body "<html>…" → .notAPlaylist, old channels still listed
@Test func emptyGuideIsNotAGuide()
@Test func gzippedGuideIsDecompressed()
@Test func latin1PlaylistDecodes()
@Test func lastErrorNeverContainsTheLocation()        // location has ?token=SECRET; lastError does not contain "SECRET"
@Test func missingFileThrowsUnreadable()
```

- [ ] **Step 2: Run** `swift test --filter ImportServiceTests` — expected: compile failure.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — expected: all pass.
- [ ] **Step 5: Commit** — `import: fetch and load playlists and guides`

### Task 11: The self-managing playback supervisor

**Files:**
- Create: `Sources/TunerCore/Playback/Player.swift`, `Sources/TunerCore/Playback/PlaybackSupervisor.swift`, `Tests/TunerCoreTests/PlaybackSupervisorTests.swift`

**Interfaces — Produces:**

```swift
public enum PlayerState: Equatable, Sendable { case idle, opening, buffering, playing, ended, error }
public struct PlayerStats: Equatable, Sendable {
    public var positionMs: Int64; public var displayedPictures: Int; public var decodedAudioBlocks: Int
    public var lostPictures: Int; public var inputBitrateKbps: Double
    public static let zero: PlayerStats
}
@MainActor public protocol Player: AnyObject {
    func play(url: URL, bufferMs: Int)     // replaces whatever is playing; implementations stop the old stream first
    func stop()
    var volume: Int { get set }            // 0...100
    var state: PlayerState { get }
    var stats: PlayerStats { get }
}
public protocol BufferMemory: Sendable { func bufferMs(forStreamURL: String) -> Int?; func setBufferMs(_ ms: Int, forStreamURL: String) }
public struct SupervisorPolicy: Sendable {
    public var bufferStepsMs = [1000, 2000, 4000, 8000]   // a new channel starts at the first step
    public var startTimeout: TimeInterval = 12            // opening/buffering with no progress → failed start
    public var stallAfter: TimeInterval = 4               // was progressing, then nothing → stall
    public var rebufferLimit = 3                          // playing→buffering transitions…
    public var rebufferWindow: TimeInterval = 60          // …within this window → stutter
    public var retryDelays: [TimeInterval] = [1, 2, 5, 10, 20]   // wait before attempt 1…5; then unavailable
    public var stableAfter: TimeInterval = 60             // progressing this long resets the attempt count
    public var stepDownAfter: TimeInterval = 30 * 60      // progressing this long with no stall → one step down
    public var wakeGap: TimeInterval = 30                 // a tick this late means the Mac slept
    public static let `default`: SupervisorPolicy
}
@MainActor public final class PlaybackSupervisor {
    public enum Status: Equatable, Sendable { case idle, starting, playing, reconnecting(attempt: Int), unavailable }
    public init(player: Player, memory: BufferMemory, now: @escaping () -> Date, policy: SupervisorPolicy = .default)
    public private(set) var status: Status
    public private(set) var reconnectCount: Int          // since the last play(streamURL:)
    public private(set) var currentBufferMs: Int
    public var onStatusChange: ((Status) -> Void)?
    public func play(streamURL: String)
    public func stop()
    public func retry()                                  // only meaningful from .unavailable
    public func tick()                                   // the app calls this once a second; tests call it directly
}
extension Store: BufferMemory {}                         // traps nothing: errors are swallowed and read as nil
```

"Progress" means that since the previous tick `positionMs`, `displayedPictures` or `decodedAudioBlocks` increased. The supervisor owns no timers and reads the time only through `now`.

Behaviour:

- `play` → `.starting`, calls `player.play` with the remembered buffer for that URL or the first step. First progress → `.playing`.
- **Failed start** (`startTimeout` with no progress, or state `error`/`ended` before any progress) and **stall** (`stallAfter` without progress while `.playing`, or state `error`/`ended` while `.playing`) both go to `.reconnecting(attempt: n)`, call `player.stop()`, and call `player.play` again once `retryDelays[n-1]` has elapsed.
- A **stall** or a **stutter** also moves the buffer one step up (saturating) and saves it. A failed start does not change the buffer.
- After `retryDelays.count` consecutive failed attempts → `.unavailable`, `player.stop()`, and **no further `player.play` calls** until `retry()` or `play(streamURL:)`.
- `stableAfter` of continuous progress resets the attempt counter to zero. `stepDownAfter` of continuous progress moves the buffer one step down and saves it, without restarting the stream (it applies next time).
- **Wake-up:** if a tick arrives more than `wakeGap` after the previous one, the supervisor forgets its progress baseline and timers for that tick, does not count a stall, and — if it was `.unavailable` or mid-retry — restarts from attempt 1.
- `stop()` → `.idle`, cancels any pending retry. `play` for a new URL while reconnecting abandons the old one.

- [ ] **Step 1: Write the failing tests** against a `FakePlayer` (records `play`/`stop` calls with their arguments; test sets `state` and `stats`) and a `FakeMemory`, with a mutable test clock

```swift
@Test func startsWithFirstBufferStep()                  // play → player.play(bufferMs: 1000), status .starting
@Test func usesRememberedBuffer()                       // memory has 4000 → play(bufferMs: 4000)
@Test func becomesPlayingOnFirstProgress()
@Test func startTimeoutTriggersReconnectAfterOneSecond()// 12 s no progress → .reconnecting(1); +0.9 s no play call; +1 s play call #2
@Test func errorBeforeProgressIsAFailedStartAndKeepsBuffer()
@Test func stallReconnectsAndStepsBufferUp()            // playing, 4 s frozen → .reconnecting(1), memory now 2000, next play uses 2000
@Test func endedWhilePlayingIsAStall()
@Test func bufferSaturatesAtLastStep()
@Test func threeRebuffersInAMinuteIsAStutter()          // playing→buffering ×3 within 60 s → buffer steps up, stream restarted once
@Test func retriesFollowTheDelaySchedule()              // attempts at +1, +2, +5, +10, +20 s after each failure
@Test func givesUpAfterFiveAttemptsAndStopsConnecting() // → .unavailable; 120 more ticks → play call count unchanged
@Test func retryFromUnavailableStartsOver()
@Test func stablePlaybackResetsAttemptCount()           // fail, recover, 60 s good, fail → .reconnecting(1) again
@Test func longCleanPlaybackStepsBufferDownWithoutRestart()
@Test func wakeGapIsNotAStall()                         // playing; clock jumps 2 h; tick → no reconnect counted, status unchanged that tick
@Test func wakeFromUnavailableRetriesFromAttemptOne()
@Test func playNewChannelAbandonsPendingRetry()
@Test func stopCancelsEverything()                      // stop while reconnecting; 60 ticks → no play calls
@Test func neverTwoPlayCallsWithinOneSecond()           // across every scenario above: assert min spacing ≥ 1 s between play calls for the same URL
@Test func statusChangeCallbackFiresOncePerChange()
```

- [ ] **Step 2: Run** `swift test --filter PlaybackSupervisorTests` — expected: compile failure.
- [ ] **Step 3: Implement** as an explicit state machine driven only by `tick()`.
- [ ] **Step 4: Run** — expected: all pass. Then `swift test` — expected: the whole suite passes.
- [ ] **Step 5: Commit** — `playback: add self-managing supervisor`

---

## Part C — The app

UI tasks are verified by building, launching and checking a short list by hand; they add no unit tests beyond what Part B has. Each ends with `swift build` clean of warnings in `Sources/Tuner`.

### Task 12: App shell — bundle, engine, three panes, play a channel

**Files:**
- Create: `scripts/bundle.sh`, `Resources/Info.plist`, `Sources/Tuner/TunerApp.swift`, `Sources/Tuner/AppModel.swift`, `Sources/Tuner/VLCPlayer.swift`, `Sources/Tuner/VideoView.swift`, `Sources/Tuner/Views/SidebarView.swift`, `Sources/Tuner/Views/ChannelListView.swift`, `Sources/Tuner/Views/PlayerPaneView.swift`
- Modify: `Package.swift`

**Interfaces — Consumes:** everything in `TunerCore`; VLCKit linkage and statistics property names from `docs/spikes/2026-11-spike-results.md`.
**Produces:**

```swift
@MainActor final class VLCPlayer: NSObject, Player { let videoView: NSView }   // one VLCMediaPlayer; media option ":network-caching=<bufferMs>"
@MainActor @Observable final class AppModel {
    var section: Section            // setting it reloads `rows`
    private(set) var rows: [ChannelRow]
    private(set) var groups: [String]
    var selectedChannelID: Int64?
    private(set) var playingChannel: ChannelRow?
    private(set) var status: PlaybackSupervisor.Status
    private(set) var importMessage: String?       // "Importing…", "4,144 channels", or a short error
    func play(_ channel: ChannelRow)              // supervisor.play + store.recordWatched
    func stop()
    func toggleFavourite(_ channel: ChannelRow)
    func addPlaylist(location: String) async
    func addGuide(location: String) async
    func refreshAll() async
}
```

- [ ] **Step 1: `Package.swift`** — add `.binaryTarget(name: "VLCKit", path: "Vendor/VLCKit.xcframework")` (or the linkage the spike recorded) and executable target `Tuner` depending on `TunerCore` and `VLCKit`, Swift 5 language mode for this target.

- [ ] **Step 2: `scripts/bundle.sh`** — runs `scripts/fetch-vlckit.sh`, `swift build -c release`, then assembles `build/Tuner.app`: executable in `Contents/MacOS`, `Resources/Info.plist` in `Contents`, `VLCKit.framework` in `Contents/Frameworks`, an `@executable_path/../Frameworks` rpath on the executable, and an ad-hoc signature (`codesign --force --deep -s -`). `Info.plist`: bundle id `local.tuner`, name `Tuner`, `LSMinimumSystemVersion` 26.0, `NSHighResolutionCapable`, `NSLocalNetworkUsageDescription` ("Tuner looks for TVs on your network to cast to."), `NSAppTransportSecurity` → `NSAllowsArbitraryLoads` true (IPTV sources are often plain HTTP).

- [ ] **Step 3: `VLCPlayer`** — maps VLCKit's player states onto `PlayerState` and its media statistics onto `PlayerStats`; `play` stops any current media before starting the new one.

- [ ] **Step 4: `AppModel` and the window** — the database lives at `~/Library/Application Support/Tuner/tuner.sqlite`. A one-second `Timer` calls `supervisor.tick()`. `NavigationSplitView` with three columns:
  - Sidebar: Recents, Favourites, Sports, All channels, then a collapsed "Groups" disclosure listing `groups`. (Guide arrives in plan 2.)
  - Channel list: a `List` of `rows` bound to `selectedChannelID`, each row showing the name; Return or double-click plays.
  - Player pane: `VideoView` over a black background, channel name beneath.
  - On launch: section `.recents`, the most recent channel selected, **nothing playing**. If there are no sources at all, the list area shows "Add a playlist to get started" with a button.
  - File menu: "Add Playlist File…" (open panel), "Add Playlist URL…", "Add Guide URL…" (small sheet with one text field), "Refresh Sources" (⌘R). Imports run off the main thread and never interrupt playback.

- [ ] **Step 5: Build and launch**

Run: `scripts/bundle.sh && open build/Tuner.app`
Check by hand:
  - Add `sample_files/*.m3u` via the menu → "All channels" fills, scrolling 4,144 rows is smooth.
  - Sports shows about 809 channels.
  - Return on a channel plays it in the right pane within a few seconds; picking another switches; the first stream is gone (one connection).
  - Quit and relaunch → opens on Recents with the last channel selected and no sound.
  - Add the guide URL → finishes without freezing the window.

- [ ] **Step 6: Commit** — `app: three-pane window with VLCKit playback`

### Task 13: Now-playing rows, programme details, logos, keyboard, full screen

**Files:**
- Create: `Sources/Tuner/LogoCache.swift`
- Modify: `Sources/Tuner/AppModel.swift`, `Sources/Tuner/Views/ChannelListView.swift`, `Sources/Tuner/Views/PlayerPaneView.swift`, `Sources/Tuner/TunerApp.swift`

**Interfaces — Produces (additions to `AppModel`):**

```swift
private(set) var nowPlaying: [Int64: ProgrammeRow]     // by guideRef; reloaded on the minute and after any import
private(set) var upNext: [ProgrammeRow]                // for the playing channel, limit 3
func playRecent(_ index: Int)                          // 0-based into Recents
func playPrevious()                                    // the channel watched before the current one
```

- [ ] **Step 1: Rows** — logo (32 pt, rounded), name, current programme title in secondary colour, and a thin progress bar for elapsed fraction. Channels without a `guideRef` or without a current programme show logo and name only, at the same row height.
- [ ] **Step 2: `LogoCache`** — `func image(for urlString: String) async -> NSImage?`; memory cache plus a `URLCache` with 200 MB on disk; at most 6 downloads at once; failures cached as misses for the session. A row never waits for its logo.
- [ ] **Step 3: Details pane** — under the video: programme title, sub-title, start–end in local time with a LIVE badge, description (scrolls if long), then "Next" with up to three upcoming titles and times. With no guide data: channel name and group only.
- [ ] **Step 4: Keyboard and full screen** — arrows move the selection; Return plays; typing a letter with the list focused moves focus to the search field with that letter in it; Escape clears search, or leaves full screen; ⌘D toggles favourite on the selected channel; ⌘1…⌘9 play Recents 1–9; ⌘[ plays the previous channel; F or double-click on the video toggles full screen for the player pane; in full screen the pointer and any overlay controls hide after 3 seconds idle. A star shows on favourite rows; the Favourites section updates immediately.
- [ ] **Step 5: Build, launch, check by hand**
  - Rows for ESPN-style channels show a title and a moving bar; unlisted channels look tidy, not broken.
  - Flick-scrolling "All channels" stays smooth while logos load in.
  - Every shortcut above works; full screen hides the pointer.
- [ ] **Step 6: Commit** — `app: now-playing rows, details pane, keyboard navigation`

### Task 14: Search

**Files:**
- Create: `Sources/Tuner/Views/SearchResultsView.swift`
- Modify: `Sources/Tuner/AppModel.swift`, `Sources/Tuner/Views/SidebarView.swift`, `Sources/Tuner/Views/ChannelListView.swift`

**Interfaces — Produces (additions to `AppModel`):**

```swift
var searchText: String                       // setting it schedules a search
private(set) var searchResults: SearchResults?   // nil when searchText has no usable terms
```

- [ ] **Step 1:** A search field at the top of the sidebar (⌘F focuses it). Setting `searchText` runs `store.search` off the main thread after an 80 ms pause in typing; a result is discarded if the text changed while it ran.
- [ ] **Step 2:** While `searchResults` is non-nil the middle column shows `SearchResultsView` instead of the channel list: sections "On now", "Later", "Channels", hidden when empty; "No results" when all three are. Programme rows: LIVE badge or local start time (with weekday when not today), title, sub-title, channel name and logo. Arrow keys move through all sections as one list; the first row is preselected.
- [ ] **Step 3:** Return on an "On now" row or a channel row plays that channel and keeps the results up. Return on a "Later" row shows that programme in the details pane without changing what is playing.
- [ ] **Step 4: Build, launch, check by hand** — with the real guide loaded: typing a team name shows the game under "On now" or "Later" with no perceptible lag per keystroke; `texas a&m`, a lone `"`, and an emoji neither error nor hang; Escape returns to the previous section and selection.
- [ ] **Step 5: Commit** — `app: search channels and programmes`

### Task 15: Reconnect badge, unavailable state, stats overlay

**Files:**
- Create: `Sources/Tuner/Views/StatsOverlay.swift`
- Modify: `Sources/Tuner/Views/PlayerPaneView.swift`, `Sources/Tuner/AppModel.swift`

- [ ] **Step 1:** Over the video, driven by `AppModel.status`: `.starting` → a small spinner; `.reconnecting` → a "Reconnecting…" capsule in a corner over the last frame; `.unavailable` → centred "Channel unavailable" with a "Try Again" button calling `supervisor.retry()`. No alerts or sheets for any playback failure.
- [ ] **Step 2:** `StatsOverlay`, toggled with ⌘I, updated each second: stream host name (never the full URL), input bitrate, current buffer setting, lost pictures, reconnect count, supervisor status.
- [ ] **Step 3:** While `status` is `.starting`, `.playing` or `.reconnecting`, hold a `ProcessInfo` activity that prevents display sleep; release it on `.idle` and `.unavailable`.
- [ ] **Step 4: Build, launch, check by hand**
  - Play a channel, turn Wi-Fi off: within about 5 seconds the badge appears; turn Wi-Fi on: playback returns without touching anything; the overlay's reconnect count went up and the buffer value rose a step.
  - Leave Wi-Fi off for a minute: "Channel unavailable" appears and stays; "Try Again" with Wi-Fi back on plays.
  - Close the lid for a minute while playing, reopen: playback resumes by itself.
  - Play the same channel again later: the overlay shows it starting at the raised buffer.
- [ ] **Step 5: Commit** — `app: reconnect badge, unavailable state, stats overlay`

### Task 16: Speed check at real size

**Files:**
- Create: `Tests/TunerCoreTests/PerformanceTests.swift`

- [ ] **Step 1: Write the tests** — build, in a temp on-disk store, a synthetic 5,000-channel playlist and an 80,000-programme guide (16 programmes on each of the first 5,000 guide channels, around "now"), then:

```swift
@Test func playlistImportUnderOneSecond()        // M3UParser.parse + replaceChannels
@Test func guideImportUnderTenSeconds()          // replaceGuide with 80,000 programmes, including matching and index rebuild
@Test func allChannelsQueryUnder50ms()           // channels(in: .all)
@Test func sportsQueryUnder50ms()
@Test func nowPlayingUnder50ms()
@Test func searchUnder50ms()                     // median of 20 runs each for "foot", "college football", "espn"
```
Use `ContinuousClock().measure`. These limits are for a release build: run with `swift test -c release --filter PerformanceTests`.

- [ ] **Step 2: Run** — expected: all pass. If one fails, fix the query or index it exercises (not the limit) and re-run the full suite.
- [ ] **Step 3: Final check with the owner's real data** — `scripts/bundle.sh && open build/Tuner.app`, import the real playlist and guide into a fresh database, and confirm against spec section 4: launch to usable window is immediate, scrolling and search feel instant, a stream survives a Wi-Fi blip untouched.
- [ ] **Step 4: Commit** — `tests: add speed checks at real data size`

# Native macOS IPTV client — design

Date: 2026-11-14
Status: awaiting approval

Throughout, **decided** marks what the owner chose in conversation, and **call** marks a choice made on their behalf that they have seen in summary and can overturn.

## 1. Intent

A personal-use macOS app for watching live IPTV: load M3U playlists, pull XMLTV guide feeds, find something to watch quickly, and play it reliably.

The owner uses UHF today. Its core shortcoming is that it is an iPad app running on the Mac, not a native Mac app. This app should be "similar but better": elegant, quick, TV-like, robust.

The owner's first ten seconds in the app: **search for a sporting event, reach recently watched channels, navigate quickly.** Everything is prioritised around that.

It is for one person on one Mac. No distribution, no accounts, no App Store.

## 2. Goals

1. Native Mac app in a three-pane layout (decided): sidebar, channel list, player with programme details.
2. M3U playlists, by local file or URL, one or more.
3. XMLTV guide feeds, one or more, refreshed automatically in the background.
4. One search box that matches channel names and programme titles, so typing a team finds the game.
5. Guide with an Events view as default (decided) and a time Grid as a toggle in the same view (call).
6. Recents and Favourites.
7. Playback that manages itself (decided): adapts buffering per channel, detects stuck streams, reconnects without being asked. No tuning knobs.
8. Casting to Google Cast devices (Shield / Google TV) (decided). Apple TV casting is wanted but **deferred** (decided): the owner has only a Shield on the network, and it will be built once an Apple TV is available to test against.
9. Stays fast with thousands of channels and tens of thousands of programmes.
10. Extreme performance on the minimum of system resources, while staying rock solid (decided: a side goal, added by the owner on 2026-11-14 during the first build). It applies to every part: CPU, memory, disk, wake-ups and network use are kept as low as the job allows, idle and while playing. Where speed and stability pull apart, stability wins (call). It is a quality bar on what is already in scope, not a reason to add features or to optimise without measuring first (call).

## 3. Non-goals for the first version

Agreed as "out for now": recording, pause/rewind of live TV, catch-up/timeshift, movie and series libraries (VOD), picture-in-picture, multi-view (several channels at once), closed captions/subtitles and audio-track selection (decided: a future update), Apple TV / AirPlay casting (decided: later, when an Apple TV is on the network for testing), provider logins other than a playlist URL (no Xtream Codes API, no Stalker portal), iPhone/iPad versions.

## 4. Anti-goals

It fails, even if every feature works, if it:

- feels slow with ~4,000 channels (scrolling, search-as-you-type, launch);
- needs fiddling to keep a stream alive;
- looks or behaves like a ported app (non-standard controls, no keyboard navigation, ignores Mac conventions);
- is wasteful or fragile: noticeably heavy on CPU, memory or battery for what it is doing, or prone to crashes and hangs (goal 10).

## 5. Constraints and facts about the real data

Measured from the owner's sample playlist and guide feed on 2026-11-14. Design for this shape, but do not hard-code it.

**Playlist**

- 4,144 channels, ~800 KB. Only `#EXTM3U` and `#EXTINF` lines; no other tags.
- Every entry has `tvg-id`, `tvg-name`, `tvg-logo`, `group-title`. No channel numbers, no catch-up attributes.
- Only two groups: "United States" (3,335) and "US Sports" (809). Provider grouping is too coarse to browse by.
- `tvg-id` is **empty on 3,969 entries**; only 175 entries carry one (155 distinct values).
- Stream URLs are HTTPS on a single host with no file extension. **The container format is unknown** (HLS vs raw MPEG-TS) until probed.
- Names carry inconsistent prefixes ("US:", "USA:", "US :", "(PLUTO France) …").

**Guide**

- XMLTV, ~23 MB uncompressed, served as `application/xml` with an ETag. 4,112 `<channel>` elements, 67,467 `<programme>` elements.
- Only 1,365 channels have any programmes.
- Coverage is dense for about four days, thin out to two weeks.
- Every programme has a title; ~97% a description; ~45% a category; ~20% a sub-title. Times are `YYYYMMDDHHMMSS +0000`.
- Guide channel ids are a mix of real ids (`espn.us`), numbers, and display names used as ids.

**Matching** — of the 3,958 distinct names on id-less playlist entries, 3,817 (96%) equal a guide `<display-name>` exactly. Matching must therefore be: id first, then name.

**Privacy** — playlist entries and feed URLs embed the owner's account credentials. They must never be committed, logged in full, or sent anywhere except to the provider. The repo's `.gitignore` already excludes `sample_files/` and `*.m3u*`. Test fixtures must be synthetic.

**Connection limit (decided: stated by the owner)** — the provider allows **two simultaneous connections** on the account. Whether rapid reconnects are penalised is unknown, so treat them as if they might be. Consequences:

- The app never holds more than two streams open, counting everything: the playing channel, a channel being tuned, a format probe, and a stream an Apple TV fetches for itself.
- Channel change may open the new stream before closing the old one (two connections, briefly), which is what keeps zapping fast. It must close the old one as soon as the new one shows a picture, or on failure.
- While a second connection is in use elsewhere (AirPlay session, or the owner watching on another device), a "connection limit" failure is possible; the supervisor treats it like any start failure and backs off rather than hammering.
- Reconnects have a minimum spacing (builder's value; think seconds, not milliseconds) even for the first retry. "Retries start immediately" in 7.5 means without waiting for the owner, not in a tight loop.
- AirPlay hand-off closes the local stream before the Apple TV opens its own.

**Platform** — owner's machine is Apple silicon on macOS 27. Support the current macOS release only (call); no back-deployment work.

**Process** — commits and any docs carry no AI attribution. This is a new repo, separate from the VLC source checkout (decided).

## 6. Approaches considered

1. **Swift app + VLCKit (prebuilt libVLC) — chosen by the owner.** VideoLAN's packaging of the engine for Apple platforms: a video view, playback events, renderer (Chromecast) discovery, no compiling of VLC. Trade-off: the engine version is whatever VLCKit ships (stable 3.x line) rather than current VLC master. Picked because playback works on day one and effort goes into guide, search and self-healing playback, which is where the app beats UHF.
2. **Swift app + own libVLC 4 build from the VLC repo.** Newest engine and full module control, at the cost of a long fragile build (contribs, then VLC), an unstable API and owning every breakage. Too much upkeep for a personal app.
3. **Apple's AVPlayer only, no VLC.** Lightest, and AirPlay comes free, but it accepts a narrow set of stream formats and IPTV providers commonly send ones it refuses. Kept only as the Apple TV casting path.

Also dropped early: forking VLC's own macOS interface (large Objective-C codebase built around a media library; slow build), and any web-technology shell (works against "native").

The playback engine sits behind a small interface (section 8.4) so approach 2 could replace VLCKit later without touching the rest (call).

## 7. What the owner sees

### 7.1 Main window

```
┌──────────────┬────────────────────────────┬──────────────────────────────┐
│ ⌕ Search     │ [logo] ESPN                │                              │
│              │        College Football    │           VIDEO              │
│ Recents      │        ▓▓▓▓░░░░░░          │                              │
│ Favourites   │ [logo] Fox Sports 1        │                              │
│ Sports       │        College Football    ├──────────────────────────────┤
│ Guide        │        ▓▓▓▓▓▓▓░░░          │ College Football        LIVE │
│ All channels │ [logo] NFL Network         │ Tennessee at Texas A&M       │
│              │        NFL GameDay         │ until 6:00 PM                │
│              │        ▓▓░░░░░░░░          │ Next  6:00  CFB Scoreboard   │
└──────────────┴────────────────────────────┴──────────────────────────────┘
```

- **Sidebar** (call): Search, Recents, Favourites, Sports, Guide, All channels. Below those, the playlist's own groups, collapsed by default.
- **Channel list**: logo, channel name, current programme title, progress bar through it. Channels with no guide data show name and logo only and remain playable.
- **Player pane**: video on top, programme title/description/times and the next programme below. Double-click or a key toggles full screen; controls fade when idle.
- **Launch** (call): opens on Recents with the last channel selected, **not** auto-playing.
- **Sports** (call): channels whose playlist group name contains "sport", plus any channel currently airing a programme whose guide category indicates sport.

### 7.2 Keyboard (call)

Arrow keys move through the list, Return plays, typing anywhere in the list focuses search and filters, Escape clears search, a shortcut toggles favourite, a shortcut toggles full screen, number shortcuts jump to the first few Recents, and "previous channel" flips back to the last one watched. Exact bindings are the builder's.

### 7.3 Search

One field. Results are grouped: **On now**, **Starting soon / later**, **Channels**. It matches channel names and programme titles, sub-titles and descriptions, updates as the owner types, and must feel instant. Selecting a live programme plays its channel. Selecting a future programme shows its details (no reminders in v1).

### 7.4 Guide

Filter chips across the top: Sports / Favourites / All, and a day picker. Sports is selected by default (call). Channels with no listings are hidden here by default.

**Where it sits (call).** Selecting Guide in the sidebar replaces both the channel list and the player pane with the guide, at full width. If a channel is playing, it keeps playing in a small docked player fixed in the guide's bottom-right corner (not a floating or detachable window, so this is not picture-in-picture); clicking it returns to the three-pane view. Choosing a live programme in the guide plays it in that docked player; Return or double-click plays it and returns to the three-pane view.

**Events view (default, decided)** — programmes in time order under "On now", "Starting soon", "Tonight", "Tomorrow", …

```
ON NOW
 LIVE  College Football — Tennessee at Texas A&M        [ESPN]
       ESPN · ends 6:00 · also on 2 other channels
 LIVE  College Football                                  [FS1]
       Fox Sports 1 · ends 4:30
STARTING SOON
 4:30  College Football                                  [FS1]
       Fox Sports 1 · in 52 min
```

The same event on several channels collapses into one row with "also on N other channels" (call). Two programmes are the same event when title, start and stop all match; the row expands to pick a channel.

**Grid view (toggle, call)** — channels down, time across, a line marking now. Only shown for the filtered channel set.

### 7.5 Playback behaviour (decided in principle; specifics are calls)

- **Adaptive buffer.** Each channel starts with a small network buffer so it tunes fast. When a channel stutters or stalls, its buffer steps up, and the value is remembered per channel. A channel that has behaved for a long stretch may step back down.
- **Watchdog.** The app tracks whether playback is actually advancing (playback time and/or decoded/displayed frame counters). If nothing advances for a few seconds, or the engine reports end-of-stream or an error on a live channel, it reconnects by itself.
- **Reconnect UX.** A small "Reconnecting…" badge over the last frame. No modal dialogs.
- **Back-off.** Retries start immediately and slow down. After several consecutive failures it stops and shows "Channel unavailable" with one Retry button.
- **No settings.** A hidden stats overlay (bitrate, buffer level, dropped frames, reconnect count) is available for curiosity.

Starting values, thresholds and step sizes are the builder's to choose and tune against real streams.

### 7.6 Casting

**First version: Google Cast only.** The cast menu lists Google Cast devices and has no AirPlay entry. Everything below about Apple TV and AirPlay is the intended design for the later version and is kept here so it is not lost; none of it is built or tested now.

One cast button in the player controls opening one menu (call): Google Cast devices found on the network are listed by name, followed by an "AirPlay…" entry that opens the system AirPlay picker. macOS offers no supported way to list AirPlay devices inside an app's own menu, and private API is not worth the fragility here. The owner picks a device and never has to think about how the stream gets there.

- **Google Cast (Shield / Google TV) — primary.** Through the engine's own renderer discovery and Chromecast output, which can also transcode when the device cannot play the original format. The Mac relays the stream, so it must stay awake while casting; the app prevents sleep while a cast session is active.
- **Apple TV — secondary.** While casting, playback of that channel switches to an AVPlayer-based path with AirPlay external playback. This only works for stream formats AVPlayer accepts. If the stream is refused, the app says so plainly and points the owner to macOS Screen Mirroring with the app in full screen as the fallback.
- While casting, the player pane shows the device name, play/stop and volume; the watchdog and reconnect logic still apply.

**Risk, to settle when the Apple TV work starts** (section 10): whether the owner's streams are HLS or raw MPEG-TS decides how often the Apple TV path works at all.

### 7.7 Sources and settings

A Sources screen: add/remove playlists (file or URL) and guide feeds (URL), see last refresh time and counts, refresh now. Guide feeds refresh on launch when stale and periodically while running, using conditional requests so an unchanged feed costs nothing (call). URL playlists refresh on the same basis. Refresh never blocks the UI and never interrupts playback.

When a refreshed playlist drops or renames channels, favourites and recents follow a channel by its stream URL first and its name second (call).

## 8. How it is built

### 8.1 Stack (owner handed these over; all calls unless marked)

- Swift, single macOS app target. New repo at `~/repos/iptv-mac` (decided: new repo; name is a working name, as is the app's display name "Tuner").
- UI in SwiftUI, dropping to AppKit only where a large list or the grid needs it to stay smooth.
- Playback through VLCKit, stable 3.x line, as a prebuilt binary (decided: VLCKit). How it is integrated (Swift package vs vendored xcframework) is the builder's choice.
- Storage in a local SQLite database under Application Support, with SQLite full-text search (FTS5) for programmes and channels. Library choice is the builder's.
- No sandbox requirement (personal, not distributed). Local-network permission and Bonjour declarations are needed for cast discovery.

### 8.2 Parts

Each has one job and can be tested without the others.

| Part | Does | Depends on |
|---|---|---|
| **Playlist importer** | Parses M3U text into channel records (name, id, logo, group, URL, plus any unknown attributes kept verbatim). Tolerant of malformed lines. | — |
| **Guide importer** | Streams XMLTV into programme and guide-channel records without loading the file into memory. | — |
| **Matcher** | Links playlist channels to guide channels: exact id, then exact name, then normalised name (case, whitespace, punctuation, known prefixes). Records how each link was made. | Store |
| **Store** | SQLite: sources, channels, guide channels, programmes, favourites, recents, per-channel playback memory. Owns queries for now/next, events lists, grid windows and search. | — |
| **Refresher** | Schedules and runs source refreshes off the main thread, with conditional requests; swaps new guide data in atomically; prunes programmes that ended more than a day ago. | Importers, Matcher, Store |
| **Player** | Protocol: play(channel), stop, volume, state stream, stats stream, set output device. One implementation on VLCKit, one on AVPlayer for AirPlay. | — |
| **Playback supervisor** | The self-managing logic: watchdog, reconnect with back-off, per-channel adaptive buffer. Talks only to the Player protocol, so it is testable against a fake player. | Player, Store |
| **Cast** | Discovers Google Cast and AirPlay devices, presents one list, routes a session to the right Player implementation, holds the no-sleep assertion. | Player |
| **UI** | Sidebar, channel list, player pane, search, guide (events + grid), sources. Reads through Store queries; never parses or fetches. | all of the above |

### 8.3 Data flow

```
M3U file/URL ─► Playlist importer ─┐
                                   ├─► Store ◄─► UI (lists, search, guide)
XMLTV URL ────► Guide importer ────┤     ▲
                    Matcher ───────┘     │
                                         │ per-channel buffer memory, recents
UI: play(channel) ─► Playback supervisor ─► Player (VLCKit │ AVPlayer) ─► screen or cast device
```

### 8.4 Behaviour worth stating precisely

- **"Now" queries** must be fast enough to fill a 4,000-row list while scrolling: programmes indexed by channel and start time; the list only computes rows on screen.
- **Guide swap is atomic**: the owner never sees a half-loaded guide; the old data stays until the new import commits.
- **Times** are stored in UTC and shown in the Mac's local time zone.
- **Unmatched channels** are normal (two thirds of the guide's channels have no programmes and ~4% of names do not match). They are listed and playable; nothing is shown as an error.
- **Logos** load lazily with an on-disk cache; a missing or slow logo never delays a row.
- **Resources and stability (goal 10; specifics are calls)**: nothing runs on the main thread that can run elsewhere; no polling or timers beyond the ones a design section names; files and tables are streamed and batched, never loaded whole; every cache has a bound; data from files, the network or the database never reaches a force-unwrap or a trap.
- **Credentials**: source URLs live only in the database. Logs and the stats overlay show host names, never full URLs.

### 8.5 Errors

| Situation | Behaviour |
|---|---|
| Playlist or guide URL unreachable | Keep existing data, mark the source "last refresh failed" in Sources, retry on the next cycle. |
| Malformed playlist lines / XML | Skip the bad entries, import the rest, report a count in Sources. |
| Stream will not start | Supervisor's back-off, then "Channel unavailable" with Retry. |
| Stream stalls mid-play | Watchdog reconnects; buffer for that channel steps up. |
| Cast device disappears | Fall back to local playback paused, with a notice. |
| AirPlay refuses the stream | Say so; point to Screen Mirroring. |

### 8.6 Testing

- Unit tests with **synthetic** fixtures for: M3U parsing (quoted commas, missing attributes, odd prefixes, empty ids), XMLTV parsing (time zones, missing fields, entities), matching (id, name, normalised name, no match), event collapsing, now/next and search queries.
- Playback supervisor tested against a fake Player: stall → reconnect, repeated failure → back-off → give up, stutter → buffer step-up and persistence.
- A performance check that loads a synthetic 5,000-channel / 80,000-programme dataset and asserts search and "now" queries stay within an interactive budget.
- Resource checks alongside the timings (call): peak memory during a full-size guide import, and the app's CPU and memory while idle and while playing one channel.
- Real playback and casting are verified by hand against the owner's streams and devices.

## 9. Left to the builder

Exact keyboard bindings; visual styling within Mac conventions; database library and schema details; VLCKit integration method; buffer start values, stall thresholds and back-off schedule; refresh intervals; the name-normalisation rules beyond the ones listed; whether the grid is SwiftUI or AppKit; module/package layout; minimum window sizes and pane behaviour when narrow.

## 10. Order of work and early spikes

Two unknowns can change the plan, so they are checked first, as throwaway spikes:

1. **VLCKit on macOS with Google Cast** — confirm the prebuilt Mac framework plays one of the owner's channels in a bare window and that renderer discovery finds the Shield and can cast to it.
2. **Stream format** — probe a couple of the owner's channels to learn the container format. This costs minutes now and is the main predictor of whether the later Apple TV path can work. The AirPlay test itself (the same channels in AVPlayer, sent to an Apple TV) is deferred with the feature.

Neither spike has been run. Spike 1 is run on the owner's Mac with the owner present, since it needs the owner's streams and Shield.

Note for both: the provider may limit simultaneous connections, so spikes should open one stream at a time and close it promptly.

**If spike 1 fails (call):**

- *VLCKit 3.x does not build, link or render on this macOS:* try the prebuilt VLCKit 4 package next. It is pre-release, but still a prebuilt binary and still approach 1.
- *Playback works but Google Cast discovery or casting does not:* build everything else as designed, leave Google Cast out, and go back to the owner with the options (own engine build, a hand-written Cast sender, or dropping it) before spending anything on them.
- Building libVLC from source is never chosen silently; it is approach 2, which the owner did not pick.

Then, in order: importers + store + matcher → main window with channel list and local playback → search → playback supervisor → guide (events, then grid) → sources screen and background refresh → Google Cast. The Apple TV path follows later, outside this sequence.

When the Apple TV work starts: if AVPlayer refuses the owner's streams outright, that path reduces to the Screen Mirroring guidance and the owner is told before any more is built on it.

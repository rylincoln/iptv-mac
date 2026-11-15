# Spike results — November 2026

Throwaway spikes from plan 1, Part A. No URLs or tokens are recorded here; hosts are described, not quoted.

## Stream format

Probed 2026-11-14 with `curl` (headers) and `ffprobe`, three channels, one connection at a time.

| # | Group | HTTP | Redirect | Final content type | Container | Video | Audio | Resolution | Frame rate |
|---|---|---|---|---|---|---|---|---|---|
| 1 (first entry) | US Sports | 302 → 200 | yes, to a `workers.dev` subdomain over HTTPS | `application/octet-stream` | `mpegts` | h264 | aac | 1280×720 | 59.94 |
| 2 | United States | 302 → 200 | yes, to a bare IPv4 address over **plain HTTP** | `video/mp4` (wrong; the body is MPEG-TS) | `mpegts` | h264 | aac | 1280×720 | 29.97 |
| 3 | US Sports | 302 → 200 | yes, to a bare IPv4 address over **plain HTTP** | `video/mp4` (wrong; the body is MPEG-TS) | `mpegts` | h264 | aac | 1920×1080 | 59.94 |

Findings:

- **All three are raw MPEG-TS over HTTP, not HLS.** There is no playlist/manifest; the response is one endless transport stream.
- Every playlist URL answers `302` to a different edge host. Two of three edges were bare IP addresses on plain HTTP, so the app must allow non-HTTPS loads (the planned `NSAllowsArbitraryLoads`) and must log only the host.
- The `Content-Type` header is unreliable (`application/octet-stream`, `video/mp4`) and cannot be used to detect the format.
- The `Range` request was ignored: the server kept sending until the client hung up. Roughly 5–10 Mbit/s observed (9–18 MB in 15 s).
- Two streams joined mid-GOP: the decoder reported missing PPS until the first keyframe arrived. A short stretch with no picture at tune-in is normal and is not a start failure.
- All three probed URLs happen to end in a numeric path segment; no difference in behaviour was seen between groups.

## VLCKit and Google Cast

Run 2026-11-14 on macOS 27.2, Apple silicon, Command Line Tools only (no Xcode), Swift 6.4.2.

**Engine**

- VLCKit **3.7.3** (`VLCKit-3.7.3-319ed2c0-79128878.tar.xz` from VideoLAN's cocoapods/prod directory), SHA-256 `019afdae4e2e2d0f3ac325fac8f7ba0af25dca70b9d157df7d60db88e0be8e5d`. Fetched by `scripts/fetch-vlckit.sh`.
- The archive ships a real `VLCKit.xcframework` (one slice, `macos-arm64_x86_64`), so it is linked as a SwiftPM `.binaryTarget(name: "VLCKit", path: …)`. No `unsafeFlags` needed. `swift build` compiles and links it with Command Line Tools alone. The only noise is two harmless `ld: warning: search path … not found` lines.
- SwiftPM requires the binary target path to be inside the package; for the root package `Vendor/VLCKit.xcframework` satisfies that directly.
- **Runtime lookup:** the framework's install name is `@loader_path/../Frameworks/VLCKit.framework/Versions/A/VLCKit`, and SwiftPM adds no matching rpath, so `swift run` fails at launch with "Library not loaded". That layout is exactly an app bundle (`Contents/MacOS/<exe>` beside `Contents/Frameworks/`), so `scripts/bundle.sh` works without an extra rpath. To run the bare executable from `.build`, start the binary directly with `DYLD_FRAMEWORK_PATH` pointing at the build products directory (`swift run` strips `DYLD_*`).

**API names that work (VLCKit 3.7.3, from Swift)**

- View: `VLCVideoView(frame:)` (an `NSView`) assigned to `VLCMediaPlayer.drawable`.
- Media: `VLCMedia(url:)`, `media.addOption(":network-caching=1000")`, `player.media = media`, `player.play()`, `player.stop()`.
- Position: `player.time.intValue` (milliseconds, `Int32`).
- Statistics: `player.media.statistics` is a `VLCMediaStats` struct. Useful fields: `displayedPictures`, `decodedVideo`, `decodedAudio`, `lostPictures`, `lostAudioBuffers`, `readBytes`, `inputBitrate`, `demuxBitrate`, `demuxDiscontinuity`, `demuxCorrupted`. The older per-field properties (`numberOfDisplayedPictures`, …) are deprecated.
- `inputBitrate` × 8000 gives kbit/s (observed 3,000–19,000, jumpy; `demuxBitrate` × 8000 is steadier at about 6,000 for a 720p60 channel).
- State: `player.state` (`VLCMediaPlayerState`: `.stopped .opening .buffering .ended .error .playing .paused .esAdded`), delegate `mediaPlayerStateChanged(_:)`, `VLCMediaPlayerStateToString(_:)`; `player.isPlaying`.
- Renderers: `VLCRendererDiscoverer.list()` → descriptions; `VLCRendererDiscoverer(name:)`, `.delegate`, `.start()`, `.stop()`; delegate `rendererDiscovererItemAdded(_:item:)` / `rendererDiscovererItemDeleted(_:item:)`; `VLCRendererItem.name`, `.type`, `.flags`; `player.setRendererItem(_:)` before `play()`.

**`player.state` cannot be trusted as "is it playing"** — on a healthy stream the delegate fired `Playing` once, then a burst of `ESAdded` and `Buffering` events within 200 ms, and `player.state` then read `Buffering` for the entire 20 s of smooth playback while `isPlaying` was `true` and every counter advanced. Consequences for the build:

- `VLCPlayer` (Task 12) must not map VLCKit's `.buffering` straight onto `PlayerState.buffering`, or the supervisor's stutter rule (three playing→buffering transitions in a minute) will fire on every tune-in. Derive `.playing` from advancing counters / `isPlaying`, and treat `.buffering` and `.esAdded` events after first picture as noise unless progress has actually stopped.
- Progress (position, displayed pictures, decoded audio) is the only dependable health signal, as the supervisor design already assumes.

**Local playback**

- Time from `play()` to first displayed picture and first decoded audio: **about 1.0 s** with `:network-caching=1000` (720p60 channel).
- Over 20 s: 0 lost pictures, 1 lost audio buffer (at start), 0 discontinuities, position advancing in step with the wall clock.
- Owner confirmed picture and sound in the window.

**Google Cast**

- Discovery: VLCKit lists one renderer discoverer, `Bonjour_renderer`. It **found the Shield** within half a second, reported as type `chromecast`, flags `3` (audio and video). No local-network prompt appeared for the terminal during this run; the bundled app may still be asked once.
- Casting itself: **not tested.** The owner chose to skip the cast run on the day. Whether `setRendererItem` actually puts these MPEG-TS streams on the TV is still unknown and must be checked before plan 4 is written.

**Stall behaviour**

- **Not tested.** The owner chose to skip the Wi-Fi off/on run. What VLCKit reports during a network drop (state changes, frozen counters, self-recovery) is unknown, so the watchdog starts from the plan's default thresholds and is calibrated by hand in Task 15's Wi-Fi checks.

**Fallback rules:** VLCKit 3.x links, renders and plays, so VLCKit 4 was not tried and nothing was built from source.

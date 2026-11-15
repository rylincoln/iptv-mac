# Supporting Apple TV: a tvOS app, or AirPlay from the Mac

Date: 2026-11-15
Status: research only. No source in this repository was changed, the app was not launched and no stream was played. One build was run, outside the repository: a scratch copy of `Sources/TunerCore` compiled for tvOS (3.2), then deleted.

## 1. The question

The owner asked to "research how to also support apple tv". That can mean two different things, and they cost very different amounts.

- **Reading A, a tvOS app.** Tuner runs on the Apple TV box itself, driven by the Siri Remote, and fetches the streams itself.
- **Reading B, AirPlay from the Mac.** Tuner stays a Mac app, and the picture is sent to an Apple TV on the network.

**Which is meant.** The written record points to B. The design spec lists "Apple TV casting" as wanted but deferred until an Apple TV is on the network (`docs/superpowers/specs/2026-11-14-iptv-mac-client-design.md:27`, `:33`), describes it as an AirPlay hand-off (`:155-165`), and never mentions tvOS. "Also support Apple TV" reads naturally as "as well as the Shield". Against that: the spec's non-goals name "iPhone/iPad versions" but not a tvOS version (`:33`), and the owner's current player, UHF, is the kind of app that exists on Apple TV **[general knowledge]**. So B is the likelier meaning, held with moderate confidence. It matters less than it might, because the findings below say that the proper form of B probably cannot play the owner's streams, and that A can. Section 6 asks the owner directly.

### How claims are marked

- A URL or `file:line` after a statement means it was read there for this note. Apple documentation was read in its JSON form (`developer.apple.com/tutorials/data/...`); the links given are the ordinary pages for the same documents.
- **[checked here]** means established by a command run for this note (a directory listing, a published manifest, a compile).
- **[inferred]** means reasoned from sources and the code, not stated by either.
- **[general knowledge]** means not read in a source for this note.
- **[not verified]** means it can only be settled on a device, in a simulator, or by playing a stream, and was not.

## 2. What the project has today

- **A Swift package, no Xcode project.** One platform, `.macOS(.v26)` (`Package.swift:6`). Three targets: the library `TunerCore` in Swift 6 mode, the binary target `VLCKit` at `Vendor/VLCKit.xcframework` (`Package.swift:19`), and the executable `Tuner`. `scripts/bundle.sh` assembles `Tuner.app` by hand and signs it ad hoc; `scripts/release.sh` zips it. There is no developer signing identity and no notarisation (`README.md`, Install).
- **The engine** is VideoLAN's prebuilt VLCKit 3.7.4 for macOS, fetched and checksummed by `scripts/fetch-vlckit.sh`. Its xcframework has one slice, `macos-arm64_x86_64` (`docs/spikes/2026-11-spike-results.md:31`; `Vendor/VLCKit.xcframework/Info.plist` **[checked here]**).
- **All engine code is one file**, `Sources/Tuner/VLCPlayer.swift` (145 lines), behind the `Player` protocol in `Sources/TunerCore/Playback/Player.swift`. The reconnect logic (`PlaybackSupervisor`) talks only to that protocol. The spec planned a second `Player` on AVPlayer for AirPlay (`...design.md:194`); it has not been written.
- **`TunerCore` imports only Foundation, GRDB, Synchronization and zlib** **[checked here: grep of every `import`]**. No AppKit. It holds the M3U and XMLTV parsers, the store (GRDB `DatabasePool`, `Sources/TunerCore/Store/Store.swift:24`, with FTS5 tables at `:92` and `:117`), import, search, and the playback supervisor.
- **`Sources/Tuner` is the Mac app** and is AppKit-bound in nine of its seventeen files (3.2 lists them).
- **The library lives** at `~/Library/Application Support/Tuner/tuner.sqlite` (`Sources/Tuner/AppModel.swift:160-164`); logos are cached under Caches (`Sources/Tuner/LogoCache.swift:55-56`). Source URLs, which embed the account's credentials, live only in that database (`...design.md:218`).
- **What is already settled and is not re-derived here:**
  - Every probed channel is raw MPEG-TS over HTTP, not HLS: one endless transport stream, no playlist, `Range` ignored, unreliable `Content-Type`, and a `302` that for two of three channels lands on a bare IP address over plain HTTP (`docs/spikes/2026-11-spike-results.md:17-20`).
  - The spike's conclusion on Apple TV: AirPlay external playback is "unlikely" to accept these streams as they are; expect "a local HLS repackaging step or the Screen Mirroring fallback". Not tested, for want of an Apple TV (`...spike-results.md:67-69`).
  - The spec's intended AirPlay design: an "AirPlay…" entry opening the system picker, an AVPlayer path for that channel, Screen Mirroring as the stated fallback, and the local stream closed before the Apple TV opens its own (`...design.md:159-165`, `:75`, `:229`, `:262`).
  - The provider allows two simultaneous connections, and a stream an Apple TV fetches for itself counts as one (`...design.md:69-75`).
  - Google Cast: discovery found the Shield; casting itself was never tested (`...spike-results.md:56-59`). No cast code is in `Sources/` today **[checked here: no `setRendererItem` or `VLCRendererDiscoverer` anywhere]**.

## 3. Findings: Reading A, a tvOS app

### 3.1 The engine on tvOS

**VLCKit 3.x has a prebuilt tvOS build at the same version the Mac uses.**

- CocoaPods lists **TVVLCKit 3.7.4**, published 2026-09-30, the same day as the Mac's 3.7.4 **[checked here: `trunk.cocoapods.org/api/v1/pods/TVVLCKit`]**. Its podspec gives the licence as LGPLv2.1, the platform as `tvos: 10.2`, the product as `TVVLCKit.xcframework`, and the source as `TVVLCKit-3.0-20260930-0854.tar.xz` on VideoLAN's server with SHA-256 `07892cae8e59e95a23f1fcf11692f802eae106312aa5ad9782faa2556b2d65d5` **[checked here: `cdn.cocoapods.org/Specs/.../TVVLCKit/3.7.4/TVVLCKit.podspec.json`]**. The archive is in VideoLAN's listing at 131 MB (https://download.videolan.org/pub/cocoapods/prod/). It was not downloaded.
- **Slices.** VLCKit's 3.0 build script builds tvOS for `arm64` on the device and `x86_64 arm64` on the simulator, and joins them with `xcodebuild -create-xcframework` (https://code.videolan.org/videolan/VLCKit/-/blob/3.0/buildMobileVLCKit.sh, lines 231-235 and 1169-1200). So the archive should hold `tvos-arm64` and `tvos-arm64_x86_64-simulator`. **[inferred from the script; the archive's own `Info.plist` was not read]**
- VLCKit's CI builds TVVLCKit on runners tagged `macos-xcode26` (https://code.videolan.org/videolan/VLCKit/-/blob/3.0/.gitlab-ci.yml, jobs `continous-TVVLCKit` and `dev-artifacts-TVVLCKit`).
- **API.** VLCKit's README: "Except as indicated, all the APIs are the same on macOS, iOS and tvOS" (https://code.videolan.org/videolan/VLCKit/-/blob/master/README.md). The player's `drawable` "can be any UIView or NSView or instances of VLCVideoView / VLCVideoLayer if running on macOS" (https://code.videolan.org/videolan/VLCKit/-/blob/3.0/Headers/Public/VLCMediaPlayer.h, line 252). So `VLCPlayer.swift` ports with two changes: the module name (`TVVLCKit`, not `VLCKit`) and a plain `UIView` in place of `VLCVideoView` (`Sources/Tuner/VLCPlayer.swift:20`, `:31`). **[inferred]**
- **Risk: OpenGL ES.** The 3.x podspec links `OpenGLES` (same podspec), so the 3.x picture on tvOS is drawn with OpenGL ES. Apple deprecated that API in tvOS 12; the framework is still in the tvOS 27.2 SDK **[checked here: `AppleTVOS27.2.sdk/System/Library/Frameworks/OpenGLES.framework`, `EAGL.h` marks `tvos(9.0, 12.0)`]**. It works today and VLC for Apple TV ships on this line, but it is a deprecated path, and how much CPU and power it costs next to the Mac build is **[not verified]**.
- **Streams.** The engine is the same libVLC 3.0.x that already plays the owner's MPEG-TS channels on the Mac (`...spike-results.md:52-54`), and VLCKit's README names exactly this case: "a live stream hailing from some weird media server". That it plays them equally well on an Apple TV is **[not verified]**: hardware decoding, time to first picture and stall behaviour on Apple TV hardware need a device.

**The VLCKit 4 alpha is one binary for every Apple platform, tvOS included, and is not the better choice here.**

- VLCKit 4.0.0a26 (2026-11-09) is a single `VLCKit.xcframework` with deployment targets `osx 10.13, tvos 11.0, ios 9.0, visionos 1.0, watchos 7.4` **[checked here: `cdn.cocoapods.org/Specs/.../VLCKit/4.0.0a26/VLCKit.podspec.json`]**. VLCKit's own `Package.swift` declares it as a SwiftPM binary target by URL and checksum, with `.tvOS(.v12)` (https://code.videolan.org/videolan/VLCKit/-/blob/master/Package.swift).
- Its zip holds these slices **[checked here: the zip's directory was read with an HTTP range request; the archive was not downloaded]**: `ios-arm64`, `ios-arm64_x86_64-simulator`, `macos-arm64_x86_64`, `tvos-arm64`, `tvos-arm64_x86_64-simulator`, `watchos-*`, `xros-*`.
- It is **910 MB** to download, against 96 MB (Mac) plus 131 MB (tvOS) for 3.7.4 (same listing, `/unstable`).
- It is an alpha on "libvlc HEAD leading to v4", with "all API deprecated in version 3" removed and event handling rewritten (https://code.videolan.org/videolan/VLCKit/-/blob/master/NEWS). The spec allows VLCKit 4 only as the fallback if 3.x fails (`...design.md:256`), and 3.x has not failed.
- What 4 would buy on tvOS: a picture drawn through `AVSampleBufferDisplayLayer` instead of OpenGL ES (VLC master has `modules/video_output/apple/VLCSampleBufferDisplay.m`, https://code.videolan.org/videolan/vlc/-/tree/master/modules/video_output/apple), and picture in picture, which the NEWS file claims for "iOS and macOS" only.

**Licence.**

- VLCKit is LGPL 2.1 or later; its README says the licence "allows our software to be included in proprietary apps, as long as you follow the license" and lists the duties: publish changes to VLCKit, tell the user it is embedded, give access to its code (same README, FAQ). VideoLAN's relicensing notice answers "Can I build non open-source libVLC-based applications?" with "Yes. Please check the legality of the re-distribution" (https://www.videolan.org/press/lgpl-libvlc.html).
- VLC for Apple TV is on the App Store; VideoLAN states it "is bi-licensed under the Mozilla Public License Version 2 as well as the GNU General Public License Version 2 or later" and "requires tvOS 11.0 or later" (https://www.videolan.org/vlc/download-appletv.html). So an App Store app on top of the LGPL engine exists, published by the engine's own authors.
- VLCKit 4 "removed support to compile VLCKit as a static framework" (NEWS, above), and 3.x for tvOS is a dynamic `TVVLCKit.xcframework`. Tuner's existing position carries over unchanged: an unmodified, dynamically linked framework, public MIT source, the notice and the LGPL text shipped in the bundle (`THIRD-PARTY-NOTICES.md`). **[inferred]** Whether App Store distribution terms sit comfortably with the LGPL's relinking right is a known argument that VideoLAN's pages do not settle **[general knowledge]**; it only arises if the app goes to TestFlight or the App Store.

**AVPlayer alone on tvOS is not an option for these streams.** Apple's tvOS guide: "All video playback on Apple TV is based on HTTP Live Streaming and FairPlay Streaming" (https://developer.apple.com/library/archive/documentation/General/Conceptual/AppleTV_PG/index.html, archived). HLS is an index file listing short media files (https://developer.apple.com/documentation/http-live-streaming); the owner's channels are a single endless transport stream with no index (`...spike-results.md:17`). The spec rejected an AVPlayer-only app for the same reason (`...design.md:85`).

### 3.2 What carries over

**`TunerCore` compiles for tvOS as written.** **[checked here]** A scratch package outside the repository, holding an unmodified copy of `Sources/TunerCore` with `platforms: [.macOS(.v26), .tvOS(.v26)]` and GRDB 7.12.0, was built with `xcodebuild -destination 'generic/platform=tvOS'`: build succeeded, no errors. What that rests on:

- GRDB supports tvOS 13 and later (https://github.com/groue/GRDB.swift/blob/v7.12.0/Package.swift, `platforms`; README "Requirements").
- `Mutex` (`Sources/TunerCore/SharedWork.swift:24`, `CappedDownload.swift:43`) needs tvOS 18 (https://developer.apple.com/documentation/synchronization/mutex).
- `zlib` (`Sources/TunerCore/Gunzip.swift:2`), `URLSession` and `FileManager` are all present in the tvOS SDK (the compile).
- The Application Support path and the `ProcessInfo` activity calls are in the app target, not the library (`Sources/Tuner/AppModel.swift:163`, `:287-291`), so nothing macOS-only had to be stubbed.

**Compiling is not running.** Three things are still open:

- **FTS5 at run time.** GRDB compiles its FTS5 API in for every platform ("FTS5 is enabled by default since GRDB 6.7.0", https://github.com/groue/GRDB.swift/blob/v7.12.0/README.md), and the store creates its tables with raw `USING fts5` SQL, which needs the system SQLite to have FTS5 built in. The tvOS 27.2 SDK ships SQLite 3.54.0, the same version as the macOS SDK **[checked here: `sqlite3.h` in both SDKs]**, which makes it likely. That tvOS's library has FTS5 enabled is **[not verified]**; no tvOS simulator runtime is installed on this Mac to run the tests against.
- **Speed.** Importing a 23 MB guide and filling the FTS index on an Apple TV's processor, and the memory it peaks at, are **[not verified]**. The parsers stream and batch already (`...design.md:217`).
- **Where the database may live** (3.3).

**What in `Sources/Tuner` is Mac-only and needs a tvOS counterpart.**

| File | Bound to | On tvOS |
|---|---|---|
| `VLCPlayer.swift` | `VLCVideoView` (`:20`, `:31`), module `VLCKit` | Shared with a small `#if`: `UIView` drawable, `import TVVLCKit` |
| `VideoView.swift` | `NSViewRepresentable` (`:6`) | `UIViewRepresentable` (tvOS 13, https://developer.apple.com/documentation/swiftui/uiviewrepresentable) |
| `LogoCache.swift` | `NSImage`, `NSScreen` (`:30`, `:39`) | Same logic over `UIImage`/`CGImage`; decoding is ImageIO already |
| `AppModel.swift` | Application Support path (`:163`), `ProcessInfo` activity (`:287`) | Mostly shared. `beginActivity` exists on tvOS 9+ (https://developer.apple.com/documentation/foundation/processinfo/beginactivity(options:reason:)); whether it holds off the screen saver is **[not verified]** |
| `Views/WindowBridge.swift` | `NSWindow` full screen and the small floating picture | Nothing. A tvOS app is always full screen and has no windows |
| `Views/PlayerPaneView.swift` | `NSEvent.mouseLocation`, `NSCursor` (`:93`, `:372-373`) | Rewritten: no pointer on tvOS |
| `Views/PlaylistFilePanel.swift` | `NSOpenPanel` (`:9`) | Nothing. No user-visible file system |
| `Commands.swift`, `TunerApp.swift` | `Commands`, `keyboardShortcut`, `Window` scene | None of the three exists on tvOS (https://developer.apple.com/documentation/swiftui/commands, `/view/keyboardshortcut(_:modifiers:)`, `/window`) |
| `Views/MainWindow.swift`, `SidebarView.swift`, `ChannelListView.swift`, `SearchResultsView.swift` | `NavigationSplitView`, typing-to-search with `onKeyPress` | Redesigned for the remote (3.4) |

In short: the library, the model's logic and the engine wrapper carry over; the views do not. The Mac views are about 1,500 lines **[checked here: `wc -l`]**, and a tvOS interface is a second set of about that size, not a port. **[inferred]**

### 3.3 Building, installing and storing

**No Xcode project.** SwiftPM has three product types, library, executable and plugin (https://developer.apple.com/documentation/packagedescription/product). There is no app product, and on tvOS there is no equivalent of `scripts/bundle.sh`'s freedom: a device will only run a bundle signed with a development certificate and carrying a provisioning profile. Apple documents one way to get those, Xcode's Signing & Capabilities pane on a project (https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices). Options, least to most departure from the rule:

1. Keep every line of code in the package (a `TunerTV` library target), and add the thinnest possible app project that only names the package product, the bundle identifier and the team. The rule becomes "no code in an Xcode project".
2. Hand-assemble and sign the tvOS bundle in a script, as on the Mac. Plausible for the simulator, which needs no signing. For a device it needs a profile obtained some other way: with a paid account one can be made on the developer site; with a free account only Xcode makes them. **[inferred; not verified]**
3. A Top Shelf extension (3.4), if wanted, is an app extension and needs a project regardless. **[inferred]**

**Getting it onto an Apple TV.**

- **Pairing.** In Xcode's Device Hub, "Pair Nearby Device"; on the Apple TV, Settings > Remotes and Devices > Remote App and Devices; "make sure that your Wi-Fi network has IPv6 enabled"; and "if you upgrade the operating system later, you'll need to pair the device again" (https://developer.apple.com/documentation/xcode/managing-your-simulated-and-physical-devices-in-device-hub).
- **Free Apple Account (Personal Team).** Allowed, with these limits in Apple's words: "You can register up to 3 devices, which expire after 7 days", "You can install up to 3 apps per device", and "Provisioning profiles that enable apps to be installed on a device will expire 7 days from issuance. You'll need to rebuild and reinstall your app to your device after expiration" (https://developer.apple.com/support/compare-memberships/). For a living-room app that means reinstalling from the Mac every week. Good enough for a spike, not for use.
- **Paid Apple Developer Program.** Needed for TestFlight and the App Store (same page). A development build installed from Xcode then lasts as long as its profile, about a year **[general knowledge]**; TestFlight builds expire after 90 days **[general knowledge]**. The program also unlocks the iCloud capabilities in 3.5 **[general knowledge]**, and would let the Mac app be notarised.
- **App Store review**, only if the app is published. The relevant guidelines: 5.2.2, "If your app uses, accesses, monetizes access to, or displays content from a third-party service, ensure that you are specifically permitted to do so", and 5.2.3, "Streaming of audio/video content may also violate Terms of Use" (https://developer.apple.com/app-store/review/guidelines/). A player that ships no content and asks for the user's own playlist is the usual shape for this category **[general knowledge]**. The spec says "No distribution, no accounts, no App Store" (`...design.md:16`), so this is a change of intent, not a detail.

**Storage.** Apple's statement, from the tvOS programming guide: "your app can only access 500 KB of persistent storage that is local to the device (using the NSUserDefaults class). Outside of this limited local storage, all other data must be purgeable by the operating system when space is low." And: "Your app can download the data it needs into its cache directory. Downloaded data is not deleted while the app is running. However, when space is low and your app is not running, this data may be deleted" (https://developer.apple.com/library/archive/documentation/General/Conceptual/AppleTV_PG/index.html). That guide is archived and dates from the first tvOS; no newer Apple statement replacing it was found, and what tvOS 27 does in practice is **[not verified]**.

What it means for a library of about 36 MB:

- The SQLite file goes in Caches and is **treated as a cache**: channels, guide and search index can all be rebuilt from the source URLs. Nothing in it may be the only copy of something the owner made. **[inferred]**
- The owner-made data is small: source URLs, favourites, recents, per-channel buffer memory. It must live in `UserDefaults` (within 500 KB) or iCloud, and be written back into a rebuilt database. Today favourites and recents are tables in the same database (`Sources/TunerCore/Store/Store.swift:75`, `:81`), so the store needs an export/restore seam it does not have. **[inferred]**
- After a purge the next launch has no channels until an import finishes: tens of seconds of "loading" at an unpredictable moment. This cuts against the standing goal of rock-solid behaviour and has to be designed for, not hoped away. **[inferred]**
- `DatabasePool` uses WAL (`Store.swift:24`), so a purge that removes one of the three files while the app is not running must be survived: open, fail, delete, rebuild. **[inferred]**

### 3.4 The interface

**Input is the focus engine, not a pointer or a keyboard.** "tvOS users rely on using directional gestures on a remote or game controller ... to reach every onscreen element, so you need to make sure that people can bring focus to every element in your app", and "Avoid displaying a pointer" (https://developer.apple.com/design/human-interface-guidelines/focus-and-selection). Remote buttons have fixed meanings: Back "returns to previous screen. Exits to Apple TV Home Screen"; Play/Pause plays and pauses (https://developer.apple.com/design/human-interface-guidelines/remotes).

**SwiftUI on tvOS.**

- `NavigationSplitView` exists (tvOS 16) but does not behave as on the Mac: "On watchOS and tvOS ... the navigation split view collapses all of its columns into a stack" (https://developer.apple.com/documentation/swiftui/navigationsplitview). `MainWindow`'s structure (`Sources/Tuner/Views/MainWindow.swift:23`) does not carry over.
- `TabView` with `.sidebarAdaptable` (tvOS 18): "macOS and tvOS always show a sidebar" (https://developer.apple.com/documentation/swiftui/tabviewstyle/sidebaradaptable). This is the closest system match to the Mac sidebar's sections.
- `focusable(_:)` (tvOS 15), `focusSection()` (tvOS 15), `onMoveCommand` (tvOS 13, "taps the edge of the Siri Remote"), `onPlayPauseCommand` (tvOS 13, tvOS only), `onExitCommand` (tvOS 13, "pressing the Menu button on tvOS") (https://developer.apple.com/documentation/swiftui/view/focusable(_:), `/focussection()`, `/onmovecommand(perform:)`, `/onplaypausecommand(perform:)`, `/onexitcommand(perform:)`). The Mac app already uses `onExitCommand` (`MainWindow.swift:52`).
- `onKeyPress` exists on tvOS 17 but only for "a hardware keyboard" (https://developer.apple.com/documentation/swiftui/view/onkeypress(_:action:)), so the Mac's type-anywhere-to-search (`Sources/Tuner/Views/ChannelListView.swift:204`) has no remote equivalent.
- `glassEffect` is available on tvOS 26 (https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)), so the overlays' look can match.

**The single-pane design maps well.** The Mac window is now the video with a channel drawer and a programme card over it (`...design.md:109-110`). Apple's guidance for live-viewing apps describes the same thing for a television (https://developer.apple.com/design/human-interface-guidelines/live-viewing-apps):

- "Consider using a content footer for browsing channels during playback ... Give it a subtle treatment, such as a darkening" and "Design a simple, predictable way for people to invoke and dismiss" it: the drawer, called up by a swipe and put away by Back.
- "Let people browse the EPG without leaving their current content."
- "Provide instant visual feedback when people change channels ... providing feedback can give the streaming content some time to load": the existing status overlay.
- "Feature live content prominently ... minimize the interval between starting your app and playing content."
- With the video full screen and no drawer, "let people use gestures to interact with the content, not to move focus" (focus-and-selection, tvOS): up/down can change channel.
- Some remotes have guide and channel buttons; apps handle `TVUserActivityTypeBrowsingChannelGuide` and `UIPress.PressType.pageUp`/`pageDown` to open the guide and change channel (https://developer.apple.com/documentation/tvservices/providing-channel-navigation).
- Layout: "Inset primary content 60 points from the top and bottom of the screen, and 80 points from the sides" (https://developer.apple.com/design/human-interface-guidelines/layout). Row heights, type sizes and the 4,000-row list all need retuning for three metres' distance. Scrolling that list with a remote, and its frame rate, are **[not verified]**.

**Text entry is the weak point.** "tvOS displays a linear virtual keyboard when people select a text field using the Siri Remote" (https://developer.apple.com/design/human-interface-guidelines/virtual-keyboards); "Minimize text entry in your tvOS and watchOS apps" (`/text-fields`); "People typically don't want to do a lot of typing in tvOS ... provide popular and context-specific search suggestions, including recent searches" (`/search-fields`).

- *Search* is the owner's first-ten-seconds task (`...design.md:14`). `searchable` exists on tvOS 16 (https://developer.apple.com/documentation/swiftui/view/searchable(text:placement:prompt:)). It works, but slowly; recent searches, a Sports section and dictation through the remote **[general knowledge]** have to carry more of the load than on the Mac.
- *The playlist address* is long and carries credentials. Typing it with a remote is not reasonable. A nearby iPhone can be used as the keyboard **[general knowledge]**; the better answers are in 3.5.

**Top Shelf.** A Top Shelf extension (`TVTopShelfContentProvider`, tvOS 13) supplies items shown on the Home Screen when the app is in the top row; "your app doesn't need to be running", and the extension's memory limit is "significantly lower than for apps" (https://developer.apple.com/documentation/tvservices/tvtopshelfcontentprovider, https://developer.apple.com/documentation/tvservices). A "sectioned content row ... can work well to highlight recently viewed content ... or favorites" (https://developer.apple.com/design/human-interface-guidelines/top-shelf): Recents, one press from the Home Screen. It needs a shared container between app and extension and the same purge-tolerance as 3.3. Optional, and not for a first version.

**Picture in picture.** `AVPictureInPictureController` is on tvOS 14; it shows content "from an AVPlayerLayer or AVSampleBufferDisplayLayer" (https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller/contentsource-swift.class). VLCKit 3.x on tvOS draws with OpenGL ES (3.1), which is neither, so there is no system picture in picture on the 3.x engine **[inferred]**. The Mac's small picture is a window trick (`Sources/Tuner/Views/WindowBridge.swift:129-152`) with no tvOS counterpart.

### 3.5 Sharing the library between the Mac and the Apple TV

| Way | Holds | Needs | Credentials go |
|---|---|---|---|
| iCloud key-value store | 1 MB in all, 1,024 keys (https://developer.apple.com/documentation/foundation/nsubiquitouskeyvaluestore). Enough for source URLs and a favourites list; not for the guide | The iCloud capability on both apps, hence a paid account **[general knowledge]**; and the Mac app signed with a real identity and a profile, not ad hoc, which changes `scripts/bundle.sh` and the release | Into the owner's iCloud |
| CloudKit | Structured records, tvOS 9+ (https://developer.apple.com/documentation/cloudkit) | As above, plus a schema and sync code | Into the owner's iCloud |
| The TV imports from the same URLs | Everything, rebuilt locally; nothing synchronised | The URL has to reach the TV once | Only to the provider, as now |
| The Mac hands its sources to the TV over the local network | Source URLs, favourites, recents | A small Bonjour service in the Mac app and a client on the TV; local-network permission. No account | Stay on the LAN |

Two notes. Favourites and recents follow a channel "by its stream URL first and its name second" (`...design.md:171`), and stream URLs contain the credentials, so a synchronised favourites list is a list of credentials unless it is keyed some other way (a hash, or the name). And the spec's rule is that source URLs are never "sent anywhere except to the provider" (`...design.md:67`); any iCloud route needs the owner to relax that knowingly.

The guide itself is never worth synchronising: both devices can fetch it, and it is rebuilt every refresh.

## 4. Findings: Reading B, AirPlay from the Mac

### 4.1 What AirPlay offers a Mac app

- **AirPlay video ("external playback").** `AVPlayer.allowsExternalPlayback` (macOS 10.11, default true) and `isExternalPlaybackActive` (https://developer.apple.com/documentation/avfoundation/avplayer/allowsexternalplayback). The picker is `AVRoutePickerView` (macOS 10.15), "a button that users tap to stream audio/video content to a media receiver"; on macOS it has a `player` property naming the `AVPlayer` to route (https://developer.apple.com/documentation/avkit/avroutepickerview, `/player`). It is a system button with a system popover, which is why the spec has an "AirPlay…" entry and not a device list (`...design.md:159`).
- **It routes an `AVPlayer`, and nothing else.** Apple's AirPlay page offers two API sets: `AVPlayer`/`AVQueuePlayer`, which "works well for video content", and `AVSampleBufferAudioRenderer` with `AVSampleBufferRenderSynchronizer` for apps that "require control over I/O", which is an audio renderer (https://developer.apple.com/documentation/avfoundation/supporting-airplay-in-your-app). No documented API sends an app's own decoded video frames to an Apple TV as AirPlay video. **[inferred from what the documentation offers]**
- **Screen mirroring** is a system feature the user turns on from Control Centre; it sends the screen, re-encoded by the Mac, whatever drew it **[general knowledge]**. No public API for an app to start it was found. Apple asks apps to "support both AirPlay streaming and mirroring" (https://developer.apple.com/design/human-interface-guidelines/airplay).

### 4.2 Can VLCKit's picture go out over AirPlay?

**Not as video.**

- libVLC has had one AirPlay-family module, the "Remote Audio Output Protocol (AirTunes) module", audio only, and it is listed under "Removed modules" for 3.0 as "RAOP stream output module" (https://code.videolan.org/videolan/vlc/-/blob/3.0.x/NEWS, lines 1762-1783 and 4437).
- The 3.0.x `modules/stream_out` directory has `chromecast` and nothing for AirPlay; master adds `dlna` and `hls`, still nothing for AirPlay (https://code.videolan.org/videolan/vlc/-/tree/3.0.x/modules/stream_out, `/master/modules/stream_out`).
- The framework the app ships contains `stream_out_chromecast` and no string matching `airplay`, `raop` or `airtunes` **[checked here: `strings` on `Vendor/VLCKit.xcframework/.../VLCKit`]**.
- VLC 4's new Apple audio output mentions "better AirPlay pause/seek/stop behavior" (https://code.videolan.org/videolan/vlc/-/blob/master/NEWS): that is audio routed by the system, not a video sender.

So with VLCKit rendering, the only way onto an Apple TV is the mirrored screen. That is what the spec already names as the fallback (`...design.md:162`), and it needs no code: full-screen video, then Screen Mirroring from Control Centre. Its cost is the Mac's: a second encode of the picture while it plays, the Mac awake, and quality and delay set by the mirroring encoder. Frame pacing of 59.94 fps sport through mirroring is **[not verified]**.

### 4.3 If AirPlay needs AVPlayer

**What AVPlayer plays.** HLS, and ordinary media files served over HTTP: "AirPlay is compatible with media delivered by progressive downloading or HTTP Live Streaming, but HTTP Live Streaming is preferred", in `.mp3, .aac, .m4a, .m4v, .mp4, and .mov` files or HLS, with `.ts` appearing only as HLS segments (https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/AirPlayGuide/Introduction/Introduction.html, `.../PreparingYourMediaforAirPlay/PreparingYourMediaforAirPlay.html`, archived).

**The owner's streams.** One nuance against a flat "no": on this Mac, AVFoundation lists `public.mpeg-2-transport-stream` among its asset types and `video/mp2t` among its MIME types **[checked here: `AVURLAsset.audiovisualTypes()` and `audiovisualMIMETypes()` on macOS 27.2]**, so a transport stream is not a foreign format to the Mac's player. What stands against these particular streams: they never end and have no length, the server ignores `Range`, and the `Content-Type` is `application/octet-stream` or a false `video/mp4` (`...spike-results.md:18-20`), where AVPlayer's file playback expects a seekable resource **[general knowledge]**. Whether AVPlayer on the Mac plays one is **[not verified]** and is a ten-minute test that needs no Apple TV (section 5). Even a yes on the Mac would not prove the Apple TV's own player accepts the same address: Apple's tvOS guide says all playback there is HLS (3.1).

**Who fetches.** In external playback the Apple TV is given the address and fetches the media itself; the Mac becomes the remote control. This is how the spec already reasons (`...design.md:71`, `:75`), and third-party documentation says the same, but no Apple page stating it outright was found: **[general knowledge; secondary sources only]**. If so:

- it is a second device opening a provider connection, so the local stream must close first, as the spec says, and a hand-back opens another;
- the stream address, credentials included, is handed to the Apple TV, and the `302` to a plain-HTTP bare IP address (`...spike-results.md:18`) then has to be acceptable to the Apple TV's player, which is **[not verified]**;
- the supervisor's health signals (decoded frames, position) come from an `AVPlayer` that is no longer decoding anything locally; what it reports during a stall on the Apple TV is **[not verified]**.

**The hybrid.** VLCKit plays locally as now; an AirPlay session swaps in an `AVPlayer`-backed `Player`. Two forms:

1. **Direct** (the spec's design). The AVPlayer is given the channel's address. Small to medium to build: a second `Player`, an `AVRoutePickerView`, hand-off rules. It only works if 4.3's test says AVPlayer takes the streams, which the evidence says is unlikely.
2. **Local repackaging** (the spike's suggestion, `...spike-results.md:69`). The Mac keeps the one provider connection, cuts the transport stream into HLS segments, and serves a rolling playlist to the Apple TV from a small HTTP server on the LAN. This fixes the format, the connection count and the credentials (they never leave the Mac). But the engine cannot do it for us: the shipped VLCKit 3.7.4 has no HLS output (no `livehttp` string in the binary **[checked here]**; libVLC's `stream_out/hls` exists only on master). So the segmenter and the server would be Tuner's own code: a transport-stream parser that finds keyframes, a segment store, a playlist writer, an HTTP listener. Large, and a new always-on moving part with its own failure modes, several seconds of added delay by HLS's nature **[general knowledge]**, and the Mac must stay awake. It runs against the owner's stability goal more than anything else in this note.

## 5. Options

Size is the work in this repository: small (days), medium (a week or two), large (several weeks), very large (months, or open-ended).

| Route | The owner gets | Needs | Cost here | Risk |
|---|---|---|---|---|
| **B0. Screen Mirroring, documented** | The Mac's picture on the TV today | An Apple TV. Nothing else | None, or a line in the README | Quality and delay are the system's; Mac does the work; not tested with these streams |
| **B1. AirPlay hand-off, direct** (spec 7.6) | A proper AirPlay button; the Apple TV plays the channel itself | An Apple TV; the streams must be ones AVPlayer accepts | Small to medium: `AVPlayerPlayer` beside `VLCPlayer.swift`, a picker in `PlayerPaneView`, hand-off in `AppModel` | **Probably does not work at all** for raw MPEG-TS. Second provider connection; credentials go to the TV |
| **B2. AirPlay with local HLS repackaging** | The same button, working for any stream, one provider connection | An Apple TV; the Mac awake while watching | Large: segmenter, local HTTP server, second `Player`, tests | Much new code on the playback path; added delay; hardest route to make rock solid |
| **A1. tvOS app, personal** | Tuner on the Apple TV, remote in hand, no Mac involved | An Apple TV; the paid Developer Program in practice (free signing lapses every 7 days); an app project or a signing script | Large: `Package.swift` gains `.tvOS` and a `TVVLCKit` binary target; `scripts/fetch-vlckit.sh` fetches a second archive; `VLCPlayer`, `LogoCache`, `AppModel` are shared with `#if`; a new `Sources/TunerTV` interface; storage rework (3.3); a way to get the playlist address onto the TV (3.5) | Engine on a deprecated OpenGL ES path; purgeable storage; run-time FTS5, import speed and list scrolling unproven on the hardware |
| **A2. tvOS app, published** | The same, installable by anyone, with TestFlight or the App Store | All of A1, plus App Review | Very large: A1, plus review, an LGPL position for store distribution, support for other people's playlists | Rejection under 5.2.x; a commitment the spec explicitly did not want (`...design.md:16`) |
| **A-alt. tvOS app on AVPlayer** | — | — | — | Ruled out: cannot play the owner's streams (3.1) |

A1 and B0 are not exclusive: B0 costs nothing and works the day an Apple TV is plugged in.

## 6. Recommendation

1. **Do not build B1 or B2 on what is known today.** B1 most likely fails on the stream format, and B2 buys an AirPlay button at the price of a home-made live repackager on the playback path, which is the opposite of the standing goal. Keep Screen Mirroring (B0) as the answer for "Mac to Apple TV", as the spec already says it will be if AVPlayer refuses the streams (`...design.md:262`).
2. **If the aim is to watch on the television, build the tvOS app (A1) on TVVLCKit 3.7.4.** It is the only route where these streams play natively: same engine and version as the Mac, one provider connection, credentials going only to the provider, no Mac needed in the room. The library already compiles for tvOS unchanged, and the single-pane design is close to what Apple recommends for live television. It is a large piece of work and should be its own design and plan, not an add-on.
3. **Cheapest first steps, in order, each retiring the biggest unknown left:**
   - **Ask the owner which reading they meant and whether an Apple TV is in the house** (below). Free, and it halves this note.
   - **For B, ten minutes, no Apple TV:** with the owner present, point a bare `AVPlayer` on the Mac at one channel, one connection, and see whether it shows a picture. A no closes B1 for good. A yes reopens it and justifies borrowing an Apple TV.
   - **For A, half a day, no Apple TV and no account:** install the tvOS simulator runtime; run the `TunerCore` tests there (settles FTS5 at run time); fetch TVVLCKit 3.7.4 and confirm its slices; put one `VLCMediaPlayer` in a bare simulator app. Whether the simulator shows VLCKit's OpenGL ES picture at all is itself unknown, so the playback half of this may only be answerable on a device.
   - **Then, with an Apple TV and a free Apple Account:** the same bare app on the device for a week: time to first picture, CPU, a stall and a reconnect, an import of the real guide, and what survives when the app has been closed for a few days.

## 7. What could not be verified

- Whether the owner's channels play in AVPlayer, on the Mac or on an Apple TV (no stream was played).
- Anything on Apple TV hardware or in a tvOS simulator: VLCKit playback, decode cost, FTS5 at run time, import time and memory, list scrolling, purge behaviour, whether `ProcessInfo` activities hold off the screen saver.
- The slice list inside the TVVLCKit 3.7.4 archive (inferred from the build script; the archive was not downloaded).
- That the Apple TV fetches the media itself during AirPlay external playback: assumed by the spec and stated by secondary sources, not found in an Apple document.
- Current tvOS storage behaviour. Apple's only statement found is the archived 2015-era guide.
- Whether a hand-assembled, script-signed tvOS bundle can be installed on a device without any Xcode project.
- Development-profile and TestFlight lifetimes, the iCloud capability's need for a paid account, and the Developer Program's fee are from general knowledge, not read for this note.

## 8. Questions for the owner

1. Which did you mean: Tuner running **on** the Apple TV, or the Mac **sending** its picture to one? Or simply "I want to watch on the television, whichever works"?
2. Is there an Apple TV on the network now? Which model? The spec deferred all of this until there was one.
3. Would you pay for the Apple Developer Program? Without it a tvOS app has to be reinstalled from the Mac every seven days. With it, the Mac app could also be notarised.
4. Is this still for you alone, or would a tvOS app be published? Publishing brings App Review and reverses "no distribution, no App Store".
5. May the playlist address, with its credentials, be stored in your iCloud so the Apple TV can pick it up, or must it stay on your own network and devices?
6. For the tvOS app, is an Xcode project acceptable if it holds no code, only the bundle identifier and signing settings?
7. Is Screen Mirroring from the Mac good enough as the "Mac to Apple TV" answer if the tvOS app exists, so that AirPlay hand-off can be dropped from the spec?

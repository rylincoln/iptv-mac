# Tuner

A native macOS client for IPTV: it imports an M3U playlist and an XMLTV guide, lists channels with
what is on now, searches channels and programmes, and plays through VLCKit with reconnects it
manages itself. A guide shows the week's programmes as a list of events or as a grid of channels
against time. The video can fill the screen, or shrink to a small picture that floats over other
apps.

Requires macOS 26 or later and a Swift 6.2 or later toolchain. There is no Xcode project; it is a
Swift package.

## Install

Download `Tuner-<version>-macos-arm64.zip` from the Releases page, unzip it and move `Tuner.app` to
Applications. Apple silicon only. The app is not notarised, so the first time, Control-click it,
choose Open, and confirm (or allow it under System Settings > Privacy & Security).

## Build

```sh
scripts/bundle.sh        # fetches VLCKit, builds, and writes build/Tuner.app
open build/Tuner.app
swift test               # the TunerCore tests
```

## Layout

- `Sources/TunerCore` — the library: playlist and guide parsing, the SQLite store, search,
  imports, the playback supervisor. No UI.
- `Sources/Tuner` — the SwiftUI app.
- `docs/` — the design spec, plans, spike results and research notes.

## Private data

Playlist files, stream addresses and guide addresses carry account credentials. They are never
committed: `sample_files/` and `*.m3u*` are git-ignored, and tests use the host `example.invalid`.

## Licence

MIT; see `LICENSE`. The app links VLCKit (LGPL 2.1 or later) and GRDB.swift (MIT); see
`THIRD-PARTY-NOTICES.md`.

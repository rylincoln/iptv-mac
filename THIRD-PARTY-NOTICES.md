# Third-party software

Tuner's own source code is under the MIT licence (see `LICENSE`). It builds on the following, none
of which is stored in this repository.

## VLCKit and libVLC

- What: the playback engine. `scripts/fetch-vlckit.sh` downloads VideoLAN's prebuilt VLCKit 3.7.3
  for macOS, checks its SHA-256, and unpacks it to `Vendor/` (git-ignored). `scripts/bundle.sh`
  copies it, unmodified, into `Tuner.app/Contents/Frameworks/`.
- Licence: GNU Lesser General Public License, version 2.1 or later (`LICENSES/LGPL-2.1.txt`, also
  inside the app at `Contents/Resources/`).
- Source: https://code.videolan.org/videolan/VLCKit and https://code.videolan.org/videolan/vlc
- How the LGPL is met: VLCKit is a separate, dynamically linked framework that anyone can replace
  with their own build; it is not modified; and Tuner's source is public, so the app can be
  rebuilt against another VLCKit. Anyone who passes on a built `Tuner.app` must pass on this
  notice and a copy of the LGPL with it, and say where the VLCKit source can be had (above).

## GRDB.swift

- What: the SQLite toolkit behind the library store, fetched by Swift Package Manager.
- Licence: MIT. Copyright (C) 2015-2025 Gwendal Roué.
- Source: https://github.com/groue/GRDB.swift

## SQLite

- What: the database engine, as shipped with macOS.
- Licence: public domain.

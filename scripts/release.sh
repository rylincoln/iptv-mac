#!/bin/bash
# Builds build/Tuner.app and zips it as build/Tuner-<version>-macos-arm64.zip, the file a release
# carries. The version is CFBundleShortVersionString in Resources/Info.plist.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
scripts/bundle.sh
ZIP="build/Tuner-$VERSION-macos-arm64.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build/Tuner.app "$ZIP"
shasum -a 256 "$ZIP"

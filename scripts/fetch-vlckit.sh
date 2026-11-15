#!/bin/bash
# Fetches the pinned VLCKit 3.x macOS binary from VideoLAN and unpacks it to Vendor/VLCKit.xcframework.
# Idempotent: does nothing when the framework is present and was unpacked from the pinned archive.
# Set VLCKIT_ARCHIVE to a local copy of the archive to skip the download (it is still verified).
set -euo pipefail

VERSION="3.7.4"
ARCHIVE="VLCKit-3.0-20260922-1444.tar.xz"
SHA256="d57a80455900e031ec87b08bdc684ba58989f9cec317b04739b2ee6b1d7a1868"
BASE_URL="https://download.videolan.org/pub/cocoapods/prod"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"
STAMP="$VENDOR/.vlckit-sha256"

if [ -d "$VENDOR/VLCKit.xcframework" ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$SHA256" ]; then
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ -n "${VLCKIT_ARCHIVE:-}" ]; then
  cp "$VLCKIT_ARCHIVE" "$TMP/$ARCHIVE"
else
  echo "Downloading VLCKit ${VERSION}…"
  curl -fL --progress-bar -o "$TMP/$ARCHIVE" "$BASE_URL/$ARCHIVE"
fi

ACTUAL="$(shasum -a 256 "$TMP/$ARCHIVE" | awk '{print $1}')"
if [ "$ACTUAL" != "$SHA256" ]; then
  echo "VLCKit checksum mismatch: expected $SHA256, got $ACTUAL" >&2
  exit 1
fi

tar -xJf "$TMP/$ARCHIVE" -C "$TMP"
FOUND="$(find "$TMP" -maxdepth 3 -name VLCKit.xcframework -type d | head -1)"
if [ -z "$FOUND" ]; then
  echo "VLCKit.xcframework not found in $ARCHIVE" >&2
  exit 1
fi

mkdir -p "$VENDOR"
rm -rf "$VENDOR/VLCKit.xcframework"
mv "$FOUND" "$VENDOR/VLCKit.xcframework"
echo "$SHA256" > "$STAMP"
echo "VLCKit $VERSION ready at Vendor/VLCKit.xcframework"

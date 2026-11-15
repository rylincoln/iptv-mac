#!/bin/bash
# Draws the app icon (scripts/make-icon.swift) and packs it as Resources/AppIcon.icns, keeping the
# 1024-point master at docs/design/tuner-icon.png. Run after changing the drawing; the result is committed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MASTER="docs/design/tuner-icon.png"
swift scripts/make-icon.swift "$MASTER"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SET="$TMP/AppIcon.iconset"
mkdir "$SET"
for SIZE in 16 32 128 256 512; do
  sips -z "$SIZE" "$SIZE" "$MASTER" --out "$SET/icon_${SIZE}x${SIZE}.png" >/dev/null
  sips -z "$((SIZE * 2))" "$((SIZE * 2))" "$MASTER" --out "$SET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
echo "Wrote Resources/AppIcon.icns"

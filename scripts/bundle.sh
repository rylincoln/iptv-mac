#!/bin/bash
# Builds Tuner in release mode and wraps it into build/Tuner.app with VLCKit embedded,
# signed ad hoc. Run from anywhere; the bundle is rebuilt from scratch every time.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

scripts/fetch-vlckit.sh
swift build -c release
BIN="$(swift build -c release --show-bin-path)"

APP="$ROOT/build/Tuner.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"

cp "$BIN/Tuner" "$APP/Contents/MacOS/Tuner"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"  # drawn by scripts/make-icon.sh
# The bundle carries VLCKit, so the LGPL and the notices travel with it.
cp LICENSE THIRD-PARTY-NOTICES.md LICENSES/LGPL-2.1.txt "$APP/Contents/Resources/"
ditto "$BIN/VLCKit.framework" "$APP/Contents/Frameworks/VLCKit.framework"

RPATH="@executable_path/../Frameworks"
# grep reads all of otool's output (no -q), so pipefail never sees otool die of SIGPIPE.
if ! otool -l "$APP/Contents/MacOS/Tuner" | grep -F "path $RPATH " >/dev/null; then
  install_name_tool -add_rpath "$RPATH" "$APP/Contents/MacOS/Tuner"
fi

# Editing the binary invalidated the linker's ad hoc signature; sign the whole bundle again.
codesign --force --deep -s - "$APP"
echo "Built $APP"

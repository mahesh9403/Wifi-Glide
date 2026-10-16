#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
swift build --configuration release
BIN_DIR=$(swift build --configuration release --show-bin-path)
APP="$ROOT/dist/Wi-Fi Glide.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/wifi-glide" "$APP/Contents/MacOS/WiFiGlide"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Ad-hoc signing is enough for local POC execution. Distribution signing/notarization is a
# separate milestone and must use the user's own Developer ID credentials.
codesign --force --deep --sign - "$APP"
printf '%s\n' "$APP"

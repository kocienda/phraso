#!/bin/sh
# Build the SwiftUI app with SwiftPM and wrap it as Phraso.app (ad hoc signed), so it
# launches with `open Phraso.app`. Pass --debug for a debug build. The Info.plist and
# the icon are the same ones the Xcode project uses (App/).
#
#   Scripts/bundle-app.sh [--debug] [--out /path/to/Phraso.app]
set -e
cd "$(dirname "$0")/.."
CONFIG=release
OUT="$PWD/Phraso.app"
while [ $# -gt 0 ]; do
  case "$1" in
    --debug) CONFIG=debug ;;
    --out) OUT="$2"; shift ;;
  esac
  shift
done
swift build -c "$CONFIG" --product PhrasoApp
BIN="$(swift build -c "$CONFIG" --show-bin-path)"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN/PhrasoApp" "$OUT/Contents/MacOS/Phraso"
cp -R "$BIN/Phraso_PhrasoKit.bundle" "$OUT/Contents/Resources/"
cp App/AppIcon.icns "$OUT/Contents/Resources/"
sed -e 's/\$(PRODUCT_BUNDLE_IDENTIFIER)/com.kocienda.phraso/' -e 's/\$(EXECUTABLE_NAME)/Phraso/' \
    App/Info.plist > "$OUT/Contents/Info.plist"
codesign --force --deep --sign - "$OUT" >/dev/null 2>&1
echo "$OUT"

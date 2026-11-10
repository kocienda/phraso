#!/bin/sh
# Draw the app icon with the engine ("Hi!" in the area style, spoken) and pack it as
# App/AppIcon.icns, which the bundle script and the Xcode project both ship.
#
#   Scripts/make-icon.sh [--text Hi!] [--style area]
set -e
cd "$(dirname "$0")/.."
swift build --product phraso >/dev/null
SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"
.build/debug/phraso icon --out "$SET/icon_512x512@2x.png" "$@" >/dev/null
for px in 16 32 128 256 512; do
  sips -z $px $px "$SET/icon_512x512@2x.png" --out "$SET/icon_${px}x${px}.png" >/dev/null
  d=$((px * 2))
  [ $px -lt 512 ] && sips -z $d $d "$SET/icon_512x512@2x.png" --out "$SET/icon_${px}x${px}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o App/AppIcon.icns
echo App/AppIcon.icns

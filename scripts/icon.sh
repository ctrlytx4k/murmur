#!/bin/sh
# Rebuilds Support/AppIcon.icns from the icon the app draws itself.
# Run scripts/dev.sh app first.
set -e
cd "$(dirname "$0")/.."
work="$(mktemp -d)"
build/Murmur.app/Contents/MacOS/Murmur --icon "$work/icon.png"
set="$work/AppIcon.iconset"
mkdir "$set"
for size in 16 32 128 256 512; do
  sips -z $size $size "$work/icon.png" --out "$set/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$work/icon.png" --out "$set/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$set" -o Support/AppIcon.icns
rm -rf "$work"
echo "Wrote Support/AppIcon.icns"

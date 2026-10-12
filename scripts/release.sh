#!/bin/sh
# Builds dist/Murmur-<version>.dmg, the file people download.
#
# For a release other people can open without warnings, set:
#   MURMUR_DEVELOPER_ID    the certificate name, e.g. "Developer ID Application: Your Name (TEAMID)"
#   MURMUR_NOTARY_PROFILE  a keychain profile made once with: xcrun notarytool store-credentials
# Without them the image is still built, signed like a local build, for testing the packaging only.
set -e
cd "$(dirname "$0")/.."

scripts/dev.sh app
app="build/Murmur.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
dmg="dist/Murmur-$version.dmg"

if [ -n "$MURMUR_DEVELOPER_ID" ]; then
  # Notarization needs the hardened runtime and a secure timestamp.
  codesign --force --options runtime --timestamp --entitlements Support/Murmur.entitlements --sign "$MURMUR_DEVELOPER_ID" "$app"
  codesign --verify --strict --verbose=2 "$app"
else
  echo "MURMUR_DEVELOPER_ID is not set: this image is NOT signed for release."
fi

stage="$(mktemp -d)"
ditto "$app" "$stage/Murmur.app"
ln -s /Applications "$stage/Applications"
mkdir -p dist
rm -f "$dmg"
hdiutil create -volname "Murmur" -srcfolder "$stage" -ov -format UDZO "$dmg" >/dev/null
rm -rf "$stage"

if [ -n "$MURMUR_DEVELOPER_ID" ]; then
  codesign --force --timestamp --sign "$MURMUR_DEVELOPER_ID" "$dmg"
  if [ -n "$MURMUR_NOTARY_PROFILE" ]; then
    xcrun notarytool submit "$dmg" --keychain-profile "$MURMUR_NOTARY_PROFILE" --wait
    xcrun stapler staple "$dmg"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
  else
    echo "MURMUR_NOTARY_PROFILE is not set: signed but NOT notarized."
  fi
fi
echo "Built $dmg"

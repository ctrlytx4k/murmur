#!/bin/sh
# Wraps one experiment in a minimal .app so macOS attributes permissions to it
# rather than to Terminal. Ad-hoc signed: there is no Developer ID on this machine.
#   scripts/make-app.sh hotkey
set -e
cd "$(dirname "$0")/.."
name="${1:?usage: make-app.sh hotkey|insert|transcribe}"
swift build -c release --product "$name" 2>&1 | tail -1
app="build/Spike-$name.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp ".build/release/$name" "$app/Contents/MacOS/$name"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.murmur.spike.$name</string>
  <key>CFBundleName</key><string>Spike-$name</string>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.0.1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Records short clips for the transcription spike.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Transcribes the recorded clips on this Mac.</string>
</dict>
</plist>
PLIST
codesign --force --sign - --identifier "local.murmur.spike.$name" "$app"
codesign -dv "$app" 2>&1 | grep -E '^(Identifier|Signature|TeamIdentifier|CDHash)'
echo "Built $app"

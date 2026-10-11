#!/bin/sh
# Build, test and run Murmur from the command line.
#   scripts/dev.sh build | test | app | run [args] | snapshots <dir>
#
# With only the Command Line Tools installed (no Xcode) two things need help:
# the macOS 27 SDK wants SwiftUI macro plugins that ship with Xcode, so we build
# against the macOS 26 SDK, and swift-testing's macro plugin needs its path spelled out.
set -e
cd "$(dirname "$0")/.."

flags=""
tools="$(xcode-select -p)"
if [ "$tools" = "/Library/Developer/CommandLineTools" ]; then
  flags="--sdk $tools/SDKs/MacOSX26.sdk -Xswiftc -plugin-path -Xswiftc $tools/usr/lib/swift/host/plugins/testing"
fi

app="build/Murmur.app"

bundle() {
  swift build -c release $flags 2>&1 | tail -1
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS"
  cp .build/release/Murmur "$app/Contents/MacOS/Murmur"
  cp Support/Info.plist "$app/Contents/Info.plist"
  mkdir -p "$app/Contents/Resources"
  cp -R THIRD-PARTY-NOTICES.md Licenses "$app/Contents/Resources/"
  # Ad-hoc signature for local runs only. Release signing is not set up yet.
  codesign --force --sign - "$app" 2>/dev/null
}

case "${1:-build}" in
  build) swift build $flags ;;
  test) swift test $flags ;;
  app) bundle; echo "Built $app" ;;
  run) shift; bundle; open "$app" --args "$@" ;;
  snapshots) bundle; "$app/Contents/MacOS/Murmur" --snapshots "${2:?usage: dev.sh snapshots <dir>}" ;;
  *) echo "usage: scripts/dev.sh build|test|app|run|snapshots <dir>"; exit 1 ;;
esac

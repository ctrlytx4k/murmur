#!/bin/sh
# Runs every clip with a given prefix through both engines, one process per run.
#   scripts/run-transcription.sh synth aiff
#   scripts/run-transcription.sh real wav
set -e
cd "$(dirname "$0")/.."
prefix="${1:-synth}"
ext="${2:-aiff}"
swift build -c release --product transcribe 2>&1 | tail -1
bin=.build/release/transcribe
for name in 5s 30s 2min technical; do
  clip="audio/$prefix-$name.$ext"
  [ -f "$clip" ] || { echo "skip $clip (missing)"; continue; }
  ref="fixtures/references/$name.txt"
  "$bin" run --engine parakeet --clip "$clip" --ref "$ref" --runs 3 2>/dev/null || echo "parakeet failed on $clip"
  "$bin" run --engine apple --clip "$clip" --ref "$ref" --runs 3 2>/dev/null || echo "apple failed on $clip"
  "$bin" run --engine apple --clip "$clip" --ref "$ref" --runs 1 --realtime 2>/dev/null || echo "apple realtime failed on $clip"
done

#!/bin/sh
# Turns the reference texts into speech with the system voice, so the engines can
# be timed without anyone at the microphone. Synthetic speech is easier than real
# speech: use these clips for latency and memory, not as the accuracy verdict.
set -e
cd "$(dirname "$0")/.."
mkdir -p audio
for name in 5s 30s 2min technical; do
  say -r 150 -o "audio/synth-$name.aiff" -f "fixtures/references/$name.txt"
  echo "audio/synth-$name.aiff"
done

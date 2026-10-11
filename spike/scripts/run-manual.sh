#!/bin/bash
# Walks through every spike run that needs a person, one step at a time.
# Run it from Terminal.app (not an editor's terminal), so permissions belong to Terminal:
#
#   spike/scripts/run-manual.sh            all three experiments
#   spike/scripts/run-manual.sh hotkey     just one: hotkey | insert | voice
#
# Each step says what to do, waits for Return, then runs. Type s + Return to skip a step.
# Steps that already have a result are skipped, so it is safe to stop and run again.
cd "$(dirname "$0")/.." || exit 1
only="${1:-all}"

echo "Building..."
swift build -c release 2>&1 | tail -1
bin=.build/release

have() { ls results/"$1"-*.jsonl >/dev/null 2>&1; }

# Throw away anything typed ahead, so a stray Return cannot start the next step unattended.
ask() {
  while read -r -t 1 _; do :; done
  printf '%s' "$1"
  read -r answer
}

# After a hotkey run: say what was seen, and discard a run where the key never registered.
check_hotkey() {
  file="$(ls -t results/"$1"-*.jsonl 2>/dev/null | head -1)"
  [ -n "$file" ] || return
  presses="$(grep '"event":"summary"' "$file" | sed -E 's/.*"downs":([0-9]+).*/\1/')"
  if [ "${presses:-0}" = 0 ]; then
    rm -f "$file"
    echo "!! No presses of your key were seen, so this run was thrown away. Run the script again to redo it."
  else
    echo "   saw $presses presses"
  fi
}

# step <result-prefix> <instructions> <command...>
step() {
  prefix="$1"; text="$2"; shift 2
  if have "$prefix"; then echo "✓ $prefix (already recorded)"; return; fi
  ask "$(printf '\n────────────────────────────────────────\n%s\n\nReturn to start, s to skip: ' "$text")"
  [ "$answer" = "s" ] && { echo "skipped"; return; }
  echo "   running now..."
  "$@" 2>/dev/null
  echo "done: $prefix"
  case "$prefix" in hotkey-*) check_hotkey "$prefix" ;; esac
}

perms="$("$bin/hotkey" --scenario preflight --duration 1 --out "${TMPDIR:-/tmp}" 2>&1 | grep '"event":"permissions"')"
case "$perms" in *'"listen_access":true'*) listen=yes ;; *) listen=no ;; esac
case "$perms" in *'"accessibility":true'*) ax=yes ;; *) ax=no ;; esac
echo "Input Monitoring for this terminal: $listen · Accessibility: $ax"
if [ "$listen" = no ] || [ "$ax" = no ]; then
  cat <<'EOF'

Grant these to Terminal in System Settings > Privacy & Security, then quit and reopen Terminal and run this again:
  - Input Monitoring   (hotkey experiment)
  - Accessibility      (text insertion experiment)
EOF
  [ "$only" = voice ] || exit 1
fi

if [ "$only" = all ] || [ "$only" = hotkey ]; then
  echo; echo "== 1. Hotkey. Each run stops on its own. =="
  echo "Pick the key for every hotkey step. The intended one is the Option (Alt) key to the RIGHT of the space bar."
  ask "Press Return, then press and release that key once: "
  key="$("$bin/hotkey" --detect --duration 20 --out "${TMPDIR:-/tmp}" 2>/dev/null | sed -n 's/^DETECTED //p')"
  if [ -z "$key" ]; then echo "No key press was seen in 20 s. Run the script again."; exit 1; fi
  echo "Using key code $key (61 is the right Option key). 'Your key' below means this key."
  step hotkey-hold30 "Hold your key for 30 seconds, then release. (40 s run)" \
    "$bin/hotkey" --key "$key" --scenario hold30 --duration 40
  step hotkey-taps200 "Tap your key 200 times as fast as you can. (60 s run)" \
    "$bin/hotkey" --key "$key" --scenario taps200 --duration 60
  step hotkey-sleepwake "Tap 5 times, then Apple menu > Sleep. Wait 20 s, wake the Mac, tap 5 more times. (120 s run)" \
    "$bin/hotkey" --key "$key" --scenario sleepwake --duration 120
  open fixtures/targets.html 2>/dev/null
  step hotkey-password "In the browser page that just opened, click the PASSWORD field. Tap your key 10 times, then hold it 3 s. (30 s run)" \
    "$bin/hotkey" --key "$key" --scenario password --duration 30
  step hotkey-secure-terminal "Terminal menu > Secure Keyboard Entry: turn it ON. Tap 10 times here, click another app, tap 10 more. (40 s run) Turn it OFF afterwards." \
    "$bin/hotkey" --key "$key" --scenario secure-terminal --duration 40
  step hotkey-contested "Only if another tool (Karabiner, Raycast, another dictation app) can bind your key: bind it there, then tap 10 times. Otherwise skip. (30 s run)" \
    "$bin/hotkey" --key "$key" --scenario contested --duration 30
  step hotkey-taps-active "Active (key-swallowing) tap. Tap your key 20 times. (30 s run)" \
    "$bin/hotkey" --key "$key" --scenario taps-active --tap active --duration 30

  scripts/make-app.sh hotkey >/dev/null 2>&1
  step hotkey-app-first "Same test as a standalone app. macOS should ask for Input Monitoring for 'Spike-hotkey': approve it in System Settings. Tap a few times. (20 s run)" \
    open -W build/Spike-hotkey.app --args --out "$PWD/results" --key "$key" --scenario app-first --duration 20
  step hotkey-app-granted "The app again, now with permission. Tap your key 20 times and hold once for 5 s. (40 s run)" \
    open -W build/Spike-hotkey.app --args --out "$PWD/results" --key "$key" --scenario app-granted --duration 40
fi

if [ "$only" = all ] || [ "$only" = insert ]; then
  echo; echo "== 2. Text insertion. After Return you get a 6 s countdown: click into the target field, then hands off until the beep. =="
  echo "   Strategy C presses Return at the newline. In Messages and Slack use a conversation with YOURSELF."
  step insert-clipboard-finder-files "First copy two files in Finder (select them, Cmd+C)." \
    "$bin/insert" clipboard --current --name finder-files
  step insert-clipboard-preview-image "Open any image in Preview, select a region, Cmd+C." \
    "$bin/insert" clipboard --current --name preview-image
  for target in notes messages slack chrome-textarea chrome-contenteditable safari-textarea vscode terminal password; do
    case "$target" in
      chrome-*) hint="Open spike/fixtures/targets.html in Chrome and use its ${target#chrome-} field." ;;
      safari-*) hint="Use the textarea on the targets page in Safari." ;;
      password) hint="Use the PASSWORD field on the targets page." ;;
      terminal) hint="Open a second Terminal window and run:  cat > /dev/null   Click into that window. Ctrl-C it afterwards." ;;
      vscode) hint="Use a new untitled file in VS Code." ;;
      messages|slack) hint="Use a conversation with yourself in ${target}." ;;
      *) hint="Use a new note in Notes." ;;
    esac
    if have "insert-$target"; then echo "✓ insert-$target (already recorded)"; continue; fi
    ask "$(printf '\n────────────────────────────────────────\nTarget: %s\n%s\n\nReturn to start the countdown, s to skip: ' "$target" "$hint")"
    [ "$answer" = "s" ] && continue
    "$bin/insert" target --name "$target" 2>&1 | grep -v '^{'
  done
fi

if [ "$only" = all ] || [ "$only" = voice ]; then
  echo; echo "== 3. Your voice. Each step prints a text: read it aloud at a normal pace when recording starts. =="
  mkdir -p audio
  for spec in "5s 7" "30s 40" "2min 135" "technical 50"; do
    set -- $spec
    if [ -f "audio/real-$1.wav" ]; then echo "✓ real-$1 (already recorded)"; continue; fi
    ask "$(printf '\n────────────────────────────────────────\nClip: %s (%s s)\nReturn to see the text and start, s to skip: ' "$1" "$2")"
    [ "$answer" = "s" ] && continue
    "$bin/transcribe" record --name "real-$1" --seconds "$2" --ref "fixtures/references/$1.txt" 2>&1 | grep -v '^{'
  done
  echo "Running both engines over your clips..."
  scripts/run-transcription.sh real wav
fi

echo
echo "All done. Results are in spike/results/. Nothing was uploaded; audio stays in spike/audio/ (git-ignored)."

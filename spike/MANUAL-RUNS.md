# Spike: runs that need a person

Throwaway. Everything here writes JSON lines to `spike/results/`. Logs hold timings, counts, type names and the test transcripts only: no clipboard contents, no paths, no audio.

The quick way is the guided script, which walks through every step below and skips ones already done:

```bash
spike/scripts/run-manual.sh
```

The rest of this page is the same steps by hand. Run them from `spike/` in Terminal. Build first:

```bash
swift build -c release
```

## Permissions to grant once

System Settings > Privacy & Security, add **Terminal** to:

- Input Monitoring (experiment 1), then quit and reopen Terminal
- Accessibility (experiment 2)
- Microphone is prompted on first recording (experiment 3)

## 1. Hotkey (about 10 minutes)

Default key is right Option. Each run ends with Ctrl-C, which writes the summary row.

| Scenario | Command | What to do |
|---|---|---|
| Hold | `.build/release/hotkey --scenario hold30` | Hold right Option for 30 s, release, Ctrl-C |
| Rapid taps | `.build/release/hotkey --scenario taps200` | Tap right Option 200 times as fast as you can, Ctrl-C |
| Sleep/wake | `.build/release/hotkey --scenario sleepwake` | Tap 5 times, Apple menu > Sleep, wait 20 s, wake, tap 5 times, Ctrl-C |
| Password field | `.build/release/hotkey --scenario password` | Open `fixtures/targets.html` in Safari, click the password field, tap 10 times, hold 3 s, Ctrl-C back in Terminal |
| Secure Keyboard Entry | `.build/release/hotkey --scenario secure-terminal` | Terminal menu > Secure Keyboard Entry (on), tap 10 times with a Terminal window focused, then with another app focused, Ctrl-C, turn it back off |
| Contested key | `.build/release/hotkey --scenario contested` | Only if you have another tool that can bind right Option (Karabiner, Raycast, another dictation app): bind it, tap 10 times, Ctrl-C. Otherwise skip and it is reported as not tested |
| Active tap | `.build/release/hotkey --scenario taps-active --tap active` | Needs Accessibility. Tap 20 times, Ctrl-C |

Then the same thing as an app, so the permission belongs to the app and not to Terminal:

```bash
scripts/make-app.sh hotkey
```

```bash
open -W build/Spike-hotkey.app --args --out "$PWD/results" --scenario app-first --duration 20
```

The first launch should raise an Input Monitoring prompt. Approve it in System Settings, then:

```bash
open -W build/Spike-hotkey.app --args --out "$PWD/results" --scenario app-granted --duration 40
```

Tap 20 times and hold once for 5 s while it runs. It exits on its own.

## 2. Text insertion (about 15 minutes)

Clipboard restore with content from other apps. Copy two files in Finder, then:

```bash
.build/release/insert clipboard --current --name finder-files
```

Then try pasting the files into a Mail draft or Notes and note whether they still attach. Repeat after copying an image region in Preview:

```bash
.build/release/insert clipboard --current --name preview-image
```

Targets. For each one: run the command, click into the target's text field during the 6 s countdown, keep hands off until the beep (about 15 s), then come back to Terminal and answer the three questions.

Strategy C presses Return at the newline. **In Messages and Slack that sends the first half, so use a conversation with yourself.** In Terminal, start `cat > /dev/null` in the target window first so nothing is executed, and Ctrl-C it afterwards.

```bash
.build/release/insert target --name notes
```

```bash
.build/release/insert target --name messages
```

```bash
.build/release/insert target --name slack
```

```bash
.build/release/insert target --name chrome-textarea
```

```bash
.build/release/insert target --name chrome-contenteditable
```

```bash
.build/release/insert target --name safari-textarea
```

```bash
.build/release/insert target --name vscode
```

```bash
.build/release/insert target --name terminal
```

```bash
.build/release/insert target --name password
```

Chrome and Safari targets are the fields in `fixtures/targets.html`. The password target is the password field on that page. VS Code: an untitled file.

If strategy A pastes the wrong thing (old clipboard instead of the test text), rerun that target with `--only A --restore-delay-ms 500` and note it.

## 3. Transcription with a real voice (about 8 minutes)

Each command prints the text to read, counts down, records, and saves to `spike/audio/` (git-ignored).

```bash
.build/release/transcribe record --name real-5s --seconds 7 --ref fixtures/references/5s.txt
```

```bash
.build/release/transcribe record --name real-30s --seconds 40 --ref fixtures/references/30s.txt
```

```bash
.build/release/transcribe record --name real-2min --seconds 135 --ref fixtures/references/2min.txt
```

```bash
.build/release/transcribe record --name real-technical --seconds 50 --ref fixtures/references/technical.txt
```

Then run both engines over them:

```bash
scripts/run-transcription.sh real wav
```

Optional, for Neural Engine use (needs sudo, so it is yours to run): in a second window start `sudo powermetrics --samplers ane_power,cpu_power -i 500` and watch it during the script.

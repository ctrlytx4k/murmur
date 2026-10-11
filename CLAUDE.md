# Murmur (working name)

Free, open-source, local-first voice dictation for macOS. Hold a hotkey, speak, text appears in whatever app has focus. No account, no subscription, no cloud required.

## Hard constraints
- macOS only for now. Do not add cross-platform abstractions.
- Target macOS 26 (Tahoe) and up (needed for Liquid Glass and Apple's SpeechAnalyzer). Confirm with testers before locking in.
- Transcription runs on-device. The only network traffic allowed is model downloads and update checks. No telemetry, no analytics, no phoning-home crash reporters.
- No account, login or license key anywhere.
- Never copy code from FluidVoice or VoiceInk (both GPL-3.0). Read for ideas only. Our license is MIT.

## Stack
- Swift 6, SwiftUI + AppKit. NSStatusItem for the menu bar item.
- Hotkeys: CGEventTap (push-to-talk needs key-up, so no high-level shortcut libraries).
- Audio: AVAudioEngine, 16 kHz mono.
- Transcription: a TranscriptionEngine protocol. Implementations: FluidAudio (Parakeet v3 on the Neural Engine) and Apple SpeechAnalyzer. Whisper-family engines only later, if a language gap demands it.
- Text insertion: pasteboard + synthesized Cmd+V with full clipboard save/restore by default; Accessibility API and typed events as per-app fallbacks.
- Login item: SMAppService. Updates: Sparkle 2.
- Add a dependency only after asking me. Prefer Apple frameworks.

## Architecture
Small services behind protocols so each can be tested alone:
- HotkeyService: owns the event tap, enqueues events and returns immediately.
- AudioCaptureService
- TranscriptionEngine
- TextInsertionService
- PermissionsService: microphone, Accessibility, Input Monitoring.
- DictationController: the single state machine. States: idle, recording, processing, inserted, error(reason). UI reads this and never calls services directly.
- SettingsStore, HistoryStore (local only).

## Rules that bite
- The event tap callback must never block or do real work. If it times out, macOS disables the tap: handle tapDisabledByTimeout / tapDisabledByUserInput by re-enabling, and re-create the tap after sleep/wake.
- Detect secure input (IsSecureEventInputEnabled) and tell the user instead of failing silently.
- Always restore the user's clipboard (all pasteboard types), including on error paths.
- Undo only reverts if the inserted text is still there unchanged.
- Re-check permission state live; never cache it across launches.
- Every failure path ends in a visible state (icon + dropdown message), never silence.

## MVP scope (P0)
Menu bar item with states, dropdown, recording overlay, push-to-talk and toggle, one local engine, paste insertion, last-transcription copy/re-insert/undo, permissions onboarding, minimal settings (hotkey, mic, launch at login).
Also in the first release: AI cleanup (Cleaned up mode) with per-app presets, using Apple's on-device Foundation Models. It must stay optional: when the model is unavailable or a cleanup fails, the spoken text goes in and the UI says so.
Not in MVP: command mode, automatic updates, Windows. Don't build these until P0 is in real people's hands. A control with nothing behind it is hidden, not shown disabled.

## Design
- Source of truth: the mockup HTML in design/ (I will add it). Don't build UI until it's there.
- Liquid Glass on floating surfaces only (overlay, dropdown, sidebars, buttons, alerts). Content areas stay solid.
- One accent (Ice blue). Red, green and amber are reserved for status.
- Light by default, dark as a full alternate.
- Honor Reduce Transparency, Increase Contrast and Reduce Motion.

## Testing
- Unit tests for the state machine and clipboard restore.
- Insertion matrix: Notes, Messages, Slack, Chrome (textarea and contenteditable), Safari, VS Code, Terminal, password field, plus sleep/wake and secure input. Scripted where possible; results recorded per release.
- Anything touching permissions must be verified in a signed .app, not only via swift run (Terminal's permissions mask real behavior).

## Workflow
- Spike code lives in spike/ and is throwaway. No real UI until the spike report says go.
- Small, focused commits.
- Commit messages are plain, human-sounding, imperative. Never add Co-Authored-By lines, model names, "generated with" footers or any AI attribution to commits, PRs or code comments.
- Ask before: new dependencies, changing the architecture above, touching signing or notarization config.

# Murmur

Free, open-source voice dictation for macOS that stays on your Mac.

Hold a shortcut, speak, and the text appears in whatever app you are using. There is no account, no subscription and no cloud: your voice is transcribed on your own machine.

## What it does

- **Dictate anywhere.** Works in any app that accepts typing. Hold the shortcut to talk, or tap it once to go hands-free and press again to finish.
- **Two speech models, both on-device.** Apple's built-in speech engine works straight away. Parakeet v3 is an optional one-time download (about 480 MB) that is faster and covers more languages.
- **Optional clean-up.** "Cleaned up" mode fixes punctuation and removes filler words using the language model built into macOS. You can pick a style per app. If the model is unavailable, your words go in exactly as spoken and Murmur tells you.
- **Your clipboard is left alone.** Murmur pastes the text and then puts back whatever you had copied.
- **Copy, re-insert or undo** the last dictation from the menu bar.
- **Dictionary and snippets.** Teach it names and jargon, or expand a spoken phrase into a block of text.
- **History, kept locally,** for as long as you choose, or not at all.

## Privacy

- Audio is transcribed on your Mac and is never uploaded.
- The only network traffic is the speech model download, the language files macOS fetches for its own speech engine, and the releases page when you choose "Check for Updates". Offline mode blocks the downloads too.
- No telemetry, no analytics, no crash reporting, no account.
- Settings › Privacy shows a log of every download the app has made.

## Requirements

- macOS 26 (Tahoe) or later
- A Mac with Apple silicon
- Cleaned up mode needs Apple Intelligence to be turned on. Everything else works without it.

## Install

Download the latest disk image from the [releases page](https://github.com/ctrlytx4k/murmur/releases), open it, and drag Murmur to Applications.

On first launch Murmur walks you through three permissions:

| Permission | Why |
|---|---|
| Microphone | To hear you, only while you are dictating |
| Accessibility | To notice your shortcut and type the text at your cursor |
| Input Monitoring | To notice your shortcut while another app is in front |

macOS may quit and reopen Murmur when you grant Input Monitoring. That is expected; setup carries on where it left off.

## Build from source

You need the Xcode Command Line Tools (or Xcode) with Swift 6.2.

```sh
git clone https://github.com/ctrlytx4k/murmur.git
cd murmur
scripts/dev.sh test   # run the tests
scripts/dev.sh app    # build build/Murmur.app
open build/Murmur.app
```

A build you make yourself is signed ad hoc, so macOS asks for the permissions again after each rebuild. To avoid that, create a self-signed code-signing certificate named "Murmur Local Dev" in Keychain Access; the build script uses it when it exists.

Useful while developing:

```sh
build/Murmur.app/Contents/MacOS/Murmur --demo --tour       # open every screen with simulated services
build/Murmur.app/Contents/MacOS/Murmur --snapshots out/    # render every screen to PNG
build/Murmur.app/Contents/MacOS/Murmur --selftest take.aiff # run the speech engines on a file
```

## Not in this release

Voice commands, automatic updates and automatic language detection.

## License and credits

Murmur is released under the [MIT license](LICENSE).

It is built on [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache 2.0) and can use the [Parakeet TDT v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) speech model by NVIDIA (CC BY 4.0). Full notices are in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

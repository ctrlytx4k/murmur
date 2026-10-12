# Insertion matrix

Where dictated text has been checked to land correctly. One section per release.

The scripted rows come from `open -n build/Murmur.app --args --matrix <results file>`, which inserts a
known sentence by paste, reads it back and checks the clipboard was put back. The manual rows are a
person dictating into the app.

## 0.1.0 (pre-release), macOS 27.0.1, 2026-10-11

| Target | How | Text inserted | Clipboard restored | Notes |
|---|---|---|---|---|
| Notes | scripted | yes | yes | Undo removed the text |
| Terminal | scripted | yes | yes | |
| Safari, textarea | scripted | yes | yes | |
| Safari, contenteditable | scripted | yes | yes | |
| Chrome, textarea | scripted | not run | - | Chrome lost focus while launching; needs a rerun |
| Chrome, contenteditable | scripted | yes | yes | |
| Password field (Safari) | scripted | n/a | - | Secure input detected, so a take there is discarded |
| Messages | manual | not tested yet | | Left out of the script so a test sentence cannot become a draft to a real person |
| Slack | manual | not tested | | Not installed on the test Mac |
| VS Code | manual | not tested | | Not installed on the test Mac |
| After sleep/wake | manual | not tested yet | | |

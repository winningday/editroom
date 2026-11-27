<p align="center"><img src="docs/icon.png" width="128" alt="Editroom icon"></p>

# Editroom

Fast and powerful video editing for Mac. Free, open source, and always yours.

Editroom has the pro editing tools you need — color grading, speed ramps, transitions, audio mixing, loudness targets and exports in any shape — in a 7.5 MB app that plays 4K in realtime, with no proxies or buffering. Say what you want and watch Claude, ChatGPT or your Mac cut it for you.

Because it's open source, you can download the Xcode project and add, remove, or modify any feature to fit your workflow.

> **This is a fork** adapted for long, multi-camera painting classes: SRT subtitles in and out (for translation and dubbing), Whisper transcription, a subtitle editor, multi-camera switching, dead-air removal and timelapse speed-ups. It **never updates itself**. See [FORK.md](FORK.md) for what changed and how to use it.

![Editroom](docs/screenshot.webp)

## Installation

Build it from this repository in Xcode (see Building). This fork has no automatic updates: a new version only arrives when you rebuild it.

## Features

### Editing
- Sharp from edit to export in 4K, in realtime: no lag, buffering, or proxies
- Opens any format: iPhone, Canon, Sony, Nikon and Fuji footage, and files macOS can't open itself (MXF, MKV, WebM…)
- Markers and in/out points, to mark the moments that matter and work on or export just part of your edit
- Split, ripple delete, close gaps, detach audio, duplicate, freeze frame and reverse
- Text and solids, on as many video and audio tracks as you need
- Editable keyboard shortcuts

### Color
- Color grading: load your own LUTs or pick a look, then fine-tune exposure, contrast, white balance and saturation
- Copy a grade from one clip and paste it onto others

### Speed and transitions
- Speed ramps: slow down part of a clip, then ease back to normal speed
- Dissolve, dip to black or wipe between clips
- Fade picture and sound in and out, with a choice of curves

### Audio
- Cut to the beat: cuts land on the beat of your music automatically
- Solo, mute and set levels per track, with meters and waveforms
- Even out audio levels across clips

### Export
- Loudness targets: export at the right level for YouTube, podcasts or broadcast (-14 LUFS and others), no audio know-how needed
- Export any shape: turn one edit into vertical, square or portrait, and choose what stays in frame

### Find any moment
- Search for what's in a clip: people, places and things (beach, car, night, laughing, dog…)
- Every clip is transcribed, so you can search what was said

### Magic
Say what you want, and watch it get cut. Type a request like *"Make an intro montage from the best moments. Cut to the beat. Slow-mo on @birthday-party when cake is thrown"* and pick who does the work:

- **Claude** — uses your Claude plan, through the Claude app
- **ChatGPT** — uses your ChatGPT plan, through ChatGPT or Codex
- **Local** — runs entirely on your Mac with Apple's on-device model, with nothing sent anywhere

Mention a clip with `@` or point at the playhead with `@playhead`. Every Magic edit can be undone.

### Works with AI agents
- Claude and ChatGPT can edit an open project directly over MCP, with their own cursor on the timeline. Connect them in Settings › Magic; no API keys needed.

## Requirements

- macOS 14 or later on a Mac with Apple silicon
- Magic's Local option needs Apple Intelligence (macOS 26 or later)
- Magic's Claude and ChatGPT options need the Claude app, or ChatGPT / Codex, signed in to your plan
- Xcode 26 or later (to build from source)
- Captions and transcripts need [Whisper](FORK.md#whisper) installed on the Mac, or macOS 26

## Building

Open `Editroom.xcodeproj` and run the **Editroom** scheme.

## Releasing

`scripts/release.sh` builds a Release version, signs it with Developer ID, notarizes and staples it, and packages it into `dist/Editroom-<version>.dmg`. Set `EDITROOM_TEAM` to your Apple Developer Team ID first. There is no update feed: copy the DMG to the Mac yourself.

They need, all kept outside this repository:

- a **Developer ID Application** certificate in the login keychain
- notarization credentials saved with `xcrun notarytool store-credentials "editroom-notary" …`
- [`create-dmg`](https://github.com/create-dmg/create-dmg) (`brew install create-dmg`)

## License

MIT — see [LICENSE](LICENSE).

Editroom includes [FFmpeg](https://ffmpeg.org) 9.1, licensed under the GNU LGPL 2.1 or later, which it runs as a separate program to open formats macOS can't. See [Vendor/ffmpeg](Vendor/ffmpeg/README.md) for its source and build options.

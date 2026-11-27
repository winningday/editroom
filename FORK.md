# This fork

Editroom, adapted for Maya's long watercolor classes: several cameras, long quiet stretches, Chinese speech,
and English subtitles and dubs made by our own translation pipeline (Oscar, in OpenClaw-Artist-Management).

**Status: written without a Mac.** Everything here was written and reviewed on Linux. The pure logic (subtitles,
SRT, camera sync, dead air, speed-ups) is unit-tested there. The app itself has **not been compiled or run yet**.
The first Xcode build will likely turn up a few compile errors to fix. Test it on real footage before Maya relies on it.

## What changed

### No automatic updates
- Sparkle is gone: no update feed, no update checks, no "Check for Updates" menu.
- The app only changes when someone rebuilds it from this repo.
- Signing is local (ad-hoc, "Sign to Run Locally"), with our own bundle id `art.mayahan.Editroom`.
  To ship a notarized DMG, set `EDITROOM_TEAM` and run `scripts/release.sh`.

### Security
- **Claude (Magic)**: Settings › Magic › *Claude can use files on this Mac* (on by default). On, Claude Code can
  read files in the home folder (Read, Glob, Grep) and bring in footage, SRTs and dubs. It gets **no web tools in the same
  run**, so a web page can't trick it into sending files out. Off, it gets web search for music but no files.
- **ChatGPT (Magic)**: no web search any more. Its read-only shell could read any file, so it gets no web input.
- The AI launcher only falls back to an Editroom copy installed in an Applications folder.
- `scripts/build-ffmpeg.sh` checks the FFmpeg download (GPG signature, or `FFMPEG_SHA256`) before building.
- Still true: the app isn't sandboxed (normal for video editors). The local AI connection on port 47920 has no
  password; it rejects web pages, but any program already running on the Mac can use it.
  Turn it off in Settings › Magic if unused.

### Whisper
Captions, transcripts and "nobody's talking" detection now use Whisper when it's installed. It works on any
macOS 14+, not just macOS 26, and handles Chinese well. Settings › Subtitles chooses the engine and language
(中文 asks Whisper for Simplified Chinese).

It finds, in this order:
1. `mlx_whisper`: fastest on Apple silicon. Install with `pip3 install mlx-whisper`. The first run downloads the model, about 1.6 GB.
2. `whisper-cli` (whisper.cpp): `brew install whisper-cpp`, then put a `ggml-*.bin` model in
   `~/Library/Application Support/Editroom/Whisper/` (large-v3-turbo is a good choice).
3. `whisper` (OpenAI's Python package).

The Python ones need `ffmpeg` on the PATH (`brew install ffmpeg`). Or set the exact program path in Settings › Subtitles.
Already-heard files keep their transcript; use **Clip › Transcribe Again** after changing the language or engine.

### Subtitles
- **Subtitles › Export Subtitles (SRT)…**: the captions as shown, timed to the timeline. Also plain text, and
  text with times (for show notes or a blog post).
- **Subtitles › Import Subtitles (SRT)…**: an SRT comes in as a *layer* (for example "English") and the caption
  track shows it. Times can be from this timeline (the usual case: exported from here, then translated) or
  from one clip's own file. Layers follow every trim and cut, like the heard captions do.
- **Subtitles › Show**: switch between what's heard (Chinese) and any imported layer.
- **Subtitles › Import Dub Track…**: a narration WAV timed to the timeline goes on a new track from 0. The
  camera sound is turned down while the dub speaks.
- **Editing on screen**: click the caption track's header. The inspector lists every subtitle with its time.
  Click a time to jump there, then type to fix a line. The line under the playhead is highlighted and followed while
  playing. Fixes on the heard layer stick to the file. Fixes on an imported layer change that layer.
- Chinese captions are laid out without spaces between characters and wrap at about 13 characters.

### Multiple cameras (Class menu)
1. Put one clip from each camera on the timeline: the main camera, whose sound plays all through, on V1, and the others on
   V2, V3…, roughly lined up.
2. Select them all → **Class › Make Multi-Angle from Selected Clips**. The cameras are lined up by their
   sound (claps, speech, a brush tapping the jar). If sound can't line one up, it's kept as you placed it.
3. Play, and press **⌥1, ⌥2, ⌥3…** to cut to that camera from the playhead on.
4. **Class › Picture in Picture** puts another camera small in a corner over the selected part.
5. **Class › Selected Clips Show** changes the camera of whole clips.

Under the hood it's an ordinary edit: one camera's clip at a time on V1, with the main sound unbroken on A1.

### Pacing (Class menu)
- **Remove Dead Air…**: finds stretches of 2–30 s or more where *nothing is said and nothing moves*,
  where nothing is said, or where nothing moves. It cuts them out or speeds them up, on every track at once so sound and
  picture stay in sync. Works on the in/out range if one is set, else the whole timeline. "Nothing said and
  nothing moving" is the safe default: painting quietly still counts as something happening.
- **Speed Up…**: a timelapse of the in/out range, or from the playhead to the end. "Only where nobody's
  talking" keeps explanations at normal speed. Sound in the sped-up parts is turned off by default.
- One undo puts each one back.

### Claude Code can do all of it
New MCP tools: `export_subtitles`, `import_subtitles`, `list_subtitle_layers`, `set_subtitle_layer`,
`import_dub`, `transcribe_again`, `make_multicam`, `list_angles`, `switch_angle`, `set_pip`,
`remove_dead_air` (with `dry_run`), `speed_up_range`. So a prompt like *"sync the three cameras, use the
overhead camera while she paints and the face camera when she talks to us, cut dead air, timelapse the last
20 minutes where she's quiet, then export the Chinese subtitles to ~/Desktop/class.srt"* is one Magic run.

## The translation and dubbing round trip

1. Edit the class. Add captions (Clip › Add Captions); Whisper hears the Chinese.
2. Fix any lines in the subtitle list, then **Export Subtitles (SRT)** with "What's Heard" shown.
3. Oscar translates it (`translator/input/` → `translator/output/`), and the dubbing pipeline makes the WAV.
4. **Import Subtitles** with the English SRT (timed to this timeline) and **Import Dub Track** with the WAV.
5. Export the video. Edit the timeline *after* step 2 and the subtitles still follow, but the dub won't:
   re-export, translate and dub again for a final cut.

## First build checklist (on the Mac)

1. Open `Editroom.xcodeproj` in Xcode 26, choose the Editroom scheme, and build. Fix any compile errors.
   Claude Code on the Mac can do this: ask it to "build Editroom and fix the errors".
2. Install Whisper (above) and pick 中文 in Settings › Subtitles.
3. Try a short two-camera clip first: multi-angle, ⌥1/⌥2, dead air dry run, SRT export and import.
4. Then a full class.

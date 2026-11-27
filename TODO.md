# TODO — Maya's editor

The goal: **Maya paints and records; getting a high-quality video out to Patreon, plus timelapses, short lessons
and social posts, takes as little of her time as possible.** She drops the footage in, says what she wants, and
checks the result. When something is off, she points at that bit and says why. Only that bit gets fixed.

Work top to bottom. Don't start a phase until the one before it works on her Mac with a real class.
Tick boxes as you go, and add what you learn under the phase.

---

## Phase 0 — First build and a real class ⬅ do this first

Everything below Phase 0 was written on Linux without a Mac. None of the app code has been compiled.

- [ ] Open `Editroom.xcodeproj` in Xcode 26 and build. Fix compile errors. (Ask Claude Code on the Mac: "build
      Editroom and fix the errors". Fix the code; don't delete features to get green.)
- [ ] Launch. Check: no update checks happen, Settings has a Subtitles tab, and the menus show Subtitles and Class.
- [ ] Whisper: install mlx-whisper (`pip3 install mlx-whisper`), set 中文 in Settings › Subtitles, add captions
      to a short clip, and check they're Chinese with no spaces between characters.
- [ ] Subtitle list: click the caption track header, edit a line, check the change shows in the viewer.
- [ ] Two cameras: Make Multi-Angle, then ⌥1/⌥2 cuts and picture in picture. Check the sync is right by eye and ear.
- [ ] Remove Dead Air: run it with a short minimum and check nothing she says or paints is cut.
- [ ] Speed Up near the end, only where quiet.
- [ ] Translate and Dub, end to end, on a **5-minute** class first (cheap), then a full one.
      Needs: a clone of OpenClaw-Artist-Management, `claude` signed in, Python 3.10+, and the ElevenLabs key in `.env`.
- [ ] Export the Patreon video with English captions and the dub. Watch it through once.
- [ ] Check the FFmpeg release-key fingerprint in `scripts/build-ffmpeg.sh` against ffmpeg.org.
- [ ] Write down everything that broke or annoyed her, as new items below.

**Done when:** one real class goes from footage to a Patreon-ready export through Editroom alone.

---

## Phase 1 — Dub as separate clips, not one long WAV

**Why.** Today `srt_dubber` mixes every line into one WAV as long as the lesson. In the editor, that's one
giant block: you can't nudge one line, swap one take, or see where each line sits. The editor can place each
line itself, at its time, as its own clip. Then one line is one clip: drag it, trim it, redo it, mute it.

**The translator side (OpenClaw-Artist-Management/translator/srt_dubber):**
- [ ] Add a `--clips` option. Besides (or instead of) the full WAV, write each chunk's audio exactly as it
      would land in the mix to `dub/<stem>_en/clips/<chunk id>.wav`. "Exactly as it would land" means after the
      trailing-breath trim, edge fades and level gain that `Timeline.place` (`srt_dubber/audio.py`) applies.
      Same sample rate as the master.
- [ ] Add each clip's file to its chunk in `manifest.json` (`"clip": "clips/27.wav"`). Its place already exists
      there (`placed_at_ms`, `audio_ms`, `cues`, `text`, `speed`, `id`).
- [ ] Keep the single WAV as the default, so their current workflow and the delivery rules don't change.
- [ ] Tests in `srt_dubber/test_srt_dubber.py`: summing the clips at their offsets equals the master.

**The Editroom side:**
- [ ] Translate and Dub runs `srt_dubber … --clips`, reads `manifest.json`, and lays every clip on one "Dub"
      track at `placed_at_ms`. That's one library item per clip, kept in a "Dub" folder in Media.
- [ ] Each dub clip remembers which chunk and cues it speaks (a new `Clip.dubChunk: Int?` and cue ids). Then
      the editor always knows which subtitle a voice clip belongs to.
- [ ] Moving a dub clip by hand is allowed. Its subtitles follow it (they're timed to the voice, rule 4).
- [ ] Re-timing (DUBBING.md rule 4) uses each clip's own words, offset by where the clip sits now. That's more
      accurate than hearing one long file, and it stays right after a clip is moved.
- [ ] Redoing a chunk (`srt_dubber --redo <id> --clips`) replaces just that clip in place.
- [ ] Delivery: when a single WAV is still wanted (交付, or other editors), Editroom exports the Dub track's mix
      as `<stem>_en_dub.wav` from the timeline as it is now, including any hand moves.
- [ ] Ducking: the camera sound already ducks under the Dub track wherever a clip speaks (track ducking), so
      nothing extra is needed. Check that it sounds right between clips.

**Done when:** a dubbed lesson arrives as one clip per line on the timeline; dragging a clip moves its subtitle
with it; redoing one line touches only that clip.

---

## Phase 2 — Point at a bit and fix just that

Select a range on the timeline, a subtitle in the list, or a dub clip, then **right-click**:

- [ ] **Redub**: a fresh take of those lines, same words (`srt_dubber --redo <chunk ids>`; only those lines
      are billed). With Phase 1, the new takes replace just those clips.
- [ ] **Retranslate…**: type why ("she means the shadow, not the paper"). Claude fixes those lines in the
      translation JSON per the translator's CLAUDE.md, regenerates the SRTs and redubs just those lines.
- [ ] **Fix this…**: anything else, as a note ("sounds flat and repetitive", "too fast", "this makes no sense
      here"). Claude decides: new take, new wording, slower speed, or a split chunk.
- [ ] Every fix is one undo step, and lists what changed and what it cost (characters billed).
- [ ] Map a timeline selection to chunk ids through the dub clips (Phase 1) or `manifest.json` (`placed_at_ms`
      … `placed_at_ms + audio_ms`).
- [ ] Learning: each fix's reason goes where the translator's PIPELINE.md says catches go (glossary,
      corrections.jsonl, CLAUDE.md, or a machine check), so the same mistake isn't fixed twice.

---

## Phase 3 — A chat that does the whole edit

Today Magic is one request per run, and each run starts fresh.

- [ ] A chat panel beside the timeline. The conversation keeps going ("now shorten the intro", "no, the
      other camera"), using one Claude Code session that resumes between messages.
- [ ] It has every MCP tool (editing, cameras, dead air, timelapse, subtitles) and the Translate and Dub steps,
      so "edit this class and dub it" is one message. It still stops at Maya's three checks (A, B, C).
- [ ] It sees what she has selected, so "fix this" means the selection.
- [ ] Keeps the current safety rule: Claude never has both her files and the web in the same run.

---

## Phase 4 — One class, many outputs

- [ ] From one class: the Patreon lesson, a 60-second timelapse, and several Reels or Shorts. Each is its own
      edit (Editroom has one sequence per project today, so this needs multiple sequences or "make a copy as a
      new edit").
- [ ] Presets: "Patreon lesson" (full length, captions, dub), "Timelapse" (sped up, music, no voice) and "Reel"
      (vertical, 30–60 s, hook first, big captions).
- [ ] Brand voice for titles and captions from OpenClaw's `config/brand-voice.md`.
- [ ] Hand-off to Kelly (social) and Rachel (content) in OpenClaw: drop the exports where their output folders expect them.

---

## Phase 5 — Hardening

- [ ] Unit tests for the model code (subtitles, cameras, pacing, dub job) in an Xcode test target. Today they
      only run on Linux; see CLAUDE.md for how.
- [ ] A password on the local AI connection (port 47920), or turn it off by default.
- [ ] Gates graduate (translator PIPELINE.md): track how often Maya overrules each check; when one is always
      right, it becomes a report instead of a stop.
- [ ] Notarized builds with our own Developer ID (`EDITROOM_TEAM`, `scripts/release.sh`). Still no auto-updates.

---

## Known issues and open questions

- Camera sync needs each camera to record sound; a silent camera stays where it was placed.
- Editing after the dub breaks sync with the voice. The panel warns, but the real fix is Phase 1, where clips move with the edit.
- The pipeline runs on Maya's Mac. If it should run on the VPS (Oscar) instead, Editroom would send files there.
  That needs a decision before Phase 3.
- Every Claude step follows the translator's delivery rule and pushes to `main` from her Mac. Change that if
  it's unwanted.

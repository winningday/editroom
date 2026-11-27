# CLAUDE.md — Editroom (Maya's fork)

A fork of Editroom, a native macOS video editor (Swift, SwiftUI and AppKit, Xcode 26, macOS 14+, Apple
silicon). It's adapted so Maya Han (watercolor artist, @mayahan.art) can turn long, multi-camera painting
classes into Patreon lessons with English subtitles and an English dub, plus timelapses and social posts,
with as little of her time as possible.

## Read these first

| File | What's in it |
|------|--------------|
| **`TODO.md`** | **The roadmap. Start every session here.** Work the top unfinished phase only. |
| `FORK.md` | What this fork changed and how each feature works (subtitles, Whisper, cameras, pacing, Translate and Dub). |
| `README.md` | The original app, building, releasing. |
| `../OpenClaw-Artist-Management/translator/PIPELINE.md` | The translation and dubbing pipeline Editroom drives. Also read its `CLAUDE.md` and `DUBBING.md` before touching anything in Translate and Dub. |

## State of the code

- **Phase 0 isn't done.** Until `TODO.md` Phase 0 is ticked, most of this fork has never been compiled or run.
  Expect compile errors on first build, and fix them in place. Don't stack new features on unbuilt code.
- Pure model logic (no AppKit, AVFoundation or SwiftUI) is the trusted part. It typechecks and its tests pass
  under Swift 6.1 on Linux. These files are `Model/Project.swift`, `Captions.swift`, `Subtitles.swift`,
  `Angles.swift`, `Pacing.swift` and `DubJob.swift`, with the `Transcript` struct from `Engine/Transcripts.swift`.
  To check them without a Mac: copy them plus `SpeedRamp.swift`, `ZoomMove.swift`, `ColorGrade.swift`,
  `MediaFolders.swift` and `Magic/MagicHistory.swift` into one folder, strip `import CoreGraphics`, stub `UTType`
  and `MagicAgent.Tab`, and run `swiftc -typecheck *.swift`.

## Where things are

| Feature | Files |
|---------|-------|
| Subtitle layers, SRT, Chinese text | `Model/Subtitles.swift`, `Model/Captions.swift`, `Engine/CaptionRenderer.swift` |
| Subtitle list editor | `UI/SubtitleList.swift`, caption section of `UI/InspectorView.swift` |
| Whisper | `Engine/Whisper.swift`, `Engine/Transcripts.swift`, Settings › Subtitles in `UI/SettingsView.swift` |
| Cameras (multi-angle, PiP) | `Model/Angles.swift` (incl. `SoundSync`), `Model/EditorModel+Class.swift` |
| Dead air, timelapse | `Model/Pacing.swift`, `Engine/ActivityScan.swift`, `Model/EditorModel+Class.swift` |
| Translate and Dub | `Engine/DubPipeline.swift`, `UI/DubPipelineView.swift`, `Model/DubJob.swift` |
| AI tools (MCP) | `MCP/MCPTools.swift`, `MCP/MCPClassTools.swift`; Magic runs in `Magic/MagicAgent.swift` |
| Menus | `App/EditroomApp.swift` (Subtitles and Class menus) |

## Rules

- **No automatic updates, ever.** Sparkle was removed on purpose. Don't add any update check, feed or self-updater.
- **Claude never gets both her files and the web in one run** (`MagicAgent.filesAllowed`). Keep it that way in
  any new chat or agent feature.
- **The translator owns translation and dubbing.** Editroom drives `translator/` (Claude Code following its
  CLAUDE.md, `srt_dubber`, `retime_to_words.py`). Don't reimplement those stages in Swift. Change them in the
  translator repo, with its tests.
- **Maya's three checks stay human** (cleanup, translation, audition) until the translator's PIPELINE.md says
  a gate has graduated.
- Edits go through `EditorModel.mutate` (one undo step). Lesson progress goes through `EditorModel.setDubJob`
  (kept out of undo).
- New saved fields on `Project` and `Clip` must be optional, so older projects still open.
- Language: Maya reads Chinese. Anything shown to her about content can be Chinese. UI text in the app is English,
  like the rest of Editroom.
- Don't put model names or ids in commit messages, PRs or code.

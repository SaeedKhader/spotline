# Spotline: architecture and starter plan

Spotline is a native macOS subtitle editor for professional movie and TV workflows (subtitling and translation), with libmpv playback hosted through AppKit inside SwiftUI.

Status: living document; update it when a decision changes. Written 2026-09-28.

---

## 1. What "UI tools ready" means here

I read it as **"ready for UI automation and testing tools from day one"**: the app can be driven and verified by XCUITest, accessibility tooling, scripts and AI agents without retrofitting. Concretely:

- **Every interactive element has a stable accessibility identifier** (`subtitleList.row.<id>`, `transport.play`, `timeline.cue.<id>.inHandle`), defined as constants in one file, never ad-hoc strings.
- **Custom-drawn views are accessible.** The timeline, waveform and video overlay are custom NSViews/Canvas, which are invisible to automation by default. They expose `NSAccessibilityElement` children (cues as elements with value = timecode range, adjustable in/out handles).
- **One command layer.** Every user action (split cue, nudge in-point, set in at playhead, next QC error) is a named `EditorCommand`. Menus, keyboard shortcuts, toolbar, App Intents / Shortcuts and tests all invoke the same commands. This is what makes the app scriptable and testable.
- **Deterministic test mode.** Launch argument `-UITestMode` loads fixture media, uses mpv with a fixed clock (paused, exact seeks), disables animations, and exposes playback state (current frame/timecode) as accessibility values so tests can assert on it.
- **UI test target and snapshot tests exist from the first commit**, running in CI.

Confirmed by Saeed (2026-09-28): yes, AI automation, plus AI tools that work on the subtitles themselves (see section 7a).

- **Agent control surface:** the same `EditorCommand` catalog is exposed to AI agents through an optional local MCP server built into the app (off by default, localhost only). Tools like `get_cues`, `seek`, `set_cue_text`, `run_qc` map one-to-one onto commands, so an agent edits through the same undoable path as a person.

## 2. Tech baseline

| Choice | Decision | Why |
|---|---|---|
| Min macOS | 14 (Sonoma) | `@Observable`, modern SwiftUI inspector/table APIs |
| Language | Swift 6, strict concurrency | mpv calls back on arbitrary threads; the compiler should police it |
| UI | SwiftUI shell, AppKit for video, timeline, big text tables | SwiftUI `Table` struggles with 2,000+ editable rows; `NSTableView` does not |
| Document model | `NSDocument` subclass (via `ReferenceFileDocument` or plain AppKit) | Free undo manager, autosave, versions, tabs, recent files |
| Packages | Local Swift packages in one Xcode workspace | Core logic testable without the app or libmpv |
| Playback | libmpv render API | Frame-accurate, plays anything ffmpeg does (MKV, ProRes, DNxHR, MXF) |

## 3. Module layout

```
spotline/
├─ project.yml                XcodeGen spec (the .xcodeproj is generated, not committed)
├─ App/                       macOS app target (thin: scenes, menus, DI)
├─ AppUITests/                XCUITest suite (from day one)
├─ Packages/SpotlineKit/      one Swift package, one target per module:
│  ├─ SubtitleCore            pure Swift, no AppKit, no mpv: MediaTime, FrameRate, Timecode, Cue, Track
│  ├─ SpotlineAccessibility   accessibility ID catalog shared by app, UI tests and agents
│  ├─ EditorCommands          every user action as a named command
│  ├─ EditorUI                SwiftUI + AppKit views, EditorState (executes commands)
│  │  --- added in later milestones ---
│  ├─ SubtitleFormats         SRT, WebVTT, ASS/SSA, TTML/IMSC1, EBU STL, SCC
│  ├─ QualityControl          CPS, CPL, line count, durations, gaps, overlaps, shot changes
│  ├─ MPVPlayer               CMPV module map + Swift wrapper + video NSView
│  ├─ MediaAnalysis           waveform peaks, shot-change detection (libav*)
│  ├─ Translation             source/target alignment, glossary, translation memory
│  ├─ AITools                 transcription, translation, text-transform providers + job runner
│  └─ AgentBridge             local MCP server exposing EditorCommands to AI agents
└─ Fixtures/                  short test clips at 23.976 / 25 / 29.97 DF, sample subtitle files
```

Dependency direction: `App → EditorUI → (MPVPlayer, QualityControl, Translation, AITools, MediaAnalysis) → SubtitleFormats → SubtitleCore`. Nothing depends on EditorUI or App. One package with many targets keeps module boundaries while staying simple to open and build; targets can split into separate packages later if needed.

## 4. libmpv hosting (AppKit inside SwiftUI)

**Approach: mpv render API + `CAOpenGLLayer`**, the same pattern IINA uses in production.

1. `MPVPlayer` owns the `mpv_handle` inside an `actor` (or a serial queue wrapped in a class, since the render callback is C). Options set before init: `vo=libmpv`, `hwdec=videotoolbox`, `hr-seek=yes`, `keep-open=always`, `idle=yes`, `pause=yes` on load.
2. `MPVVideoLayer: CAOpenGLLayer` creates the `mpv_render_context` (`MPV_RENDER_API_TYPE_OPENGL`) and draws in `draw(inCGLContext:…)`. mpv's update callback schedules a redraw; a `CVDisplayLink`/`CADisplayLink` paces it.
3. `MPVVideoView: NSView` hosts the layer, handles resize/backing scale, and hosts the subtitle overlay.
4. `VideoPlayerView: NSViewRepresentable` bridges it into SwiftUI. SwiftUI only sees a small `@Observable PlaybackState` (time, frame, duration, paused, rate).

Notes and risks:
- OpenGL is deprecated on macOS but still works on Apple silicon; libmpv has no Metal render API. Fallback if Apple removes GL: embed via `wid` with `vo=gpu-next` + MoltenVK. The wrapper hides which one is used.
- **Frame accuracy:** seek with `seek <t> absolute+exact`, step with `frame-step`/`frame-back-step`, read `estimated-frame-number`, `container-fps`, `time-pos`. All app-side time is rational (see 5), never `Double` seconds.
- **Property observation:** `mpv_observe_property` on a wakeup callback, drained on a background queue, published to the main actor at display rate (not per event).
- **Licensing:** the app is open source (Saeed, 2026-09-28). Default mpv builds are GPL, so the simplest match is licensing the app GPL-3.0-or-later and using a stock libmpv. A permissive app license (MIT/Apache-2.0) would instead need an LGPL libmpv build (`-Dgpl=false`), linked dynamically.
- **Getting libmpv:** Homebrew dylibs are fine for development; for shipping, a prebuilt LGPL xcframework (e.g. the open-source MPVKit project) or our own build script, bundled in `Frameworks/`.

### Subtitle preview on video
Two layers, used together:
- **Live editing overlay:** mpv's `osd-overlay` command with `format=ass-events` renders ASS text through libass inside mpv, so the preview matches final styling (positioning, fonts, italics) without reloading a file on every keystroke.
- **Safe-area and guide overlay:** a transparent AppKit layer above the video for title-safe/action-safe guides, line-position markers and on-video drag handles. Uses mpv's `osd-dimensions` to map video coordinates.

## 5. Subtitle model

```swift
struct FrameRate { let num: Int; let den: Int; let dropFrame: Bool }   // 24000/1001, 25/1, 30000/1001 DF…
struct MediaTime { let value: Int64; let timescale: Int64 }             // rational seconds, lossless
struct Timecode  { hours, minutes, seconds, frames; rate }              // SMPTE label, drop-frame aware
struct Cue: Identifiable {
    let id: UUID
    var start: MediaTime, end: MediaTime
    var lines: [StyledLine]          // rich text runs: italic, bold, color, ruby
    var position: CuePosition?       // top/bottom/explicit region
    var speaker: String?, notes: String?
    var sourceCueID: UUID?           // link to original-language cue (translation)
    var flags: Set<CueFlag>          // forced narrative, SDH, locked, needs review
}
struct Track { var language: Locale.Language; var role: TrackRole; var cues: [Cue]; var styles: [Style] }
struct SubtitleProject { var media: MediaReference; var frameRate: FrameRate; var startTimecode: Timecode; var tracks: [Track] }
```

- Times snap to frames on edit; SMPTE display handles drop-frame and a program start offset (e.g. 01:00:00:00 or 10:00:00:00).
- Every mutation goes through `SubtitleCore` operations that register undo, so undo works identically from UI, commands and tests.
- Project file: a `.mtproj` package (JSON manifest + one file per track + cached waveform), with the media as a security-scoped bookmark plus path fallback for relinking.

### Formats (priority order)
1. SRT, WebVTT (import/export) — M2
2. ASS/SSA (styles preserved) — M4
3. TTML / IMSC1.1 text profile (Netflix, Apple, Amazon deliveries) — M4
4. EBU STL (binary, broadcast) — M5
5. SCC / 608 captions — later

Round-trip tests for every format live in `SubtitleFormats` with golden files.

## 6. Main window layout

```
┌──────────────────────────────────────────────────────────────┐
│ Toolbar: transport · timecode · frame rate · track picker     │
├──────────────────────────────┬───────────────────────────────┤
│  Video (mpv) + subtitle       │  Inspector: cue text editor,   │
│  overlay + safe areas         │  source vs target, QC issues,  │
│                               │  speaker, position, notes      │
├──────────────────────────────┴───────────────────────────────┤
│ Timeline: waveform · shot changes · cue blocks (drag in/out)  │
├──────────────────────────────────────────────────────────────┤
│ Cue list (NSTableView): # · in · out · dur · CPS · source · target │
└──────────────────────────────────────────────────────────────┘
```

## 7. Pro workflow features (backlog, roughly in order)

- J/K/L shuttle, frame step, set in/out at playhead, "snap to shot change", nudge by frame, split/merge cues, ripple.
- Waveform: peaks extracted once with libavformat/libavcodec (same ffmpeg libmpv ships with), cached in the project package, drawn in a tiled layer.
- Shot-change detection: ffmpeg scene score, cached, shown on the timeline, used by QC and snapping.
- QC rules with presets (Netflix Timed Text Style Guide per language, BBC, custom): max CPS, max CPL, max lines, min gap (e.g. 2 frames), min/max duration, shot-change proximity, overlap, empty cues. Issues are live, listed, and navigable with a command.
- Translation mode: source track read-only beside the editable target, per-cue status, glossary, pluggable machine-translation provider protocol (provider chosen later).
- Customizable keyboard shortcuts stored as command → key bindings.

## 7a. AI tools

All AI features share one rule: **AI proposes, the editor disposes.** Every AI job returns a `ProposedChangeSet` (new cues, text edits, timing edits) that the user reviews as a diff in the cue list and accepts per cue or all at once. Accepting applies it as one undoable edit. Nothing AI-generated lands silently.

`AITools` package, provider-agnostic:

```swift
protocol Transcriber      { func transcribe(_ audio: AudioSource, language: Locale.Language?) -> AsyncThrowingStream<TranscriptSegment, Error> }  // word-level timestamps
protocol Translator       { func translate(_ cues: [Cue], from: Locale.Language, to: Locale.Language, context: TranslationContext) async throws -> [CueTranslation] }
protocol CueTextTransform { func transform(_ cues: [Cue], instruction: TransformKind) async throws -> [CueEdit] }  // profanity, SDH removal, shorten for CPS, fix punctuation
```

| Feature | Local / on-device option | Cloud option |
|---|---|---|
| Transcription with timestamps | WhisperKit (Core ML, Apple silicon) or whisper.cpp | Any speech-to-text API with word timestamps |
| Translation | Apple Translation framework (on-device) | LLM providers (Claude etc.) with glossary and neighbouring-cue context |
| Profanity removal / softening | Word lists per language (mask, remove, replace) | LLM rewrite that keeps meaning and reading speed |
| Shorten to fit CPS/CPL | n/a | LLM rewrite constrained by QC limits |
| Speaker detection, SDH tags | later | later |

Design notes:
- **Transcript → cues segmentation** is our own code, not the model's: word timestamps are grouped into cues using the QC rules (max CPL, max duration, min gap, snap to shot changes), so output is deliverable-ready.
- **Translation uses context**, not cue-by-cue strings: a sliding window of neighbouring cues, the glossary, character names and target QC limits go to the provider; results map back by cue ID.
- **Jobs** run in a background `JobRunner` with progress, cancel and resume; long media is chunked on silence boundaries.
- **Keys and privacy:** API keys in the Keychain; a per-project setting says whether media or text may leave the machine. Local providers work fully offline.
- **Same tools for agents:** each AI feature is also an `EditorCommand`, so it appears in menus, Shortcuts and the MCP bridge.

## 8. Testing from day one

- `SubtitleCore`, `SubtitleFormats`, `QualityControl`: Swift Testing unit tests, no app needed, run in seconds.
- `MPVPlayer`: integration tests with fixture clips asserting exact frame after seek/step.
- `AppUITests`: XCUITest using the accessibility IDs and `-UITestMode` (see 1). First tests: open fixture, play/pause, step 10 frames and read timecode, add cue at playhead, edit text, undo.
- CI: GitHub Actions `macos-15` runner, `xcodebuild test` for packages and UI tests.

## 9. Milestones

| # | Goal | Done when |
|---|---|---|
| M0 | Scaffold | XcodeGen project, SpotlineKit package, CI, first UI tests pass, accessibility ID catalog and command layer exist |
| M1 | Playback | libmpv in SwiftUI window, frame-accurate seek/step, SMPTE timecode display, UI test drives it |
| M2 | Basic editing | Import/export SRT + WebVTT, cue list, text editor, set in/out at playhead, undo |
| M3 | Timeline | Waveform, cue blocks draggable, shot changes, snapping |
| M4 | Pro formats + QC | ASS, TTML/IMSC, QC engine with presets, live issues panel |
| M5 | Translation | Source/target mode, glossary, translation memory, EBU STL |
| M6 | AI tools | Transcription with timestamps → segmented cues, AI translation, profanity/cleanup transforms, review-as-diff |
| M7 | Agent bridge | Local MCP server over the command catalog |

## 10. Decisions so far

- Name: Spotline, repo SaeedKhader/spotline.
- New repository, open source, licensed GPL-3.0 with a stock GPL libmpv (Saeed, 2026-09-28).
- "UI tools ready" = AI and UI automation ready, plus AI subtitle tools (Saeed, 2026-09-28).

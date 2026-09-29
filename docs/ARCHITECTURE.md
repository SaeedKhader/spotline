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
| Min macOS | 26 (Tahoe) | Matches the Homebrew libmpv we link; raised from 15 by Saeed, 2026-09-28 |
| Language | Swift 6, strict concurrency | mpv calls back on arbitrary threads; the compiler should police it |
| UI | SwiftUI shell, AppKit for video, timeline, big text tables | SwiftUI `Table` struggles with 2,000+ editable rows; `NSTableView` does not |
| Document model | `NSDocument` subclass with AppKit-owned windows hosting SwiftUI | Free undo manager, autosave, versions, tabs, recent files; AppKit opens windows deterministically at launch, which SwiftUI scenes did not under UI tests |
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
│  ├─ PlaybackCore            PlaybackEngine protocol + PlaybackStatus; simulated engine for tests
│  ├─ CMPV                    libmpv headers and link flags (system library, pkg-config)
│  ├─ MPVPlayer               libmpv player, CAOpenGLLayer render layer, video NSView
│  ├─ EditorUI                SwiftUI + AppKit views, EditorState (executes commands)
│  │  --- added in later milestones ---
│  ├─ SubtitleFormats         SRT, WebVTT, ASS/SSA, TTML/IMSC1 (M4), EBU STL, SCC
│  ├─ QualityControl          CPS, CPL, line count, durations, gaps, overlaps, shot changes
│  ├─ MediaAnalysis           waveform peaks, shot-change detection (libav*)
│  ├─ Translation             source/target alignment, glossary, translation memory
│  ├─ AITools                 transcription, translation, text-transform providers + job runner
│  └─ AgentBridge             local MCP server exposing EditorCommands to AI agents
└─ Fixtures/                  short test clips (M1: 23.976 fps MP4 and MKV), later 25 / 29.97 DF and subtitle files
```

Dependency direction: `App → EditorUI → (MPVPlayer, QualityControl, Translation, AITools, MediaAnalysis) → SubtitleFormats → SubtitleCore`. Nothing depends on EditorUI or App. One package with many targets keeps module boundaries while staying simple to open and build; targets can split into separate packages later if needed.

## 4. libmpv hosting (AppKit inside SwiftUI)

**Approach: mpv render API + `CAOpenGLLayer`**, the same pattern IINA uses in production.

1. `MPVPlayer` owns the `mpv_handle` inside an `actor` (or a serial queue wrapped in a class, since the render callback is C). Options set before init: `vo=libmpv`, `hwdec=videotoolbox`, `hr-seek=yes`, `keep-open=always`, `idle=yes`, `pause=yes` on load.
2. `MPVVideoLayer: CAOpenGLLayer` creates the `mpv_render_context` (`MPV_RENDER_API_TYPE_OPENGL`) and draws in `draw(inCGLContext:…)`. mpv's update callback schedules a redraw; a `CVDisplayLink`/`CADisplayLink` paces it.
3. `MPVVideoView: NSView` hosts the layer, handles resize/backing scale, and hosts the subtitle overlay.
4. `VideoPlayerView: NSViewRepresentable` bridges it into SwiftUI. SwiftUI only sees a small `@Observable PlaybackState` (time, frame, duration, paused, rate).

As built in M1:
- `MPVPlayer` is a `@MainActor` class implementing `PlaybackEngine`; a thread-safe `MPVHandle` owns the `mpv_handle` and drains events on a private queue, delivering them to the main actor in order.
- The player owns one `MPVVideoView` for its lifetime, because libmpv allows one render context per handle. Loads wait until the layer has created its render context, since mpv drops the video track of files opened without one.
- Seeks and frame steps are `seek <t> absolute+exact`, aimed a quarter frame before the target frame's start: mpv shows the first frame at or after the target (with a 5 ms tolerance), and MKV rounds timestamps to the millisecond. Rapid steps count from the last requested frame, so ten clicks move exactly ten frames. Tests check every frame of the MP4 and MKV fixtures.
- Test mode (`-UITestMode`) turns off audio and hardware decoding. `-OpenMedia <path>` opens a file at launch.

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

As built in M2:
- `SubtitleFormats` reads and writes SRT and WebVTT. Cue text is kept as written (inline tags and entities included), times are exact rationals (an SRT `00:00:01,5` is 3/2 s), so import then export changes only layout. Reading is lenient (missing cue numbers, `.` separators, CRLF, BOM, UTF-16, Windows-1252); writing is canonical UTF-8. WebVTT cue identifiers and settings are dropped until cues gain positioning (M4).
- Undo: `EditorState` owns an `UndoManager` and snapshots the track per edit (import, add, delete, set in/out, text). Keystrokes in one typing session on one cue undo as one step. The editor's Undo/Redo commands replace the text system's, so there is one undo stack.
- Shortcuts that are typing keys (I, O, Space, arrows, ⌘⌫) are disabled in the menus while the cue text editor has focus (`KeyShortcut.conflictsWithTextEditing`), so typing never triggers them. Escape leaves the text editor.
- Parameterized edits (`select`, `setText`) are `EditorState` methods that share the same undo path; they become command arguments with the agent bridge (M7).
- Cue in/out are shown as the first frame showing the cue and the first frame without it (`MediaTime.firstFrame(at:)`); selecting a cue seeks to its first frame.
- There is no project file yet: the app keeps a single AppKit-owned window, shows the subtitle file's name and an edited dot, and asks to export unsaved changes on quit. NSDocument arrives with the `.mtproj` project format.

### Formats (priority order)
1. SRT, WebVTT (import/export) — M2
2. ASS/SSA (styles preserved) — M4, done
3. TTML / IMSC1.1 text profile (Netflix, Apple, Amazon deliveries) — M4, done
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

### As built in M3 (timeline)
- `MediaAnalysis` opens the media with FFmpeg's libraries (`CFFmpeg`, Homebrew's ffmpeg that mpv depends on) and runs two background jobs side by side, because audio decodes in seconds while shot detection decodes every video frame (minutes for a feature). The waveform job reduces the audio track mpv is playing (`PlaybackStatus.audioStreamIndex`; switching tracks re-analyzes) to 100 peaks per second, from the center channel alone in 5.1/7.1 mixes (dialogue, as in the M6 audio pipeline) and from a mono mix otherwise; the shot-change job shrinks each video frame to 64×36 RGB and scores it against the previous frame the way FFmpeg's `scene` filter does (threshold 0.3). Results are cached in `~/Library/Caches/<bundle id>/MediaAnalysis`, keyed by path, size and modification date (waveforms also by audio stream, so switching tracks redoes only the waveform), until project packages exist. Results stream in: each job reports what it has found a few times a second, so the timeline fills in from left to right (unread media is striped) and cuts found so far already work for navigation and snapping. `-NoAnalysisCache` (and UI test mode) always analyzes.
- `TimelineView` is a hand-drawn `NSView` (ruler, waveform normalized to its loudest peak, yellow shot-change lines, cue blocks, red playhead) bridged with `NSViewRepresentable`. Click to seek, click a block to select, drag the body to move, drag an edge to trim; scroll to pan, pinch or ⌘-scroll to zoom.
- Drags move in whole frames and snap within 8 points to shot changes, the playhead and other cues' edges (exactly, even when those are off-frame times from SRT). The drag previews live and lands as one undoable edit (`EditorState.setTiming`). The math lives in `CueDrag` and is unit tested.
- Accessibility: the timeline exposes the playhead, each shot change and each cue with its in/out handles as `NSAccessibilityElement`s (IDs in `AccessibilityID.Timeline`); handles support increment/decrement by one frame.
- New commands: Go to Previous/Next Shot Change (⌥← / ⌥→), Zoom In/Out (⌘= / ⌘-), and the "Snap to Shot Changes and Cues" toggle.
- Audio tracks: `PlaybackStatus` lists the media's audio tracks (language, title, channels, FFmpeg stream) from mpv's `track-list`; Playback › Audio Track chooses one (`EditorState.selectAudioTrack`), and Next Audio Track (⌥⌘A) cycles. The waveform follows the playing track.

### As built in M3b (speech-aware waveform)
- Waveform peaks are taken after a voice-band filter (`VoiceBandFilter`: 150 Hz to 4 kHz, 24 dB/octave Butterworth biquads), so bass, rumble and hiss no longer hide speech.
- A third background job, `MediaAnalyzer.speech`, feeds the same mono (or center-channel) audio to Apple's on-device sound classifier (SoundAnalysis, `SNClassifySoundRequest(.version1)`) in 1 s windows every 0.5 s, and keeps windows scoring at least 0.5 for "speech" as `SpeechRegion`s. It runs about 200× faster than real time (roughly 30 s for a 2-hour film), streams partial results like the other jobs and is cached per audio track. This is also the speech-detection step of the M6 audio pipeline.
- The timeline draws speech in mint and dims everything else; Timeline › Highlight Speech in Waveform turns it off. True dialogue/music separation (e.g. Demucs) stays with the M6 AI tools.
- Tests generate speech at run time with macOS `say` rather than committing synthesized recordings.
- Status (Saeed, 2026-09-29): good enough for now, not perfect; revisit later (e.g. per-scene tuning or source separation).

### As built in M3.5 (UI design pass)
Layout agreed with Saeed (2026-09-29), replacing section 6's sketch:

```
┌────────────────────────────────┬─────────────────────────────┐
│ Cue list = editor: # · S/E ·   │ Video + subtitle overlay     │
│ c/s · review · text · actions  │ (white, black outline,       │
│ footer: "N cues need review" ↑↓│  title-safe, top or bottom)  │
├────────────────────────────────┴─────────────────────────────┤
│ Actions bar: transport · in/out · add/split/merge/delete ·     │
│ snapping · zoom ······ analysis status · timecode · fps        │
├──────────────────────────────────────────────────────────────┤
│ Mini-map: whole media, speech, cues, shot changes, viewport    │
├──────────────────────────────────────────────────────────────┤
│ Timeline                                                       │
└──────────────────────────────────────────────────────────────┘
```

- Each cue row edits its cue in place: start/end fields accept SMPTE timecode or HH:MM:SS,mmm; text is a two-line editor; hover or selection shows Default/Top position and add/split/merge/delete. Rows are lazily built.
- Row buttons and the actions bar repeat menu commands on purpose (Saeed's exception to "no duplicates"); they run the same `EditorCommand`s.
- Times show as frames by default (the professional convention); View › Show Timecodes in Milliseconds switches.
- `Cue.position` (bottom/top) round-trips as `{\an8}` in SRT and `line:0` in WebVTT.
- `Review` flags empty cues, overlaps, more than 20 c/s, lines over 42 characters and more than 2 lines; the footer counts them and ⌥⌘↑/⌥⌘↓ step through them. Full QC presets remain M4.
- New commands: Split Cue (⌥⌘S), Merge with Next (⌥⌘J), Show Cue at Top (⌥⌘T), J/K/L shuttle (backward, pause, forward, faster on repeat; mpv plays backward), and ⌘↑/⌘↓ now also work while typing, keeping the cursor in the text.
- Per-frame state (`position`, `currentCueID`) is observed separately from everything else, so only the timecode, timeline, overlay and mini-map playhead redraw during playback.
- No overlaps (Saeed, 2026-09-29): edits keep cues in the same position at least 2 frames apart (`EditorState.room(for:)` clamps drags, typed times, Set In/Out and new cues; snapping targets the gap). A top cue may run alongside bottom ones. Overlaps in imported files are kept, flagged for review, and Cue › Fix Overlaps trims them.
- The window uses the dark appearance.

### As built in M4 (pro formats and QC)
- **Formats.** `SubtitleFormats` reads and writes ASS (v4.00+), SSA (v4.00) and TTML, alongside SRT and WebVTT.
  - Cue text keeps one markup whatever the file (SRT's): `<i>`, `<b>`, `<u>`, `<s>`, entities for `<`, `>` and `&`, and ASS override blocks (`{\fs48}`) kept as written. ASS `{\i1}`…`{\i0}` and TTML `tts:fontStyle` spans convert to and from it (`Markup`); tags a format can't express are dropped on export (e.g. `<v Anna>` in ASS).
  - `SubtitleTrack` gained `styles` (`SubtitleStyle`: font, colors with opacity, bold/italic/underline/strike-out, scale, spacing, angle, border style, outline, shadow, numpad alignment, margins, encoding) and `properties` (the ASS `[Script Info]` fields, e.g. `PlayResX`, kept for round trips). `Cue` gained `style` (the style's name) and `speaker` (ASS Name). Import is one undoable edit that replaces cues, styles, properties and language.
  - ASS/SSA: columns are read by the `Format` lines; SSA's alignments (1–3, 5–7, 9–11) and decimal colors convert. A cue's position is its style's alignment, or the first `{\anN}`/`{\aN}` override; on export an override is written only when the position differs from the style's. Tracks from other formats export with one `Default` style on a 1920×1080 script (Arial 64, white with a black outline, title-safe margins). Times are centiseconds (the format's precision). Not kept yet: `Comment` lines, layers, per-line margins and effects, `[Fonts]`/`[Graphics]`.
  - TTML: parsed with `XMLParser` into a small tree (Foundation's `XMLDocument` drops whitespace-only text, which in TTML is the space between spans). Reads clock, frame (`ttp:frameRate`, `ttp:frameRateMultiplier`), tick and offset times, `begin`/`end`/`dur` on `body`, `div`, `p` (and spans of untimed paragraphs), referenced and inherited styles, `xml:space`, `xml:lang`, and regions (%, px, c) for top/bottom. Writes an IMSC 1.1 Text Profile document: media-time `HH:MM:SS.mmm`, one default style, `top` and `bottom` regions inside the title-safe area. `.dfxp` and `.xml` files import as TTML.
  - Golden files cover every format; lenient inputs (an Aegisub file, a legacy SSA file, a Netflix-style frame-timed TTML, a prefixed EBU-TT-style file with ticks) normalize to `Input/*.expected.*`.
- **QC.** A new `QualityControl` module replaces `SubtitleCore.Review` (and `SubtitleGuidelines`). `QualityControl.check` takes the cues, a `QCPreset` and the frame rate and shot changes, and returns `QCIssue`s per cue: empty and overlapping cues are errors; reading speed, characters per line, line count, minimum and maximum duration, gaps shorter than the preset's (counted in frames, per position) and cue edges near a shot change are warnings.
  - Shot-change rule: a start within `shotChangeFrames` (12) of a cut should be on it; an end should be on the cut or the minimum gap (2 frames) before it.
  - Presets: Netflix (Adult) (42 characters, 2 lines, 20 c/s, 5/6 s to 7 s), Netflix (Children) (17 c/s), Broadcast (37 characters, 15 c/s, 1 s to 7 s; conservative values in the spirit of BBC/EBU practice, to be tuned per broadcaster) and Basic (what M3.5 checked). Netflix (Adult) is the default; the choice is remembered in user defaults (not in UI tests).
  - The editor keeps edits the preset's minimum gap apart. Issues are recomputed whenever cues, the preset, the frame rate or the shot changes change, so they are live while shot detection streams in.
- **Review menu:** Show Issues (⌥⌘I), Previous/Next Cue with Issues (⌥⌘↑/↓, moved from Cue), Fix Overlaps and Short Gaps (was Fix Overlaps; same command ID), and the QC Preset picker.
- **Issues panel:** under the cue list (a split, closed by default), one row per issue in cue order with severity, cue number, start and message; clicking selects the cue. The footer gained the panel toggle and the preset's name (its tooltip explains the limits). Cue-row icons and the mini-map show errors in red and warnings in orange.
- The video shows a top cue and a bottom cue at the same time (a sign over dialogue); the top one's accessibility ID is `video.subtitle.top`.
  - On the timeline, a top cue and a bottom cue that are on screen together split the cue block's height, the top one above, so neither hides the other; other cues keep the full height.

### Embedded subtitle tracks
- **mpv never renders subtitles** (`sid=no`, `sub-auto=no`): the only text over the picture is Spotline's cue overlay, so a file's own tracks can't be mistaken for the cues being edited.
- **Import on open.** When media opens, `MediaAnalyzer.subtitleTracks(in:)` lists its subtitle streams (codec, language, title, default/forced/SDH, text or image). Image-based tracks (PGS, VobSub, DVB) can't be imported and are never shown. The first time a file with text tracks opens (remembered per path in user defaults; every time in UI tests), a sheet offers them in a scrolling list with the default track preselected; "Also save a copy" asks where to save the result (suggesting `<video>.<lang>.<ext>` next to the video). File › Import Embedded Subtitles… reopens the sheet later; it is off when the media has no text tracks.
- **Reading.** `MediaAnalyzer.subtitles(in:streamIndex:)` demuxes one stream with FFmpeg, timed from the container's start time like mpv's clock. SubRip and WebVTT packets are cue text kept as written; ASS keeps its header (styles, `[Script Info]`) via `SubtitleTrack(assHeader:events:)`; other text codecs (MP4 timed text) go through FFmpeg's decoder to ASS events and become plain cues. Import is one undoable edit, like importing a file; the cues then have no file until exported.

## 7. Pro workflow features (backlog, roughly in order)

- J/K/L shuttle, frame step, set in/out at playhead, "snap to shot change", nudge by frame, split/merge cues, ripple.
- Waveform: peaks extracted once with libavformat/libavcodec (same ffmpeg libmpv ships with), cached in the project package, drawn in a tiled layer.
- Shot-change detection: ffmpeg scene score, cached, shown on the timeline, used by QC and snapping.
- QC rules with presets (Netflix Timed Text Style Guide per language, BBC, custom): max CPS, max CPL, max lines, min gap (e.g. 2 frames), min/max duration, shot-change proximity, overlap, empty cues. Issues are live, listed, and navigable with a command.
- Translation mode: source track read-only beside the editable target, per-cue status, glossary, pluggable machine-translation provider protocol (provider chosen later).
- Customizable keyboard shortcuts stored as command → key bindings.

## 7a. AI tools

### Audio preparation pipeline (M6, shared by every AI tool)

1. **Extract dialogue:** in a 5.1 or 7.1 source, take the center channel. Otherwise mix down to mono.
2. **Resample to 16 kHz mono.** Decode with the FFmpeg libraries libmpv already bundles (libavformat/libswresample), not AVFoundation, which can't read MKV.
3. **Detect speech (VAD):** split into chunks of about 30 s to a few minutes, cut at pauses. Store each chunk's start time so timestamps map back exactly.
4. **Cache** the prepared audio in the project so transcription, diarization and gender tagging (section 7b) reuse it.
5. **Encode for the destination:** on-device (WhisperKit) takes raw 16 kHz PCM. Cloud takes Opus at about 24 to 32 kbps per chunk (roughly 20 to 30 MB for 2 hours), staying under upload caps (about 25 MB on some APIs). Chunks upload in parallel and retry independently.
6. **Privacy:** on-device by default. Cloud upload is opt-in per project with a warning, since pro content is often under NDA.

### AI features

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

## 7b. Gender and addressee context for translation

Some target languages (Arabic first; also Hebrew, French, Spanish, etc.) change the sentence depending on who speaks and who is addressed: "You are busy" is انت مشغول / انتِ مشغولة / انتما مشغولان / انتم مشغولون / انتن مشغولات. The AI fills this context in automatically and flags what it is unsure of; the user only fixes low-confidence lines. Nobody tags lines by hand.

- **Speakers:** transcription runs voice diarization (Speaker A, B…), and a voice classifier guesses each speaker's gender. Names are optional. Speakers live in a project cast list (`Speaker { id, name?, gender, confidence }`), reusable across episodes.
- **Per cue:** `speakerID` plus `addressee: Addressee` (`.male`, `.female`, `.dualMale`, `.dualFemale`, `.groupMale`, `.groupFemale`, `.groupMixed`, `.unknown`) with a confidence and a source (inferred / user-confirmed).
- **Addressee inference:** the Translator reads the whole scene, not one cue: turn-taking (the previous speaker is usually the addressee), names, later "he/she" references, gender marked in the source language, and optionally a video frame sent to a vision model.
- **Output:** for gendered lines with low confidence, the Translator returns every variant and marks its pick as a guess (`CueTranslation.variants`, `assumption`). The cue list shows a ♂/♀/group chip; one click swaps variants. Still reviewed as a diff (7a).
- **Propagation:** confirming a speaker's gender updates all their lines. Confirming an addressee suggests the same for neighbouring cues in the scene (shot changes + pauses) and re-translates only those.
- **Review filter:** "gender guesses" in the QC/issues panel, so the user reviews only flagged lines.
- Milestone: model fields in M5 (Translation), inference and variants in M6 (AI tools).

## 8. Testing from day one

- `SubtitleCore`, `SubtitleFormats`, `QualityControl`: Swift Testing unit tests, no app needed, run in seconds.
- `MPVPlayer`: integration tests with fixture clips asserting exact frame after seek/step.
- `AppUITests`: XCUITest using the accessibility IDs and `-UITestMode` (see 1). First tests: open fixture, play/pause, step 10 frames and read timecode, add cue at playhead, edit text, undo.
- CI: GitHub Actions `macos-26` runner, `xcodebuild test` for packages and UI tests.

## 9. Milestones

| # | Goal | Done when |
|---|---|---|
| M0 | Scaffold | XcodeGen project, SpotlineKit package, CI, first UI tests pass, accessibility ID catalog and command layer exist |
| M1 | Playback | libmpv in SwiftUI window, frame-accurate seek/step, SMPTE timecode display, UI test drives it |
| M2 | Basic editing | Import/export SRT + WebVTT, cue list, text editor, set in/out at playhead, undo |
| M3 | Timeline | Waveform, cue blocks draggable, shot changes, snapping |
| M3b | Speech-aware waveform | Waveform filtered to the voice band; on-device speech detection draws speech brightly and dims music and effects |
| M3.5 | UI design pass | One layout, look and keyboard flow for video, cue list, editor and timeline, before M4–M7 add panels |
| M4 | Pro formats + QC | ASS, TTML/IMSC, QC engine with presets, live issues panel |
| M5 | Translation | Source/target mode, glossary, translation memory, EBU STL |
| M6 | AI tools | Audio preparation pipeline, transcription with timestamps → segmented cues, AI translation, profanity/cleanup transforms, review-as-diff |
| M7 | Agent bridge | Local MCP server over the command catalog |

## 10. Decisions so far

- Name: Spotline, repo SaeedKhader/spotline.
- New repository, open source, licensed GPL-3.0 with a stock GPL libmpv (Saeed, 2026-09-28).
- "UI tools ready" = AI and UI automation ready, plus AI subtitle tools (Saeed, 2026-09-28).
- Gender/addressee context for Arabic and similar languages: AI infers speaker and addressee, flags low-confidence lines with variants, user only fixes those (Saeed, 2026-09-28). See 7b.

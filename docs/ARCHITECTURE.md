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
  As built in M7 (docs/AGENTS.md): agents launch `spotline-mcp`, a stdio helper in the app bundle, which relays tool calls to the app over a Unix domain socket in Application Support (user-only permissions, no network listener). Off by default, turned on in Settings › Agents. Agent edits are ordinary undo steps; cleanup proposals still wait for the person to accept or reject them.

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
│  ├─ SubtitleTranslation     source/target alignment, glossary, translation memory (not "Translation": that name hides Apple's framework)
│  ├─ AITools                 transcription, translation, text-transform providers + job runner
│  ├─ AgentBridge             MCP tool catalog, JSON-RPC and the local socket to the app (M7)
│  └─ SpotlineMCP             the `spotline-mcp` stdio helper agents launch
└─ Fixtures/                  short test clips (M1: 23.976 fps MP4 and MKV), later 25 / 29.97 DF and subtitle files
```

Dependency direction: `App → EditorUI → (MPVPlayer, QualityControl, SubtitleTranslation, AITools, MediaAnalysis) → SubtitleFormats → SubtitleCore`. Nothing depends on EditorUI or App. One package with many targets keeps module boundaries while staying simple to open and build; targets can split into separate packages later if needed.

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
- Project file: a `.spotline` package (JSON manifest + one file per track + cached analysis and AI results), with the media as a security-scoped bookmark plus path fallback for relinking. Built in M9 (below).

As built in M2:
- `SubtitleFormats` reads and writes SRT and WebVTT. Cue text is kept as written (inline tags and entities included), times are exact rationals (an SRT `00:00:01,5` is 3/2 s), so import then export changes only layout. Reading is lenient (missing cue numbers, `.` separators, CRLF, BOM, UTF-16, Windows-1252); writing is canonical UTF-8. WebVTT cue identifiers and settings are dropped until cues gain positioning (M4).
- Undo: `EditorState` owns an `UndoManager` and snapshots the track per edit (import, add, delete, set in/out, text). Keystrokes in one typing session on one cue undo as one step. The editor's Undo/Redo commands replace the text system's, so there is one undo stack.
- Shortcuts that are typing keys (I, O, Space, arrows, ⌘⌫) are disabled in the menus while the cue text editor has focus (`KeyShortcut.conflictsWithTextEditing`), so typing never triggers them. Escape leaves the text editor.
- Parameterized edits (`select`, `setText`) are `EditorState` methods that share the same undo path; the agent bridge (M7) passes them as tool arguments.
- Cue in/out are shown as the first frame showing the cue and the first frame without it (`MediaTime.firstFrame(at:)`); selecting a cue seeks to its first frame.
- M2 had no project file: one AppKit-owned window that asked to export unsaved changes on quit. M9 replaced it with project documents.

As built in M9 (project files):
- `SpotlineDocument` (an `NSDocument`) per project window, each with its own `EditorState` and player; `EditorWorkspace` tracks the window in front for the menus and agents, and shares Settings › AI between windows. With no window open, the menus read a stand-in editor that only allows New Project, Open Project and Open Media.
- The package (`ProjectFile`): `project.json` (format version, video reference, frame rate, QC preset, subtitle and source files, selection, playhead), `subtitles.json` and `source.json` (the tracks as Codable, so AI tint, translation flags, variants and the cast survive), `Analysis/` (waveform and speech per audio stream, shot changes) and `AI/` (each transcriber's raw words). Reading is lenient about the caches; a newer format version is refused.
- Standard Mac behaviour from AppKit: autosave in place, File › Revert To (last saved version, or browse all versions), window restoration, Open Recent. The editor keeps its own undo stack and reports each change to the document (`ProjectChange`: edit, undo, redo, other), which drives the edited state and autosave.
- The first AI tool run on an untitled project with a video saves it beside the video (`Episode 1.spotline`, or `Episode 1 2.spotline` when taken) without asking, so results are never lost. Transcribing again reuses the saved words instead of uploading the audio again. Reopening a project analyzes nothing: stored waveforms, speech and shot changes are used (`~/Library/Caches` stays a second cache).
- The video is found by bookmark (follows moves and renames on its disk), then by its path, then by its path from the project, then beside the project. Otherwise Spotline asks where it went; the cues open either way, the project keeps pointing at the video, and opening the video later relinks it.
- Opening media in a window that already has a video opens a new project window (agents too), so nothing is replaced. SRT, ASS, TTML, STL and the rest stay imports and exports.

### Formats (priority order)
1. SRT, WebVTT (import/export) — M2
2. ASS/SSA (styles preserved) — M4, done
3. TTML / IMSC1.1 text profile (Netflix, Apple, Amazon deliveries) — M4, done
4. EBU STL (binary, broadcast) — M5, done
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
- The timeline draws speech in mint and dims everything else; View › Highlight Speech in Waveform turns it off. True dialogue/music separation (e.g. Demucs) stays with the M6 AI tools.
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
- No overlaps (Saeed, 2026-09-29): edits keep cues in the same position at least 2 frames apart (`EditorState.room(for:)` clamps drags, typed times, Set In/Out and new cues; snapping targets the gap). A top cue may run alongside bottom ones. Overlaps in imported files are kept, flagged for review, and Review › Fix Overlaps and Short Gaps trims them.
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
- **mpv never renders subtitles** (`sid=no`, `secondary-sid=no`, `sub-auto=no`, and the renderer hidden with `sub-visibility=no` in case a track is ever selected) and shows no OSD (`osd-level=0`): the only text over the picture is Spotline's cue overlay, so a file's own tracks can't be mistaken for the cues being edited.
- **Opening new media starts over.** Replacing open media clears the cues, the translation source, undo, the selection, the analysis and the embedded-subtitle offer at once (not when the new file loads), and scrolls the timeline to the start. Unsaved subtitles prompt Export…/Don't Export/Cancel first. Subtitles imported before any media opens are kept for it. View preferences, the QC preset, the glossary and the memory stay.
- **Import on open.** When media opens, `MediaAnalyzer.subtitleTracks(in:)` lists its subtitle streams (codec, language, title, default/forced/SDH, text or image). Image-based tracks (PGS, VobSub, DVB) can't be imported and are never shown. The first time a file with text tracks opens (remembered per path in user defaults; every time in UI tests), a sheet offers them in a scrolling list with the default track preselected; "Also save a copy" asks where to save the result (suggesting `<video>.<lang>.<ext>` next to the video). File › Import Embedded Subtitles… reopens the sheet later; it is off when the media has no text tracks.
- **Reading.** `MediaAnalyzer.subtitles(in:streamIndex:)` demuxes one stream with FFmpeg, timed from the container's start time like mpv's clock. SubRip and WebVTT packets are cue text kept as written; ASS keeps its header (styles, `[Script Info]`) via `SubtitleTrack(assHeader:events:)`; other text codecs (MP4 timed text) go through FFmpeg's decoder to ASS events and become plain cues. Import is one undoable edit, like importing a file; the cues then have no file until exported.

### As built in M5 (translation)
- **Translation mode.** Translation › Open Source Subtitles… (⌥⌘O) reads a file as the read-only source; the editor's track is the target. An empty target becomes the source's timing with no text (one undoable edit); cues already there are paired with the source cue they overlap most (same position first). Each target cue links to its source (`Cue.sourceCueID`); splits keep the link. Close Source Subtitles leaves the mode. The window subtitle reads "Translating from <file>", and export suggests `<name>.<target language>.<ext>` beside the source.
- **Layout.** Each cue row shows the source text (read-only, selectable) beside the target editor, each in its own direction: `TextDirection` comes from the language (Arabic, Hebrew, Persian, Urdu are right to left), else from the text's letters. The list widens in translation mode. No new panels in the main window: the source column, glossary chips and memory suggestions live in the rows.
- **Languages.** Source and target languages come from the file, else `NLLanguageRecognizer`; a new translation's target is the last one chosen (Arabic by default). Translation › Target Language changes it (undoable; exports carry it).
- **Glossary** (`Translation.Glossary`): source term, agreed translation, note, per language pair. Terms match whole words ignoring case, accents, Arabic/Hebrew vowel marks, hamza forms, tatweel and ى/ي, ة/ه (`MatchText`). A row shows the terms its source uses, green when the target uses the translation and orange when not. Translation › Show Glossary (⌥⌘G) opens a floating panel to edit terms; Import Glossary… reads CSV or tab-separated files (source, target, note; header optional).
- **Translation memory** (`SubtitleTranslation.TranslationMemory`): pairs are stored when you leave a translated cue, on export, and with Add All Translations to Memory. The selected row lists up to three suggestions (exact 100%, fuzzy from 70% by word-level edit distance); click one, or Use Best Memory Match (⌃⌘M). Fill Untranslated Cues from Memory fills every empty cue with an exact match in one undoable edit. Copy Source to Target (⌥⌘C) copies names and signs.
- **Storage.** Glossary and memory live in `~/Library/Application Support/<bundle id>/Translation/<source>-<target>/` (`glossary.json`, `memory.json`). They are shared by every project with that language pair (M9 kept them out of the package). UI tests use neither.
- **QC on the target.** M4's presets, issues panel and Review menu check the target. Translation adds: an empty target whose source has text is "Not translated" (an error), and a glossary term whose translation is missing is a warning.
- **Gender and number (7b).** Replaced in M10 by translation flags; see section 7b.
- **EBU STL** (`SubtitleFormats.EBUSTL`): reads and writes the GSI and TTI blocks. `STL25.01` is 25 fps; `STL30.01` is read and written as 29.97 non-drop. Character tables: Latin (ISO 6937, with accents as prefix diacritics), Cyrillic, Arabic, Greek and Hebrew (ISO 8859-5 to -8), chosen on export from the text's script. Italics and underline map to `<i>`/`<u>`; teletext colour, double-height and box codes are dropped on read; rows in the top half make top cues; extension blocks join and long text is split across them; comments and user data are skipped; times are taken from the programme start (TCP), which is kept (`EBU.TCP`) with the title, translator, publisher and country. Written as teletext (DSC 1, 23 rows, 40 characters), centred, bottom lines ending on row 22. Characters the table lacks become "?". A text `.stl` (Spruce STL) is not read.

### As built in M6 (AI tools)
- **Providers (chosen 2026-09-29).** On-device by default, cloud opt-in (Settings › AI: "Allow cloud providers", off by default; API keys in the login Keychain).
  - Transcription: Apple **SpeechAnalyzer** (`SpeechTranscriber`, macOS 26) on this Mac; macOS downloads a language's model once after the app asks. Cloud: **OpenAI Whisper** (`whisper-1`, word timestamps), chunks sent as Ogg Opus at 24 kbit/s, four at a time, each retried on its own. WhisperKit was not used: it needs bundled Core ML models (hundreds of MB) and Apple's model is managed by the OS.
  - Translation: Apple **Translation** framework on this Mac (languages downloaded in System Settings). Cloud: **Claude** (`claude-opus-5-5`; since M10 `claude-sonnet-5-5`, at half the price, is a choice in Settings › AI. Messages API with a JSON-schema structured output, server-side fallbacks), or OpenAI's **GPT-6 Luna** (`gpt-6-luna`, far cheaper; Responses API with the same prompt and a strict JSON schema, `store: false`), sent in batches of 40 lines with the 6 lines before, the glossary terms the lines use, translation memory examples, the transcriber's voice labels, the cast known so far and QC limits.
  - Cleanup always runs on this Mac.
- **Audio preparation** (`MediaAnalysis.prepareAudio`): the audio track mpv plays, center channel of 5.1/7.1 else a mono mix, resampled to 16 kHz with libswresample; VAD by loudness (30 ms frames 12 dB over the noise floor or above -35 dBFS, breaths under 0.4 s bridged); chunks of up to 30 s ending at pauses, silence left out, each with its media start time. Cached in `~/Library/Caches/<bundle id>/MediaAnalysis` as 16-bit PCM plus a JSON index. `OpusEncoder` makes Ogg Opus for cloud uploads.
- **Transcript → cues** (`CueSegmenter`): our code, from word timestamps: a new cue at a pause of 0.8 s, when text passes the preset's lines × characters or its maximum duration, or at a sentence end once the cue has half a line; two balanced lines preferring a break after punctuation; ends 0.5 s after the last word, at least the minimum duration, the minimum gap before the next; starts and ends snap to shot changes within the preset's distance. Transcription only proposes cues where none exist.
- **Speakers and addressees** (M6's pitch-based `VoiceSpeakerAnalyzer` and `SceneAddresseeInferrer`, with per-line ♂/♀ chips) were removed in M10: see section 7b.
- **Cleanup** (`CleanupTool`): Mask Profanity (word stems in English, French, Spanish, German, Arabic), Remove Hearing-Impaired Text (brackets, parentheses, music notes, speaker labels; cues left empty are proposed for removal), Fix Spacing and Punctuation (double spaces, spaces before punctuation, "…", Arabic comma and question mark).
- **Translate with AI** (⌃⌘T) fills the empty target cues in translation mode. Outside it, the cues being edited (say, a transcription) become the source and the target starts as their timing with no text, in the last target language (Arabic by default).
- **Filling versus rewriting (Saeed, 2026-09-29).** Transcription and translation only fill empty cues and gaps, so their results go straight into the cue list as they arrive: each batch is one undoable edit, AI-written text is tinted with a ✨ until someone edits it, and a result never overwrites what the user did meanwhile (a new cue that would overlap one, a cue the user typed in). Transcription writes each cue once the word after it is heard. A bar over the cue list shows the running tool with Stop. Cleanup rewrites existing text, so it stays a review: proposed text shows in place of the text editor as a word diff with ✓/✗, the bar shows "Mask Profanity: 12 changes to review" with Accept All and Reject All, and AI › Accept Change (⌘↩) / Reject Change (⌥⌘⌫) move through the changes; each acceptance is one undoable edit.
- **Starting over.** AI › Clear Translation empties every target cue (text, flagged choices, the ✨ tint) and keeps its timing and source link, so Translate with AI fills it again. AI › Clear Transcript… removes the transcribed cues and the transcripts the project keeps, after saying that the next Transcribe Audio pays the transcriber again; in translation mode the transcript is the source, so the translation made from it goes too and the editor leaves translation mode. Each is one undoable edit, and agents run both with `run_command` (no dialog).
- **UI tests** run with scripted providers (`ScriptedTranscriber`, `ScriptedTranslator`): no models, no network.

### As built in M8 (UI revision)
Agreed with Saeed (2026-09-29) after an audit of M0 to M7:
- **AI tint.** Text and cues an AI tool wrote are purple (`Color.aiTint`, `SpotlineStyle.swift`) until edited: in the cue list, the review bar, proposals, the timeline and the mini-map. The accent colour marks only the selection.
- **No duplicate buttons.** The review footer is gone: "N cues need review · preset" sits on the right of the actions bar, and View › Show Issues (⌥⌘I) lists them. Empty states are hints that name the menu command and shortcut (drop a video; Transcribe Audio ⌃⌘R or Import Subtitles ⇧⌘O), not buttons. Row hover actions and the actions bar stay the only in-window copies of menu commands.
- **Rows.** Start and end fields show their box only on the hovered or selected row or while typing. Default/Top is one icon button (tinted when the cue is at the top), and a top cue shows a small ⤒ beside its reading speed. For a right-to-left track outside translation mode the row mirrors: number and times on the right. Timecodes always read left to right.
- **Menus.** File, Edit, View (Show Issues, milliseconds, zoom, snapping, speech highlight; the Timeline menu is gone), Cue, Review, Translation, AI, Playback (transport, stepping, Go to Start/End ⌘←/⌘→, shot changes, audio track). New shortcuts: Transcribe Audio ⌃⌘R (M10 removed Detect Speakers and Addressees ⌃⌘S). J and L are "Shuttle Backward/Forward".
- **Settings › AI.** API keys save on Return or when leaving the field, with a check once the Keychain has them; key fields are dimmed while cloud providers are off, and a warning says when a chosen cloud provider can't run yet.
- **Dark everywhere.** `NSApp.appearance` is dark, so Settings, the glossary, sheets and alerts match the editor.
- **Dash dialogue.** A cue whose lines all start with a dash (`SubtitleText.isDialogue`) shows on the video as one block aligned to the text's start (left, or right for Arabic and Hebrew), centred as a whole, so the dashes line up.

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

Every AI job returns a `ProposedChangeSet` (new cues, text edits, timing edits). Jobs that only fill (transcription, translation) are applied as they arrive, one undoable edit per batch, with AI text marked until edited; jobs that rewrite existing text (cleanup) are reviewed as a diff and accepted per cue or all at once. See "As built in M6".

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
| Gender and number in the translation | n/a | Claude flags lines that read more than one way and writes every variant (M10) |

Design notes:
- **Transcript → cues segmentation** is our own code, not the model's: word timestamps are grouped into cues using the QC rules (max CPL, max duration, min gap, snap to shot changes), so output is deliverable-ready.
- **Translation uses context**, not cue-by-cue strings: a sliding window of neighbouring cues, the glossary, character names and target QC limits go to the provider; results map back by cue ID.
- **Jobs** run in a background `JobRunner` with progress, cancel and resume; long media is chunked on silence boundaries.
- **Keys and privacy:** API keys in the Keychain; a per-project setting says whether media or text may leave the machine. Local providers work fully offline.
- **Same tools for agents:** each AI feature is also an `EditorCommand`, so it appears in menus, Shortcuts and the MCP bridge.

## 7b. Gender and number in translations (M10)

Some target languages (Arabic first; also Hebrew, French, Spanish, etc.) change the sentence depending on who speaks and who is spoken to: "You are busy" is انتَ مشغول / انتِ مشغولة / انتما مشغولان / انتم مشغولون / انتن مشغولات. M6 guessed each speaker's gender from pitch and tagged every line's addressee; Saeed found it too much and not helpful (2026-09-29), so M10 replaced it with flags written by the translator. Nobody tags lines or enters names by hand.

- **Flags** (`Cue.flag`, `TranslationFlag`): while translating into a gendered language, Claude flags every line whose wording depends on something the source leaves open: the listener's gender or number ("you"), gendered verbs, adjectives or pronouns, or an unclear speaker. For each it writes every valid variant (`TranslationVariant`: text, speaker and listeners by name, their gender, how many listen), recommends one from the scene, says how sure it is, and gives a one-line reason ("Beth is talking to Morty"). The recommendation goes straight into the cue, tinted like any AI text, one undo step per batch. Apple's on-device translator has no scene context and flags nothing.
- **Context** Claude gets: the lines before, the transcriber's voice labels (`Cue.voices`, from ElevenLabs Scribe's diarization; for imported subtitles, from the transcript words the project keeps), the ASS speaker name, and the cast known so far. Voice labels are a hint only: Scribe sometimes splits one person over several labels and merges two into one.
- **Cast** (`SubtitleTrack.cast`, `CastMember`: name, gender, voices, confirmed): built by the translator from the dialogue, batch by batch, and sent back with later batches. Picking a variant confirms what it assumes (the speaker's gender, a single listener's), and confirmed people are facts the translator must not contradict.
- **Review.** The actions bar shows "N lines to choose"; clicking it, or AI › Review Translation Choices (⌃⌘V), filters the cue list to the open flags, least confident first. Each flagged row lists its variants under the text, who each assumes ("Beth ♀ to Morty ♂") and the reason with the confidence; one click uses a variant (one undoable edit) and selects the next. AI › Accept Remaining Choices keeps the recommendations and ends the review. Typing in a flagged cue settles it too. A settled line keeps its variants in a row hover menu.
- **Picks carry forward.** A pick about a person re-ranks that person's other open lines in the same undo step: variants that contradict the confirmed cast go last, the text switches when the recommendation no longer fits, and a line left with one fitting variant is settled. Batches still arriving are re-ranked the same way.
- **Saved** in the project with the cues and track (`subtitles.json`); projects from before M10 open without flags or cast.
- **Scribe options (M10).** Audio events are tagged ("(laughter)", "(music)") for hearing-impaired subtitles; `enable_logging=false` asks for zero retention (ElevenLabs allows it for enterprise accounts only, so a refusal falls back to a normal request); each word's log probability is kept, and words under 50% make the cue a "Check the transcription" QC warning until its text is edited. Translate with AI warns when cues still have words to check, offering Review Cues or Translate Anyway. The speaker count is left unset: Claude works out who is who from names and context.
- **Missing lines.** When Claude leaves lines out of a batch or declines it, the missing lines are asked for again in halves, down to single lines; lines that never come back are reported and stay "Not translated".
- **Benchmark.** `spotline-bench` sends the Scribe voices it has cached, notes how many lines were flagged, and scores "Addressee form agreement" (whether the chosen Arabic "you" matches the reference's).

## 7c. Subtitle quality (M11)

Saeed compared Spotline's Arabic for two episodes of A Knight of the Seven Kingdoms with professional subtitles (2026-09-30). Timing matched within two frames; the gaps were segmentation, clutter, drifting names, misheard lines translated smoothly, and a few "you" forms. M11 answers each:

- **Joining lines** (`CueJoiner`, AITools). Translating cue by cue keeps the source's breaks, which fall mid-phrase in Arabic, and leaves many short cues (the reference had a third fewer cues and four times as many two-line ones). After a translation, the lines it wrote that nobody has edited are joined in one undoable edit (a setting, on by default): a sentence split over two cues becomes one two-line cue, a short line joins its neighbour, a quick exchange becomes a dialogue cue; always within the preset (two lines, line length, 7 s, reading speed, a pause of at most 0.75 s). Two sentences go on separate lines where lines end without a full stop. A joined cue translates several source cues (`Cue.joinedSourceCueIDs`); its source reads as their lines together. Review › Join Short Lines proposes the same for any track, as a reviewed diff. Line breaks never leave an article, preposition or conjunction at the end of the top line.
- **Transcript cleanup** (`TranscriptCleanup`). Hesitations (um, uh) and stutters ("I, I", "D- Dunk", "w-what", but not "No, no") are dropped, cues that are only an interjection ("Oh.", "Hmm.") are left out, words stretched over music are shortened, and short cues stay up 1.2 s when the next cue leaves room.
- **The translator's context.** Claude gets the whole episode's source as cached context (sent at full price once per episode), the episode's title from the video's file name (release tags removed), the user's notes for the translator (glossary panel, saved with the track), 20 translated lines before, and the transcriber's unsure words marked "[word?]".
- **Rules.** Never soften or change the meaning of violent, sexual or profane lines ("Stop raping" became "stop joking" in the review); a Faithful or Broadcast register setting. A line that reads as misheard (ungrammatical, or not fitting the scene) is flagged with the reason `source`, with variants for the likely line and the line as heard (`TranslationVariant.assumedSource`), in any target language; the choice review shows them as "If the line is “It's an elm.”". Names spelled one way and transliterated, never translated. A listener's gender kept through a scene, singular for one listener, the dual for two. House style for Arabic: no full stop at line ends (a setting, also applied after translating), no hesitations, one stutter at most, quotes for songs, imitations and quoted speech, names optionally in parentheses. A " / " the model copied for a line break (from how lines were once sent) becomes a break.
- **Names.** The cast records how the translation spells each name (`CastMember.translatedName`), sent with later batches; `NameEnforcer` puts the agreed spelling back where a line drifts by a letter or two ("دنك" → "دانك"). Translation › Add Names to Glossary carries the spellings to the next episode.
- **Words to check.** Unsure words (Scribe confidence under 50%) are no longer QC warnings. They keep their time and confidence (`UnsureWord`), show under the cue with Play (the word with 0.3 s either side, then pause) and Confirm, and have their own review like translation choices: "N words to check" in the actions bar, AI › Review Words to Check (⌃⌘W, least sure first) and Confirm Remaining Words. Editing a cue clears only the words edited out. Translate with AI's warning opens this review; in translation mode the source can't be edited, so the words go to the translator instead. Projects transcribed before M10 have no confidences: transcribing again reuses the saved transcript, so AI › Clear Transcript… first gets them.

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
| M8 | UI revision | One look across every milestone: AI tint, fewer duplicate buttons, menus, Settings, dark everywhere, RTL rows, dialogue |
| M9 | Project files | `.spotline` documents with autosave, versions and window restoration; cached analysis and AI results; relinking a moved video |
| M10 | Translation flags | Lines that read more than one way flagged with variants and a reason; filtered review, one-click picks that carry forward; old speaker/addressee detection removed |
| M11 | Subtitle quality | From comparing Spotline's Arabic for two episodes with professional subtitles: lines joined after translating, transcript cleanup, a richer translator prompt with house style, consistent names, and a review for words the transcription was unsure of |

## 10. Decisions so far

- Name: Spotline, repo SaeedKhader/spotline.
- New repository, open source, licensed GPL-3.0 with a stock GPL libmpv (Saeed, 2026-09-28).
- "UI tools ready" = AI and UI automation ready, plus AI subtitle tools (Saeed, 2026-09-28).
- Gender/addressee context for Arabic and similar languages: AI infers speaker and addressee, flags low-confidence lines with variants, user only fixes those (Saeed, 2026-09-28). Replaced by translation flags: the translator flags every line that reads more than one way, applies its pick with a reason, and the user reviews only those; no pitch-based guessing or per-line tags (Saeed, 2026-09-29). See 7b.
- AI results that only fill (transcription, translation) go straight into the cue list without review; cleanup that rewrites text stays a reviewed diff (Saeed, 2026-09-29).

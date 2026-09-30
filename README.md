# Spotline

A native macOS subtitle editor for professional movie and TV workflows: timing ("spotting"), translation and delivery.

- Frame-accurate playback of pro formats through [libmpv](https://mpv.io), hosted via AppKit inside SwiftUI
- Exact timecode math: 23.976, 25, 29.97 drop-frame and more, with no floating-point drift
- Built for automation from day one: stable accessibility IDs, one command layer shared by menus, shortcuts, UI tests and AI agents
- An MCP server for AI agents such as Claude Code (off by default; see [docs/AGENTS.md](docs/AGENTS.md))
- AI tools (planned): transcription with timestamps, translation, profanity removal and line shortening, always reviewed as a diff before applying

Status: early development (milestone M4, pro formats and QC). See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the design and roadmap.

## Requirements

- macOS 26 or later
- Xcode 26 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) and libmpv: `brew install xcodegen mpv`

## Build

```sh
xcodegen generate      # creates Spotline.xcodeproj from project.yml
open Spotline.xcodeproj
```

Local builds are signed ad hoc, so the Keychain asks again for the AI API keys after every rebuild. To sign them with your Apple Development certificate instead, run `scripts/setup-local-signing.sh` once, then `xcodegen generate`; allow Keychain access once more and it sticks. `scripts/bench.sh <samples>` builds, signs and runs `spotline-bench` the same way.

Run the package unit tests without Xcode's UI:

```sh
swift test --package-path Packages/SpotlineKit
```

Open a file with File > Open Media… (Command-O) or by dropping it on the video. `-OpenMedia <path>` opens one at launch.

Import SRT, WebVTT, ASS/SSA or TTML (IMSC, DFXP) subtitles with File > Import Subtitles… (Shift-Command-O) or `-OpenSubtitles <path>` at launch, and export with File > Export Subtitles… (Shift-Command-E). In the Cue menu: Add Cue at Playhead (Shift-Command-N), Set In/Out at Playhead (I / O), Delete Cue (Command-Delete), previous/next cue (Command-Up/Down).

The Review menu checks every cue live against a QC preset (Netflix adult or children, Broadcast or Basic): reading speed, line length and count, duration, gaps and distance from shot changes. The scope bar over the cue list counts them, and Review › Review Issues (Option-Command-I) shows only those cues with their issues; Option-Command-Up/Down step through them, and Fix Overlaps and Short Gaps trims cues that run too close.

The timeline shows the waveform, shot changes (found automatically when media opens) and cue blocks: drag a block to move it, drag its edges to trim, with snapping to shot changes, the playhead and other cues. Option-Left/Right jump between shot changes; Command-= and Command-- zoom. Choose the audio track in Playback › Audio Track (Option-Command-A cycles); the waveform shows the center (dialogue) channel of surround tracks. The waveform is filtered to the voice band, and speech (detected on-device) is highlighted while music and effects are dimmed.

Run the UI tests:

```sh
xcodebuild test -project Spotline.xcodeproj -scheme Spotline -destination 'platform=macOS'
```

## Layout

| Path | What |
|---|---|
| `App/` | App entry point, scenes and menus |
| `AppUITests/` | XCUITest suite, launched with `-UITestMode` |
| `Packages/SpotlineKit/Sources/SubtitleCore` | Time, frame rates, SMPTE timecode, cues. No UI. |
| `Packages/SpotlineKit/Sources/SubtitleFormats` | SRT, WebVTT, ASS/SSA and TTML/IMSC import/export, with golden-file tests |
| `Packages/SpotlineKit/Sources/QualityControl` | QC rules and client presets |
| `Packages/SpotlineKit/Sources/MediaAnalysis` | Waveform peaks and shot changes via FFmpeg, cached |
| `Packages/SpotlineKit/Sources/EditorCommands` | Every user action as a named command |
| `Packages/SpotlineKit/Sources/SpotlineAccessibility` | Accessibility identifier catalog |
| `Packages/SpotlineKit/Sources/PlaybackCore` | The playback engine interface, plus a simulated engine for tests |
| `Packages/SpotlineKit/Sources/MPVPlayer` | libmpv player, OpenGL render layer and video view |
| `Packages/SpotlineKit/Sources/AgentBridge` | MCP tools and the local socket agents reach the app through |
| `Packages/SpotlineKit/Sources/SpotlineMCP` | `spotline-mcp`, the stdio helper agents launch (bundled in the app) |
| `Packages/SpotlineKit/Sources/EditorUI` | Editor views and state |
| `Fixtures/` | Short test clips and subtitles used by the player and UI tests |

## License

Spotline is free software under the [GNU General Public License v3.0 or later](LICENSE). It links libmpv, which is GPL in its default build.

# Spotline

Native macOS subtitle editor (SwiftUI + AppKit, libmpv playback). Design and roadmap: `docs/ARCHITECTURE.md`.

## Build and test

- Requires `brew install xcodegen mpv`. SpotlineKit links Homebrew's libmpv (`Sources/CMPV`) and the FFmpeg libraries mpv depends on (`Sources/CFFmpeg`) through pkg-config.
- `swift test --package-path Packages/SpotlineKit` runs the unit tests (Swift Testing).
- `xcodegen generate` creates `Spotline.xcodeproj` from `project.yml`. Never commit the `.xcodeproj`; change `project.yml` instead.
- UI tests: `xcodebuild test -project Spotline.xcodeproj -scheme Spotline -destination 'platform=macOS'`.
- CI (`.github/workflows/ci.yml`) runs both on `macos-26`.

## Rules

- **Time is rational.** Use `MediaTime` and `Timecode` from `SubtitleCore`. Never store or compare editing times as `Double` seconds; convert only at the edges (mpv, file parsers).
- **Every user action is an `EditorCommand`.** Add the command to `EditorCommand.all`, execute it in `EditorState.perform`, and let menus and buttons call it. No logic in button closures.
- **Every interactive or custom-drawn view gets an ID from `AccessibilityID`.** No string literals for identifiers. Containers use `.accessibilityElement(children: .contain)` before `.accessibilityIdentifier`, or the ID overwrites the children's.
- **AI fills, the user decides on rewrites.** Transcription, translation and speaker/addressee detection only fill empty cues, gaps and tags, so they go straight into the track as they arrive (one undoable edit per batch; AI text is tinted until edited; they never overwrite what the user typed meanwhile). Tools that rewrite existing text (cleanup) return proposed changes shown as a diff to accept or reject; each acceptance is one undoable edit. (Saeed, 2026-09-29.)
- `SubtitleCore` must not import SwiftUI, AppKit or mpv.
- The editor talks to playback only through `PlaybackEngine` (`PlaybackCore`). `MPVPlayer` is the real engine; unit tests use `SimulatedPlaybackEngine`. Playback state comes from the engine's status updates, never from what a command asked for.
- mpv seeks are exact and aim a quarter frame before the target frame's start (mpv shows the first frame at or after the target, and containers round timestamps). Read frames with `MediaTime.nearestFrame(at:)`.
- Swift 6 language mode with strict concurrency. UI state is `@MainActor`.
- License is GPL-3.0-or-later. Only add dependencies with GPL-compatible licenses.

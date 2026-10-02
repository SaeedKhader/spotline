# Spotline

Native macOS subtitle editor (SwiftUI + AppKit, libmpv playback). Design and roadmap: `docs/ARCHITECTURE.md`.

## Build and test

- Requires `brew install xcodegen mpv`. SpotlineKit links Homebrew's libmpv (`Sources/CMPV`) and the FFmpeg libraries mpv depends on (`Sources/CFFmpeg`) through pkg-config.
- `swift test --package-path Packages/SpotlineKit` runs the unit tests (Swift Testing).
- `xcodegen generate` creates `Spotline.xcodeproj` from `project.yml`. Never commit the `.xcodeproj`; change `project.yml` instead.
- UI tests: `xcodebuild test -project Spotline.xcodeproj -scheme Spotline -destination 'platform=macOS'`.
- CI (`.github/workflows/ci.yml`) runs both on `macos-26`.
- `scripts/perf.sh <project.spotline> [label]` measures the built app on a copy of a project (opening, playback, selecting, typing, review, scrolling: main-thread work and the longest stall of each) and prints a table; run it before and after a change that could slow the editor. It opens a silent Spotline window for about a minute, changes nothing of the project and calls no AI provider.

## Rules

- **Time is rational.** Use `MediaTime` and `Timecode` from `SubtitleCore`. Never store or compare editing times as `Double` seconds; convert only at the edges (mpv, file parsers).
- **Every user action is an `EditorCommand`.** Add the command to `EditorCommand.all`, execute it in `EditorState.perform`, and let menus and buttons call it. No logic in button closures.
- **Every interactive or custom-drawn view gets an ID from `AccessibilityID`.** No string literals for identifiers. Containers use `.accessibilityElement(children: .contain)` before `.accessibilityIdentifier`, or the ID overwrites the children's.
- **AI fills, the user decides on rewrites.** Transcription and translation only fill empty cues and gaps, so they go straight into the track as they arrive (one undoable edit per batch; AI text is tinted until edited; they never overwrite what the user typed meanwhile). Tools that rewrite existing text (cleanup) return proposed changes shown as a diff to accept or reject; each acceptance is one undoable edit. (Saeed, 2026-09-29.) Lines a translation could word more than one way are flagged with their variants; one click swaps a variant in (docs/ARCHITECTURE.md, 7b).
- **Agents use the same path.** MCP tools (`AgentBridge/AgentTool.swift`, run in `EditorState+Agent.swift`) call the same commands and `edit(_:_:)` as the UI, so each agent edit is one undo step. Agents never accept or reject AI proposals, and never open dialogs (they pass paths). Agent access is off by default (Settings › Agents); see `docs/AGENTS.md`.
- **Projects save everything that is not a view preference.** New state that belongs to the episode goes in `ProjectFile` (and `projectFile(savingTo:)` / `loadProject`), and changing it calls `projectDidChange` so the document autosaves. Undoable edits already do, through `edit(_:_:)`.
- `SubtitleCore` must not import SwiftUI, AppKit or mpv.
- The editor talks to playback only through `PlaybackEngine` (`PlaybackCore`). `MPVPlayer` is the real engine; unit tests use `SimulatedPlaybackEngine`. Playback state comes from the engine's status updates, never from what a command asked for.
- mpv seeks are exact and aim a quarter frame before the target frame's start (mpv shows the first frame at or after the target, and containers round timestamps). Read frames with `MediaTime.nearestFrame(at:)`.
- **Views redraw for their own data only.** A cue list row or review card is handed what it shows by its list (compared with `==`), and only the selected row has a text editor (the others show their text as a plain line); what views ask for on every redraw (review lists, a cue by ID, each cue's checks) is kept in `EditorState` until the cues, issues or proposed changes change (`reviewDerived`, `index(ofCue:)`, `updateIssues(keepingChecks:)`). Work that walks every cue does not belong in a view's `body`, or in anything run per keystroke, selection or video frame. `KeptResultsTests` checks that what is kept equals working it out afresh. The timeline draws its picture in tiles once and slides them as the media plays (`TimelineTile`): nothing there may draw per video frame either.
- Swift 6 language mode with strict concurrency. UI state is `@MainActor`.
- License is GPL-3.0-or-later. Only add dependencies with GPL-compatible licenses.

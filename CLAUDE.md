# Spotline

Native macOS subtitle editor (SwiftUI + AppKit, libmpv playback). Design and roadmap: `docs/ARCHITECTURE.md`.

## Build and test

- `swift test --package-path Packages/SpotlineKit` runs the unit tests (Swift Testing).
- `xcodegen generate` creates `Spotline.xcodeproj` from `project.yml`. Never commit the `.xcodeproj`; change `project.yml` instead.
- UI tests: `xcodebuild test -project Spotline.xcodeproj -scheme Spotline -destination 'platform=macOS'`.
- CI (`.github/workflows/ci.yml`) runs both on `macos-15`.

## Rules

- **Time is rational.** Use `MediaTime` and `Timecode` from `SubtitleCore`. Never store or compare editing times as `Double` seconds; convert only at the edges (mpv, file parsers).
- **Every user action is an `EditorCommand`.** Add the command to `EditorCommand.all`, execute it in `EditorState.perform`, and let menus and buttons call it. No logic in button closures.
- **Every interactive or custom-drawn view gets an ID from `AccessibilityID`.** No string literals for identifiers. Containers use `.accessibilityElement(children: .contain)` before `.accessibilityIdentifier`, or the ID overwrites the children's.
- **AI proposes, the user decides.** AI features return proposed changes shown as a diff; applying them is one undoable edit.
- `SubtitleCore` must not import SwiftUI, AppKit or mpv.
- Swift 6 language mode with strict concurrency. UI state is `@MainActor`.
- License is GPL-3.0-or-later. Only add dependencies with GPL-compatible licenses.

# Spotline

A native macOS subtitle editor for professional movie and TV workflows: timing ("spotting"), translation and delivery.

- Frame-accurate playback of pro formats through [libmpv](https://mpv.io), hosted via AppKit inside SwiftUI
- Exact timecode math: 23.976, 25, 29.97 drop-frame and more, with no floating-point drift
- Built for automation from day one: stable accessibility IDs, one command layer shared by menus, shortcuts, UI tests and AI agents
- AI tools (planned): transcription with timestamps, translation, profanity removal and line shortening, always reviewed as a diff before applying

Status: early development (milestone M0, scaffold). See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the design and roadmap.

## Requirements

- macOS 15 or later
- Xcode 16 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Build

```sh
xcodegen generate      # creates Spotline.xcodeproj from project.yml
open Spotline.xcodeproj
```

Run the package unit tests without Xcode's UI:

```sh
swift test --package-path Packages/SpotlineKit
```

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
| `Packages/SpotlineKit/Sources/EditorCommands` | Every user action as a named command |
| `Packages/SpotlineKit/Sources/SpotlineAccessibility` | Accessibility identifier catalog |
| `Packages/SpotlineKit/Sources/EditorUI` | Editor views and state |

## License

Spotline is free software under the [GNU General Public License v3.0 or later](LICENSE). It links libmpv, which is GPL in its default build.

// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SpotlineKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SubtitleCore", targets: ["SubtitleCore"]),
        .library(name: "SpotlineAccessibility", targets: ["SpotlineAccessibility"]),
        .library(name: "EditorCommands", targets: ["EditorCommands"]),
        .library(name: "PlaybackCore", targets: ["PlaybackCore"]),
        .library(name: "MPVPlayer", targets: ["MPVPlayer"]),
        .library(name: "EditorUI", targets: ["EditorUI"]),
    ],
    targets: [
        // Pure model: time, frame rates, timecode, cues. No AppKit, no mpv.
        .target(name: "SubtitleCore"),
        // Stable accessibility identifiers shared by the app and UI tests.
        .target(name: "SpotlineAccessibility"),
        // Every user action as a named command (menus, shortcuts, tests, agents).
        .target(name: "EditorCommands"),
        // The playback engine interface the editor drives, plus a simulated engine for tests.
        .target(name: "PlaybackCore", dependencies: ["SubtitleCore"]),
        // libmpv headers and link flags (Homebrew's mpv during development).
        .systemLibrary(name: "CMPV", pkgConfig: "mpv", providers: [.brew(["mpv"])]),
        // libmpv playback: player, OpenGL render layer and video view.
        .target(
            name: "MPVPlayer",
            dependencies: ["CMPV", "PlaybackCore", "SubtitleCore"],
            // OpenGL is deprecated but is libmpv's only macOS render API (docs/ARCHITECTURE.md, section 4).
            swiftSettings: [.unsafeFlags(["-Xcc", "-DGL_SILENCE_DEPRECATION"])]
        ),
        .target(
            name: "EditorUI",
            dependencies: ["SubtitleCore", "SpotlineAccessibility", "EditorCommands", "PlaybackCore", "MPVPlayer"]
        ),
        .testTarget(name: "SubtitleCoreTests", dependencies: ["SubtitleCore"]),
        .testTarget(name: "EditorCommandsTests", dependencies: ["EditorCommands"]),
        .testTarget(name: "PlaybackCoreTests", dependencies: ["PlaybackCore"]),
        .testTarget(name: "MPVPlayerTests", dependencies: ["MPVPlayer"]),
        .testTarget(name: "EditorStateTests", dependencies: ["EditorUI"]),
    ]
)

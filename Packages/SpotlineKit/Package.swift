// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpotlineKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SubtitleCore", targets: ["SubtitleCore"]),
        .library(name: "SpotlineAccessibility", targets: ["SpotlineAccessibility"]),
        .library(name: "EditorCommands", targets: ["EditorCommands"]),
        .library(name: "EditorUI", targets: ["EditorUI"]),
    ],
    targets: [
        // Pure model: time, frame rates, timecode, cues. No AppKit, no mpv.
        .target(name: "SubtitleCore"),
        // Stable accessibility identifiers shared by the app and UI tests.
        .target(name: "SpotlineAccessibility"),
        // Every user action as a named command (menus, shortcuts, tests, agents).
        .target(name: "EditorCommands"),
        .target(
            name: "EditorUI",
            dependencies: ["SubtitleCore", "SpotlineAccessibility", "EditorCommands"]
        ),
        .testTarget(name: "SubtitleCoreTests", dependencies: ["SubtitleCore"]),
        .testTarget(name: "EditorCommandsTests", dependencies: ["EditorCommands"]),
        .testTarget(name: "EditorStateTests", dependencies: ["EditorUI"]),
    ]
)

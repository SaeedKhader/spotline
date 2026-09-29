// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SpotlineKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SubtitleCore", targets: ["SubtitleCore"]),
        .library(name: "SubtitleFormats", targets: ["SubtitleFormats"]),
        .library(name: "QualityControl", targets: ["QualityControl"]),
        .library(name: "SubtitleTranslation", targets: ["SubtitleTranslation"]),
        .library(name: "AITools", targets: ["AITools"]),
        .library(name: "SpotlineAccessibility", targets: ["SpotlineAccessibility"]),
        .library(name: "EditorCommands", targets: ["EditorCommands"]),
        .library(name: "PlaybackCore", targets: ["PlaybackCore"]),
        .library(name: "MPVPlayer", targets: ["MPVPlayer"]),
        .library(name: "MediaAnalysis", targets: ["MediaAnalysis"]),
        .library(name: "EditorUI", targets: ["EditorUI"]),
    ],
    targets: [
        // Pure model: time, frame rates, timecode, cues. No AppKit, no mpv.
        .target(name: "SubtitleCore"),
        // Subtitle file formats (SRT, WebVTT, ASS/SSA, TTML/IMSC, EBU STL), read and written losslessly where the format allows.
        .target(name: "SubtitleFormats", dependencies: ["SubtitleCore"]),
        // QC rules and client presets (line length, reading speed, durations, gaps, shot changes).
        .target(name: "QualityControl", dependencies: ["SubtitleCore"]),
        // Translation workflow: source/target alignment, glossary, translation memory, text direction.
        // Not named "Translation": that would hide Apple's Translation framework, which AITools uses.
        .target(name: "SubtitleTranslation", dependencies: ["SubtitleCore"]),
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
        // FFmpeg headers and link flags (Homebrew's ffmpeg, a dependency of mpv).
        .systemLibrary(name: "CFFmpeg", pkgConfig: "libavformat", providers: [.brew(["ffmpeg"])]),
        // Waveform peaks and shot changes, read from media once and cached.
        .target(name: "MediaAnalysis", dependencies: ["CFFmpeg", "SubtitleCore"]),
        // AI tools: transcription, translation, cleanup and speaker/addressee detection, on-device
        // (Apple Speech, Translation, sound analysis) or cloud (OpenAI transcription, Claude), proposing reviewable changes.
        .target(name: "AITools", dependencies: ["SubtitleCore", "SubtitleTranslation", "MediaAnalysis", "QualityControl"]),
        .target(
            name: "EditorUI",
            dependencies: [
                "SubtitleCore", "SubtitleFormats", "SpotlineAccessibility", "EditorCommands", "PlaybackCore", "MPVPlayer",
                "MediaAnalysis", "QualityControl", "SubtitleTranslation", "AITools",
            ]
        ),
        .testTarget(name: "SubtitleCoreTests", dependencies: ["SubtitleCore"]),
        .testTarget(
            name: "SubtitleFormatsTests",
            dependencies: ["SubtitleFormats"],
            resources: [.copy("Golden"), .copy("Input")]
        ),
        .testTarget(name: "QualityControlTests", dependencies: ["QualityControl"]),
        .testTarget(name: "SubtitleTranslationTests", dependencies: ["SubtitleTranslation"]),
        .testTarget(name: "AIToolsTests", dependencies: ["AITools", "MediaAnalysis"]),
        .testTarget(name: "EditorCommandsTests", dependencies: ["EditorCommands"]),
        .testTarget(name: "PlaybackCoreTests", dependencies: ["PlaybackCore"]),
        .testTarget(name: "MPVPlayerTests", dependencies: ["MPVPlayer"]),
        .testTarget(name: "MediaAnalysisTests", dependencies: ["MediaAnalysis"]),
        .testTarget(name: "EditorStateTests", dependencies: ["EditorUI", "SubtitleFormats", "QualityControl", "SubtitleTranslation", "AITools"]),
    ]
)

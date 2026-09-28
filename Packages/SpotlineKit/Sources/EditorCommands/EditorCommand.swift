/// A named user action.
///
/// Menus, keyboard shortcuts, toolbar buttons, UI tests and AI agents all run
/// the same commands, so anything a person can do is scriptable by ID.
public struct EditorCommand: Identifiable, Hashable, Sendable {
    /// Stable dotted identifier, e.g. "playback.stepForward". Treat as public API.
    public let id: String
    public let title: String
    public let category: Category
    public let defaultShortcut: KeyShortcut?

    public enum Category: String, Sendable, CaseIterable {
        case file
        case playback
        /// Undo and redo.
        case editing
        /// Creating and changing cues.
        case cue
        case navigation
        /// Timeline zoom and snapping.
        case timeline
    }

    public init(id: String, title: String, category: Category, defaultShortcut: KeyShortcut? = nil) {
        self.id = id
        self.title = title
        self.category = category
        self.defaultShortcut = defaultShortcut
    }
}

extension EditorCommand {
    public static let openMedia = EditorCommand(
        id: "file.openMedia", title: "Open Media…", category: .file,
        defaultShortcut: KeyShortcut(.character("o"), modifiers: .command)
    )
    public static let importSubtitles = EditorCommand(
        id: "file.importSubtitles", title: "Import Subtitles…", category: .file,
        defaultShortcut: KeyShortcut(.character("o"), modifiers: [.command, .shift])
    )
    public static let exportSubtitles = EditorCommand(
        id: "file.exportSubtitles", title: "Export Subtitles…", category: .file,
        defaultShortcut: KeyShortcut(.character("e"), modifiers: [.command, .shift])
    )
    public static let undo = EditorCommand(
        id: "editing.undo", title: "Undo", category: .editing,
        defaultShortcut: KeyShortcut(.character("z"), modifiers: .command)
    )
    public static let redo = EditorCommand(
        id: "editing.redo", title: "Redo", category: .editing,
        defaultShortcut: KeyShortcut(.character("z"), modifiers: [.command, .shift])
    )
    public static let addCue = EditorCommand(
        id: "cue.addAtPlayhead", title: "Add Cue at Playhead", category: .cue,
        defaultShortcut: KeyShortcut(.character("n"), modifiers: [.command, .shift])
    )
    public static let deleteCue = EditorCommand(
        id: "cue.delete", title: "Delete Cue", category: .cue,
        defaultShortcut: KeyShortcut(.delete, modifiers: .command)
    )
    public static let setIn = EditorCommand(
        id: "cue.setInAtPlayhead", title: "Set In at Playhead", category: .cue,
        defaultShortcut: KeyShortcut(.character("i"))
    )
    public static let setOut = EditorCommand(
        id: "cue.setOutAtPlayhead", title: "Set Out at Playhead", category: .cue,
        defaultShortcut: KeyShortcut(.character("o"))
    )
    public static let previousCue = EditorCommand(
        id: "navigation.previousCue", title: "Select Previous Cue", category: .navigation,
        defaultShortcut: KeyShortcut(.upArrow, modifiers: .command)
    )
    public static let nextCue = EditorCommand(
        id: "navigation.nextCue", title: "Select Next Cue", category: .navigation,
        defaultShortcut: KeyShortcut(.downArrow, modifiers: .command)
    )
    public static let previousShotChange = EditorCommand(
        id: "navigation.previousShotChange", title: "Go to Previous Shot Change", category: .navigation,
        defaultShortcut: KeyShortcut(.leftArrow, modifiers: .option)
    )
    public static let nextShotChange = EditorCommand(
        id: "navigation.nextShotChange", title: "Go to Next Shot Change", category: .navigation,
        defaultShortcut: KeyShortcut(.rightArrow, modifiers: .option)
    )
    public static let zoomIn = EditorCommand(
        id: "timeline.zoomIn", title: "Zoom In", category: .timeline,
        defaultShortcut: KeyShortcut(.character("="), modifiers: .command)
    )
    public static let zoomOut = EditorCommand(
        id: "timeline.zoomOut", title: "Zoom Out", category: .timeline,
        defaultShortcut: KeyShortcut(.character("-"), modifiers: .command)
    )
    /// A toggle: see `EditorState.isOn(_:)`.
    public static let toggleSnapping = EditorCommand(
        id: "timeline.toggleSnapping", title: "Snap to Shot Changes and Cues", category: .timeline
    )
    public static let togglePlay = EditorCommand(
        id: "playback.togglePlay", title: "Play/Pause", category: .playback,
        defaultShortcut: KeyShortcut(.space)
    )
    public static let stepForward = EditorCommand(
        id: "playback.stepForward", title: "Step Forward One Frame", category: .playback,
        defaultShortcut: KeyShortcut(.rightArrow)
    )
    public static let stepBackward = EditorCommand(
        id: "playback.stepBackward", title: "Step Backward One Frame", category: .playback,
        defaultShortcut: KeyShortcut(.leftArrow)
    )
    public static let goToStart = EditorCommand(
        id: "playback.goToStart", title: "Go to Start", category: .playback,
        defaultShortcut: KeyShortcut(.leftArrow, modifiers: .command)
    )

    /// Every command the app knows, in menu order.
    public static let all: [EditorCommand] = [
        openMedia, importSubtitles, exportSubtitles,
        undo, redo,
        addCue, deleteCue, setIn, setOut,
        previousCue, nextCue, previousShotChange, nextShotChange,
        zoomIn, zoomOut, toggleSnapping,
        togglePlay, stepBackward, stepForward, goToStart,
    ]

    public static func named(_ id: String) -> EditorCommand? {
        all.first { $0.id == id }
    }
}

/// A UI-framework-neutral key binding.
public struct KeyShortcut: Hashable, Sendable {
    public enum Key: Hashable, Sendable {
        case character(Character)
        case space
        case leftArrow
        case rightArrow
        case upArrow
        case downArrow
        case returnKey
        case delete
        case escape
    }

    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
    }

    public let key: Key
    public let modifiers: Modifiers

    public init(_ key: Key, modifiers: Modifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    /// True when a text field uses this key for typing or moving the cursor
    /// (letters, Space, arrows, Delete, including with Command). Menus turn
    /// these shortcuts off while the user edits text, so typing "i" inserts
    /// an "i" instead of setting the in-point.
    public var conflictsWithTextEditing: Bool {
        switch key {
        case .leftArrow, .rightArrow, .upArrow, .downArrow, .delete: true
        case .character, .space, .returnKey, .escape: modifiers.isDisjoint(with: [.command, .control])
        }
    }
}

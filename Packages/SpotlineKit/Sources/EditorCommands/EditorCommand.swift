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
        case playback
        case editing
        case navigation
    }

    public init(id: String, title: String, category: Category, defaultShortcut: KeyShortcut? = nil) {
        self.id = id
        self.title = title
        self.category = category
        self.defaultShortcut = defaultShortcut
    }
}

extension EditorCommand {
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
    public static let all: [EditorCommand] = [togglePlay, stepBackward, stepForward, goToStart]

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
}

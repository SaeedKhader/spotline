import EditorCommands
import SwiftUI

/// Builds the app's command menus from `EditorCommand.all`.
public struct EditorMenuCommands: Commands {
    let editor: EditorState

    public init(editor: EditorState) {
        self.editor = editor
    }

    public var body: some Commands {
        CommandGroup(after: .newItem) {
            buttons(for: .file)
        }
        // The editor's undo stack also covers typing in the cue text editor,
        // so it replaces the text system's Undo and Redo.
        CommandGroup(replacing: .undoRedo) {
            buttons(for: .editing)
        }
        CommandMenu("Cue") {
            buttons(for: .cue)
            Divider()
            buttons(for: .navigation)
        }
        CommandMenu("Playback") {
            buttons(for: .playback)
        }
    }

    private func buttons(for category: EditorCommand.Category) -> some View {
        ForEach(EditorCommand.all.filter { $0.category == category }) { command in
            Button(command.title) { editor.perform(command) }
                .keyboardShortcut(command.defaultShortcut?.keyboardShortcut)
                .disabled(!editor.isShortcutEnabled(for: command))
        }
    }
}

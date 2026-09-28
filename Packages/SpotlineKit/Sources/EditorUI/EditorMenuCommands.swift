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
        CommandMenu("Playback") {
            buttons(for: .playback)
        }
    }

    private func buttons(for category: EditorCommand.Category) -> some View {
        ForEach(EditorCommand.all.filter { $0.category == category }) { command in
            Button(command.title) { editor.perform(command) }
                .keyboardShortcut(command.defaultShortcut?.keyboardShortcut)
                .disabled(!editor.canPerform(command))
        }
    }
}

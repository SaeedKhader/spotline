import EditorCommands
import SwiftUI

/// Builds the app's command menus from `EditorCommand.all`.
public struct EditorMenuCommands: Commands {
    let editor: EditorState

    public init(editor: EditorState) {
        self.editor = editor
    }

    public var body: some Commands {
        CommandMenu("Playback") {
            ForEach(EditorCommand.all.filter { $0.category == .playback }) { command in
                Button(command.title) { editor.perform(command) }
                    .keyboardShortcut(command.defaultShortcut?.keyboardShortcut)
                    .disabled(!editor.canPerform(command))
            }
        }
    }
}

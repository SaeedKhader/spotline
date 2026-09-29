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
        CommandGroup(after: .toolbar) {
            buttons(for: .view)
        }
        CommandMenu("Cue") {
            buttons(for: .cue)
            Divider()
            buttons(for: .navigation)
        }
        CommandMenu("Review") {
            buttons(for: .review)
            Divider()
            QCPresetPicker(editor: editor)
        }
        CommandMenu("Translation") {
            buttons(for: .translation)
            Divider()
            TargetLanguagePicker(editor: editor)
                .disabled(!editor.isTranslating)
        }
        CommandMenu("Timeline") {
            buttons(for: .timeline)
        }
        CommandMenu("Playback") {
            buttons(for: .playback)
            Divider()
            AudioTrackPicker(editor: editor)
                .disabled(editor.audioTracks.isEmpty)
        }
    }

    private func buttons(for category: EditorCommand.Category) -> some View {
        ForEach(EditorCommand.all.filter { $0.category == category }) { command in
            Group {
                if let isOn = editor.isOn(command) {
                    Toggle(command.title, isOn: Binding(get: { isOn }, set: { _ in editor.perform(command) }))
                } else {
                    Button(command.title) { editor.perform(command) }
                }
            }
            .keyboardShortcut(command.defaultShortcut?.keyboardShortcut)
            .disabled(!editor.isShortcutEnabled(for: command))
        }
    }
}

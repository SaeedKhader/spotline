import EditorUI
import SwiftUI

@main
struct SpotlineApp: App {
    @State private var editor = EditorState()

    var body: some Scene {
        Window("Spotline", id: "main") {
            MainWindowView(editor: editor)
        }
        .commands {
            EditorMenuCommands(editor: editor)
        }
    }
}

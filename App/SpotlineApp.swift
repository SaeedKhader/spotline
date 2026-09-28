import EditorUI
import SwiftUI

@main
struct SpotlineApp: App {
    @State private var editor = EditorState()

    var body: some Scene {
        // A WindowGroup, not a single Window scene: on CI runners the single
        // Window scene never opened at launch. Documents replace this in M2.
        WindowGroup("Spotline", id: "main") {
            MainWindowView(editor: editor)
        }
        .defaultSize(width: 1000, height: 700)
        .commands {
            EditorMenuCommands(editor: editor)
        }
    }
}

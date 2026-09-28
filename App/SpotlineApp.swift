import EditorUI
import SwiftUI

@main
struct SpotlineApp: App {
    @State private var editor = EditorState()

    var body: some Scene {
        // WindowGroup gives File > New Window, which UI tests use on CI runners
        // where no window opens at launch. Document windows replace this in M2.
        WindowGroup("Spotline", id: "main") {
            MainWindowView(editor: editor)
        }
        .defaultSize(width: 1000, height: 700)
        .commands {
            EditorMenuCommands(editor: editor)
        }
    }
}

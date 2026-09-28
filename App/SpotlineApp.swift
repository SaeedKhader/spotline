import EditorUI
import SwiftUI

@main
struct SpotlineApp: App {
    @State private var editor = EditorState()

    var body: some Scene {
        Window("Spotline", id: "main") {
            MainWindowView(editor: editor)
        }
        .defaultSize(width: 1000, height: 700)
        // Without this, SwiftUI waits for the system's "open application" event before
        // showing the window, which never comes (or comes late) when the app is started
        // by UI tests, scripts or login items: the app ran with menus but no window.
        .defaultLaunchBehavior(.presented)
        .commands {
            EditorMenuCommands(editor: editor)
        }
    }
}

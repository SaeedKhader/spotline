import EditorUI
import SwiftUI

@main
struct SpotlineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The editor window is owned by AppKit (see AppDelegate); SwiftUI supplies
        // the menus and the Settings window.
        Settings {
            Text("No settings yet.")
                .padding()
        }
        .commands {
            EditorMenuCommands(editor: appDelegate.editor)
        }
    }
}

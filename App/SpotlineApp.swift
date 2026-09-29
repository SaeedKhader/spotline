import EditorUI
import SwiftUI

@main
struct SpotlineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Project windows are AppKit documents (see AppDelegate); SwiftUI supplies
        // the menus and the Settings window.
        Settings {
            SettingsView(editor: appDelegate.workspace.idleEditor, agentAccess: appDelegate.agentAccess)
        }
        .commands {
            EditorMenuCommands(workspace: appDelegate.workspace)
        }
    }
}

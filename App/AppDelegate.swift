import AppKit
import EditorUI

/// Project windows are documents (`SpotlineDocument`, `.spotline` packages):
/// AppKit restores them on relaunch and opens an untitled one when there is
/// none. Files given at launch (`-OpenMedia`, `-OpenProject`…) open in a window
/// made here, since the system's "open application" event arrives late or not
/// at all when UI tests, scripts or login items start the app.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let workspace = EditorWorkspace.shared
    /// Settings › Agents: the local MCP bridge, off unless the user turned it on.
    lazy var agentAccess = AgentAccess(workspace: workspace)

    func applicationWillFinishLaunching(_ notification: Notification) {
        // A dark workspace, as in pro video tools, so the picture stands out:
        // the editor, Settings, the glossary, sheets and alerts alike.
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = agentAccess
        if workspace.openLaunchProject() { return }
        // Without the "open application" event, nothing would open a window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [workspace] in
            MainActor.assumeIsolated {
                if NSDocumentController.shared.documents.isEmpty, NSApp.windows.allSatisfy({ !$0.isVisible }) {
                    workspace.newProject()
                }
            }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        // UI tests and launch files get their window from `openLaunchProject`.
        !workspace.launchOptions.isUITestMode && NSDocumentController.shared.documents.isEmpty
    }

    func applicationWillTerminate(_ notification: Notification) {
        agentAccess.stop()
    }
}

import AppKit
import EditorCommands
import EditorUI
import Observation
import SwiftUI

/// Opens the editor window itself instead of relying on SwiftUI's launch-time
/// window creation, which waits for the system's "open application" event. That
/// event arrives late or not at all when the app is started by UI tests, scripts
/// or login items, which left the app running with menus and no window.
/// Document windows (NSDocument, per docs/ARCHITECTURE.md) replace this once
/// Spotline has its own project files; until then subtitles are imported and exported.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let editor = EditorState()
    /// Settings › Agents: the local MCP bridge, off unless the user turned it on.
    lazy var agentAccess = AgentAccess(editor: editor)
    private var mainWindowController: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        showMainWindow()
        _ = agentAccess
    }

    func applicationWillTerminate(_ notification: Notification) {
        agentAccess.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard editor.hasUnsavedChanges, !editor.launchOptions.isUITestMode else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Export your subtitle changes before quitting?"
        alert.informativeText = "Spotline doesn't save projects yet. Changes that aren't exported will be lost."
        alert.addButton(withTitle: "Export…")
        alert.addButton(withTitle: "Quit Without Exporting")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            editor.perform(.exportSubtitles)
            return editor.hasUnsavedChanges ? .terminateCancel : .terminateNow
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    private func showMainWindow() {
        if mainWindowController == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: MainWindowView(editor: editor)))
            window.identifier = NSUserInterfaceItemIdentifier("main")
            window.title = "Spotline"
            window.setContentSize(NSSize(width: 1280, height: 820))
            // A dark workspace, as in pro video tools, so the picture stands out.
            window.appearance = NSAppearance(named: .darkAqua)
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("MainWindow")
            mainWindowController = NSWindowController(window: window)
            updateWindowTitle(window)
        }
        mainWindowController?.showWindow(nil)
        NSApp.activate()
    }

    /// Shows the subtitle file's name and an edited dot, following the editor's state.
    private func updateWindowTitle(_ window: NSWindow) {
        withObservationTracking {
            window.title = editor.subtitleFile?.url.lastPathComponent ?? "Spotline"
            window.representedURL = editor.subtitleFile?.url
            window.isDocumentEdited = editor.hasUnsavedChanges
            window.subtitle = editor.sourceFile.map { "Translating from \($0.url.lastPathComponent)" } ?? ""
        } onChange: { [weak self, weak window] in
            Task { @MainActor in
                guard let self, let window else { return }
                self.updateWindowTitle(window)
            }
        }
    }
}

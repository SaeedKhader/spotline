import AppKit
import EditorUI
import SwiftUI

/// Opens the editor window itself instead of relying on SwiftUI's launch-time
/// window creation, which waits for the system's "open application" event. That
/// event arrives late or not at all when the app is started by UI tests, scripts
/// or login items, which left the app running with menus and no window.
/// Document windows (NSDocument, per docs/ARCHITECTURE.md) replace this in M2.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let editor = EditorState()
    private var mainWindowController: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        showMainWindow()
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
            window.setContentSize(NSSize(width: 1000, height: 700))
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("MainWindow")
            mainWindowController = NSWindowController(window: window)
        }
        mainWindowController?.showWindow(nil)
        NSApp.activate()
    }
}

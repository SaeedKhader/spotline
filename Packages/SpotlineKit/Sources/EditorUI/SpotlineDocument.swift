import AppKit
import EditorCommands
import Observation
import SwiftUI

/// A Spotline project window's document (a `.spotline` package, see `ProjectFile`).
///
/// AppKit gives projects the standard Mac behaviour: they save themselves as
/// you work (autosave in place), File › Revert To shows earlier versions, and
/// windows come back on relaunch. The editor keeps its own undo stack, and tells
/// the document about each change through `EditorState.projectDidChange`.
@objc(SpotlineDocument)
public final class SpotlineDocument: NSDocument, ProjectActions {
    public let editor: EditorState
    private let workspace: EditorWorkspace
    private let encodingCache = ProjectFile.EncodingCache()
    /// Where a save is writing, so the video's path from the project is right after Save As.
    private var destinationURL: URL?

    override public init() {
        workspace = EditorWorkspace.shared
        editor = workspace.makeEditor()
        super.init()
        hasUndoManager = false
        editor.projectActions = self
        editor.projectDidChange = { [weak self] change in self?.editorDidChange(change) }
        editor.aiToolWillStart = { [weak self] in self?.saveNextToVideoIfUntitled() }
    }

    override public class var autosavesInPlace: Bool { true }

    override public var fileURL: URL? {
        // AppKit sets it on the main thread (the document reads and writes there).
        didSet { MainActor.assumeIsolated { editor.projectURL = fileURL } }
    }

    /// An untitled project is named after its video.
    override public var displayName: String! {
        get {
            if fileURL == nil, let media = editor.status.mediaURL { return media.deletingPathExtension().lastPathComponent }
            return super.displayName
        }
        set { super.displayName = newValue }
    }

    // MARK: Window

    override public func makeWindowControllers() {
        let window = NSWindow(contentViewController: NSHostingController(rootView: MainWindowView(editor: editor)))
        window.identifier = NSUserInterfaceItemIdentifier("main")
        window.setContentSize(NSSize(width: 1280, height: 820))
        window.center()
        let controller = NSWindowController(window: window)
        controller.windowFrameAutosaveName = "MainWindow"
        addWindowController(controller)
        followEditor(in: window)
    }

    /// Keeps the title (named after the video while untitled) and the
    /// "Translating from…" subtitle in step with the editor.
    private func followEditor(in window: NSWindow) {
        withObservationTracking {
            _ = editor.status.mediaURL
            window.subtitle = editor.sourceFile.map { "Translating from \($0.url.lastPathComponent)" } ?? ""
        } onChange: { [weak self, weak window] in
            Task { @MainActor in
                guard let self, let window else { return }
                self.windowControllers.forEach { $0.synchronizeWindowTitleWithDocumentName() }
                self.followEditor(in: window)
            }
        }
    }

    override public func close() {
        editor.close()
        super.close()
        workspace.documentDidClose(self)
    }

    // MARK: Reading and writing

    override public func read(from fileWrapper: FileWrapper, ofType typeName: String) throws {
        let project = try ProjectFile(fileWrapper: fileWrapper)
        // Projects are read on the main thread: `canConcurrentlyReadDocuments` is false.
        MainActor.assumeIsolated { editor.loadProject(project, from: fileURL) }
    }

    override public func fileWrapper(ofType typeName: String) throws -> FileWrapper {
        try editor.projectFile(savingTo: destinationURL ?? fileURL).fileWrapper(cache: encodingCache)
    }

    override public func save(
        to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        if saveOperation != .autosaveElsewhereOperation { destinationURL = url }
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            MainActor.assumeIsolated { self?.destinationURL = nil }
            completionHandler(error)
        }
    }

    /// A new project is suggested next to its video.
    override public func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        if fileURL == nil, let media = editor.status.mediaURL {
            savePanel.directoryURL = media.deletingLastPathComponent()
        }
        return true
    }

    private func editorDidChange(_ change: ProjectChange) {
        switch change {
        case .edit, .other: updateChangeCount(.changeDone)
        case .undo: updateChangeCount(.changeUndone)
        case .redo: updateChangeCount(.changeRedone)
        }
    }

    /// The first AI tool run on an untitled project saves it next to its video,
    /// without asking, so what the tool returns (and what it cost) is never lost.
    private func saveNextToVideoIfUntitled() {
        guard fileURL == nil, !editor.launchOptions.isUITestMode, let media = editor.status.mediaURL else { return }
        let url = ProjectFile.suggestedURL(forMedia: media)
        guard FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path) else { return }
        // A failure leaves the project untitled; macOS still keeps it until it is saved.
        save(to: url, ofType: fileType ?? ProjectFile.typeIdentifier, for: .saveAsOperation) { _ in }
    }

    // MARK: ProjectActions

    public func canPerform(_ command: EditorCommand, projectURL: URL?) -> Bool {
        switch command.id {
        case EditorCommand.revertProject.id, EditorCommand.browseProjectVersions.id:
            projectURL != nil
        default:
            true
        }
    }

    public func perform(_ command: EditorCommand) -> Bool {
        switch command.id {
        case EditorCommand.newProject.id, EditorCommand.openProject.id:
            return workspace.perform(command)
        case EditorCommand.saveProject.id:
            save(nil)
        case EditorCommand.duplicateProject.id:
            duplicate(nil)
        case EditorCommand.revertProject.id:
            revertToSaved(nil)
        case EditorCommand.browseProjectVersions.id:
            browseVersions(nil)
        default:
            return false
        }
        return true
    }
}

/// Opens projects as documents and anything else (a video from the Finder or
/// Dock) as the video of a new project. AppKit also passes the values of launch
/// flags (`-OpenMedia <path>`, `-ApplePersistenceIgnoreState YES`) as files to
/// open; `EditorWorkspace.openLaunchProject` has opened the real ones already,
/// so they are skipped rather than shown as "can't open" errors.
public final class ProjectDocumentController: NSDocumentController {
    override public func openDocument(
        withContentsOf url: URL, display displayDocument: Bool,
        completionHandler: @escaping (NSDocument?, Bool, (any Error)?) -> Void
    ) {
        let isLaunchFile = MainActor.assumeIsolated {
            let options = EditorWorkspace.shared.launchOptions
            return [options.mediaURL, options.subtitlesURL, options.sourceSubtitlesURL, options.projectURL]
                .contains { $0?.standardizedFileURL == url.standardizedFileURL }
        }
        // Launch flag values that are not files ("-ApplePersistenceIgnoreState YES") arrive too.
        guard !isLaunchFile, FileManager.default.fileExists(atPath: url.path) else {
            completionHandler(nil, false, nil)
            return
        }
        guard url.pathExtension != ProjectFile.fileExtension else {
            super.openDocument(withContentsOf: url, display: displayDocument, completionHandler: completionHandler)
            return
        }
        MainActor.assumeIsolated { EditorWorkspace.shared.openMediaInNewProject(url) }
        completionHandler(nil, false, nil)
    }

    /// Opens a project Spotline itself asked for (Open Recent, the launch project), without the skipping above.
    func openProject(at url: URL, completionHandler: @escaping (NSDocument?, Bool, (any Error)?) -> Void) {
        super.openDocument(withContentsOf: url, display: true, completionHandler: completionHandler)
    }
}

import AgentBridge
import AITools
import AppKit
import EditorCommands
import Observation
import PlaybackCore

/// The app's project windows: which one the menus and agents act on, the AI
/// settings they share, and opening projects. Each window is a `SpotlineDocument`
/// with its own `EditorState` and player.
@MainActor
@Observable
public final class EditorWorkspace: ProjectActions {
    public static let shared = EditorWorkspace(launchOptions: .current)

    public let launchOptions: LaunchOptions
    /// The editor of the project window in front, which menus and agents act on.
    public private(set) var activeEditor: EditorState?
    /// Stands in when no project window is open: the menus read it (only New
    /// Project, Open Project and Open Media are enabled) and Settings edits its AI settings.
    public let idleEditor: EditorState
    /// Projects opened lately, newest first, for File › Open Recent.
    public private(set) var recentProjects: [URL] = []
    /// The launch options for the next editor made; only the first window opens the launch files.
    @ObservationIgnored private var pendingLaunchOptions: LaunchOptions?
    /// The projects macOS remembers for the app (`NSDocumentController.recentDocumentURLs`).
    @ObservationIgnored private let recentDocumentURLs: @MainActor () -> [URL]
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    /// Commands the stand-in editor allows while no project window is open.
    static let commandsWithoutProject: Set<String> = [
        EditorCommand.newProject.id, EditorCommand.openProject.id, EditorCommand.openMedia.id,
    ]

    init(
        launchOptions: LaunchOptions,
        recentDocumentURLs: @escaping @MainActor () -> [URL] = { NSDocumentController.shared.recentDocumentURLs }
    ) {
        self.launchOptions = launchOptions
        self.recentDocumentURLs = recentDocumentURLs
        let testMode = launchOptions.isUITestMode
        idleEditor = EditorState(
            launchOptions: launchOptions.withoutFiles, playback: SimulatedPlaybackEngine(), settings: testMode ? nil : .standard
        )
        idleEditor.allowedCommandIDs = Self.commandsWithoutProject
        idleEditor.projectActions = self
        idleEditor.openMediaElsewhere = { [weak self] url in
            self?.openMediaInNewProject(url)
            return true
        }
        idleEditor.onAISettingsChange = { [weak self] settings in self?.shareAISettings(settings) }
        refreshRecentProjects()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                if let document = window?.windowController?.document as? SpotlineDocument { self?.activeEditor = document.editor }
            }
        })
        // AppKit adds a project whenever one is opened or first saved (including
        // the save next to the video an AI tool makes); the list can also change
        // outside Spotline while it is in the background.
        for name in [ProjectDocumentController.recentDocumentsDidChangeNotification, NSApplication.didBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshRecentProjects() }
            })
        }
    }

    /// The editor menus show: the front project's, else the stand-in.
    public var menuEditor: EditorState { activeEditor ?? idleEditor }

    /// Every open project window's editor.
    public var documentEditors: [EditorState] {
        NSDocumentController.shared.documents.compactMap { ($0 as? SpotlineDocument)?.editor }
    }

    // MARK: Documents

    /// The editor for a new project window. The first one made with `openLaunchProject` opens the launch files.
    func makeEditor() -> EditorState {
        let options = pendingLaunchOptions ?? launchOptions.withoutFiles
        pendingLaunchOptions = nil
        let editor = EditorState(launchOptions: options)
        editor.aiSettings = idleEditor.aiSettings
        editor.onAISettingsChange = { [weak self] settings in self?.shareAISettings(settings) }
        editor.openMediaElsewhere = { [weak self, weak editor] url in
            // New media for a window that already has a video opens a new project; the
            // first video (or a missing one found again) opens in this window.
            guard let self, let editor, editor.hasMedia else { return false }
            self.openMediaInNewProject(url)
            return true
        }
        return editor
    }

    /// At launch: a window for the files given on the command line (and in UI
    /// tests, always a window). Returns false when there is nothing to open.
    @discardableResult
    public func openLaunchProject() -> Bool {
        let options = launchOptions
        guard options.isUITestMode || options.mediaURL != nil || options.subtitlesURL != nil
            || options.sourceSubtitlesURL != nil || options.projectURL != nil
        else { return false }
        if let url = options.projectURL {
            openProject(at: url)
        } else {
            pendingLaunchOptions = options
            newProject()
        }
        return true
    }

    @discardableResult
    public func newProject() -> SpotlineDocument? {
        let document = try? NSDocumentController.shared.openUntitledDocumentAndDisplay(true) as? SpotlineDocument
        if let document { activeEditor = document.editor }
        return document
    }

    public func openProject(at url: URL) {
        let completion: (NSDocument?, Bool, (any Error)?) -> Void = { [weak self] document, _, error in
            MainActor.assumeIsolated {
                if let document = document as? SpotlineDocument { self?.activeEditor = document.editor }
                if let error, (error as NSError).code != NSUserCancelledError { NSApp.presentError(error) }
            }
        }
        if let controller = NSDocumentController.shared as? ProjectDocumentController {
            controller.openProject(at: url, completionHandler: completion)
        } else {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true, completionHandler: completion)
        }
    }

    /// New media in its own project window.
    func openMediaInNewProject(_ url: URL) {
        newProject()?.editor.open(url)
    }

    func documentDidClose(_ document: SpotlineDocument) {
        guard activeEditor === document.editor else { return }
        activeEditor = documentEditors.first { $0 !== document.editor }
    }

    public func clearRecentProjects() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        refreshRecentProjects()
    }

    func refreshRecentProjects() {
        let urls = recentDocumentURLs()
        if urls != recentProjects { recentProjects = urls }
    }

    // MARK: ProjectActions (for the stand-in editor)

    public func canPerform(_ command: EditorCommand, projectURL: URL?) -> Bool {
        command == .newProject || command == .openProject
    }

    public func perform(_ command: EditorCommand) -> Bool {
        switch command.id {
        case EditorCommand.newProject.id:
            newProject()
        case EditorCommand.openProject.id:
            NSDocumentController.shared.openDocument(nil)
        default:
            return false
        }
        return true
    }

    // MARK: Settings

    /// Settings › AI apply to every window.
    private func shareAISettings(_ settings: AISettings) {
        for editor in [idleEditor] + documentEditors where editor.aiSettings != settings {
            editor.aiSettings = settings
        }
    }

    // MARK: Agents

    /// Runs an agent's tool call on the front project window. With none open, or
    /// to open media when the front window already has a video, a new window opens first.
    public func runAgentTool(_ tool: AgentTool, arguments: [String: JSONValue]) async throws -> JSONValue {
        var editor = activeEditor ?? documentEditors.first
        if editor == nil || (tool == .openMedia && editor?.hasMedia == true) {
            editor = newProject()?.editor
        }
        guard let editor else { throw AgentToolError("Spotline could not open a project window.") }
        return try await editor.runAgentTool(tool, arguments: arguments)
    }
}

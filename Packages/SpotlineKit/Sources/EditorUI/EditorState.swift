import AppKit
import EditorCommands
import MPVPlayer
import Observation
import PlaybackCore
import SubtitleCore
import SubtitleFormats

/// The editor's observable state and the single place commands are executed.
///
/// Playback state comes only from the engine's status updates: commands send
/// requests, and the timecode shows the frame the engine reports on screen.
///
/// Every change to the subtitles goes through `edit(_:_:)`, which registers it
/// with `undoManager`, so undo works the same from menus, buttons, tests and agents.
@MainActor
@Observable
public final class EditorState {
    public let launchOptions: LaunchOptions
    @ObservationIgnored public let playback: any PlaybackEngine
    public private(set) var status: PlaybackStatus
    public var frameRate: FrameRate
    public private(set) var track: SubtitleTrack
    public private(set) var selectedCueID: Cue.ID?
    /// The file the subtitles were last imported from or exported to.
    public private(set) var subtitleFile: SubtitleFileReference?
    /// True when the subtitles changed since they were last imported or exported.
    public private(set) var hasUnsavedChanges = false
    /// True while the user types in the cue text editor. Menus turn off
    /// shortcuts that would steal typing keys (see `isShortcutEnabled(for:)`).
    public var isEditingText = false {
        didSet { if !isEditingText { textEditCueID = nil } }
    }
    /// Increments when the text editor should take keyboard focus (after adding a cue).
    public private(set) var textFocusRequest = 0

    @ObservationIgnored public let undoManager: UndoManager
    public private(set) var canUndo = false
    public private(set) var canRedo = false
    /// The cue whose text the current typing session changes. Keystrokes in one
    /// session undo together.
    @ObservationIgnored private var textEditCueID: Cue.ID?

    /// Asks the user for a media file. Tests replace it.
    @ObservationIgnored public var chooseMedia: @MainActor () -> URL? = EditorPanels.chooseMedia
    /// Asks the user for a subtitle file to import. Tests replace it.
    @ObservationIgnored public var chooseSubtitlesToImport: @MainActor () -> URL? = EditorPanels.chooseSubtitles
    /// Asks the user where to export, suggesting the current file. Tests replace it.
    @ObservationIgnored public var chooseExportDestination: @MainActor (SubtitleFileReference?) -> SubtitleFileReference? =
        EditorPanels.chooseExportDestination(suggesting:)
    /// Shows a failed import or export to the user. Tests replace it.
    @ObservationIgnored public var reportError: @MainActor (_ title: String, _ error: any Error) -> Void = EditorPanels.showError

    public init(
        launchOptions: LaunchOptions = .current,
        playback: any PlaybackEngine,
        frameRate: FrameRate = .fps23_976,
        track: SubtitleTrack = SubtitleTrack()
    ) {
        self.launchOptions = launchOptions
        self.playback = playback
        self.status = playback.status
        self.frameRate = frameRate
        self.track = track
        self.undoManager = UndoManager()
        // One undo step per edit, also where no run loop groups events (unit tests).
        undoManager.groupsByEvent = false
        playback.onStatusChange = { [weak self] status in self?.playbackDidChange(status) }
        if let url = launchOptions.mediaURL { open(url) }
        if let url = launchOptions.subtitlesURL {
            importSubtitles(from: url)
            undoManager.removeAllActions()
            refreshUndoState()
        }
    }

    /// An editor playing through libmpv, configured for UI tests when launched with `-UITestMode`.
    public convenience init(launchOptions: LaunchOptions = .current) {
        let testMode = launchOptions.isUITestMode
        let player: MPVPlayer
        do {
            player = try MPVPlayer(configuration: .init(playsAudio: !testMode, usesHardwareDecoding: !testMode))
        } catch {
            fatalError("libmpv failed to start: \(error)")
        }
        self.init(launchOptions: launchOptions, playback: player)
    }

    // MARK: - Derived state

    public var hasMedia: Bool { status.hasMedia }
    public var isPlaying: Bool { hasMedia && !status.isPaused }
    public var currentFrame: Int64 { status.position.nearestFrame(at: frameRate) }
    public var currentTime: MediaTime { MediaTime(frame: currentFrame, rate: frameRate) }
    public var timecode: Timecode { Timecode(frameNumber: max(currentFrame, 0), rate: frameRate) }

    public var selectedCue: Cue? { selectedCueID.flatMap(cue(withID:)) }
    public var selectedCueIndex: Int? { selectedCueID.flatMap { id in track.cues.firstIndex { $0.id == id } } }

    public func cue(withID id: Cue.ID) -> Cue? {
        track.cues.first { $0.id == id }
    }

    /// The cue shown on the frame under the playhead.
    public var cueAtPlayhead: Cue? {
        guard hasMedia else { return nil }
        let time = currentTime
        return track.cues.last { $0.start <= time && time < $0.end }
    }

    // MARK: - Commands

    public func canPerform(_ command: EditorCommand) -> Bool {
        switch command.id {
        case EditorCommand.openMedia.id, EditorCommand.importSubtitles.id, EditorCommand.exportSubtitles.id,
             EditorCommand.addCue.id:
            true
        case EditorCommand.undo.id:
            canUndo
        case EditorCommand.redo.id:
            canRedo
        case EditorCommand.deleteCue.id:
            selectedCue != nil
        case EditorCommand.setIn.id:
            hasMedia && selectedCue.map { $0.start != currentTime } ?? false
        case EditorCommand.setOut.id:
            hasMedia && selectedCue.map { $0.end != currentTime && $0.start < currentTime } ?? false
        case EditorCommand.previousCue.id:
            selectedCueIndex.map { $0 > 0 } ?? !track.cues.isEmpty
        case EditorCommand.nextCue.id:
            selectedCueIndex.map { $0 < track.cues.count - 1 } ?? !track.cues.isEmpty
        case EditorCommand.togglePlay.id, EditorCommand.stepForward.id:
            hasMedia
        case EditorCommand.stepBackward.id, EditorCommand.goToStart.id:
            hasMedia && currentFrame > 0
        default:
            false
        }
    }

    /// Whether the command's keyboard shortcut should fire now: never while
    /// typing if the shortcut is a typing key.
    public func isShortcutEnabled(for command: EditorCommand) -> Bool {
        guard canPerform(command) else { return false }
        return !(isEditingText && command.defaultShortcut?.conflictsWithTextEditing == true)
    }

    /// Runs `command`. Returns false when it is unknown or not currently possible.
    @discardableResult
    public func perform(_ command: EditorCommand) -> Bool {
        guard canPerform(command) else { return false }
        switch command.id {
        case EditorCommand.openMedia.id:
            if let url = chooseMedia() { open(url) }
        case EditorCommand.importSubtitles.id:
            if let url = chooseSubtitlesToImport() { importSubtitles(from: url) }
        case EditorCommand.exportSubtitles.id:
            if let destination = chooseExportDestination(subtitleFile) { exportSubtitles(to: destination) }
        case EditorCommand.undo.id:
            endTextEditSession()
            undoManager.undo()
            refreshUndoState()
        case EditorCommand.redo.id:
            endTextEditSession()
            undoManager.redo()
            refreshUndoState()
        case EditorCommand.addCue.id:
            addCueAtPlayhead()
        case EditorCommand.deleteCue.id:
            deleteSelectedCue()
        case EditorCommand.setIn.id:
            setInAtPlayhead()
        case EditorCommand.setOut.id:
            setOutAtPlayhead()
        case EditorCommand.previousCue.id:
            selectNeighbour(offset: -1)
        case EditorCommand.nextCue.id:
            selectNeighbour(offset: 1)
        case EditorCommand.togglePlay.id:
            playback.setPaused(isPlaying)
        case EditorCommand.stepForward.id:
            playback.step(by: 1)
        case EditorCommand.stepBackward.id:
            playback.step(by: -1)
        case EditorCommand.goToStart.id:
            playback.setPaused(true)
            playback.seek(toFrame: 0, rate: frameRate)
        default:
            return false
        }
        return true
    }

    // MARK: - Media and files

    /// Opens a media file, replacing the current one.
    public func open(_ url: URL) {
        playback.load(url)
    }

    /// Replaces the cues with the file's. Undoable; reports errors through `reportError`.
    public func importSubtitles(from url: URL) {
        do {
            let (format, cues) = try SubtitleFile.read(from: url)
            edit("Import Subtitles") { track in
                track.cues = cues
            }
            selectedCueID = nil
            subtitleFile = SubtitleFileReference(url: url, format: format)
            hasUnsavedChanges = false
        } catch {
            reportError("“\(url.lastPathComponent)” could not be imported.", error)
        }
    }

    public func exportSubtitles(to destination: SubtitleFileReference) {
        do {
            try SubtitleFile.write(track.cues, as: destination.format, to: destination.url)
            subtitleFile = destination
            hasUnsavedChanges = false
        } catch {
            reportError("The subtitles could not be exported.", error)
        }
    }

    // MARK: - Selection

    /// Selects a cue and moves the playhead to its first frame.
    public func select(_ id: Cue.ID?) {
        guard id != selectedCueID else { return }
        endTextEditSession()
        selectedCueID = id
        if let cue = selectedCue, hasMedia {
            playback.seek(toFrame: cue.start.firstFrame(at: frameRate), rate: frameRate)
        }
    }

    private func selectNeighbour(offset: Int) {
        guard !track.cues.isEmpty else { return }
        let index = selectedCueIndex.map { $0 + offset } ?? (offset > 0 ? 0 : track.cues.count - 1)
        guard track.cues.indices.contains(index) else { return }
        select(track.cues[index].id)
    }

    // MARK: - Editing

    /// Changes the text of a cue. Consecutive changes to the same cue while
    /// typing undo as one step.
    public func setText(_ text: String, forCue id: Cue.ID) {
        guard let index = track.cues.firstIndex(where: { $0.id == id }), track.cues[index].text != text else { return }
        edit("Typing", coalescing: textEditCueID == id) { track in
            track.cues[index].text = text
        }
        textEditCueID = id
    }

    private func addCueAtPlayhead() {
        let start = currentTime
        let newCueFrames = MediaTime(value: Self.newCueSeconds, timescale: 1).nearestFrame(at: frameRate)
        var end = start + MediaTime(frame: newCueFrames, rate: frameRate)
        if let next = track.cues.first(where: { $0.start > start }), next.start < end {
            end = next.start
        }
        let cue = Cue(start: start, end: end, text: "")
        edit("Add Cue") { track in
            track.cues.append(cue)
        }
        selectedCueID = cue.id
        textFocusRequest += 1
    }

    /// New cues last two seconds, or until the next cue starts.
    static let newCueSeconds: Int64 = 2

    private func deleteSelectedCue() {
        guard let index = selectedCueIndex else { return }
        edit("Delete Cue") { track in
            track.cues.remove(at: index)
        }
        let cues = track.cues
        selectedCueID = cues.isEmpty ? nil : cues[min(index, cues.count - 1)].id
    }

    /// Moves the selected cue's start to the playhead. When that passes the
    /// cue's end, the cue keeps its duration.
    private func setInAtPlayhead() {
        guard let index = selectedCueIndex else { return }
        let time = currentTime
        edit("Set In") { track in
            let cue = track.cues[index]
            if time >= cue.end { track.cues[index].end = time + cue.duration }
            track.cues[index].start = time
        }
    }

    private func setOutAtPlayhead() {
        guard let index = selectedCueIndex else { return }
        let time = currentTime
        edit("Set Out") { track in
            track.cues[index].end = time
        }
    }

    /// Applies one undoable change to the track and keeps cues ordered by start time.
    /// With `coalescing`, the change joins the previous undo step.
    private func edit(_ actionName: String, coalescing: Bool = false, _ change: (inout SubtitleTrack) -> Void) {
        let before = Snapshot(track: track, selectedCueID: selectedCueID)
        var edited = track
        change(&edited)
        edited.cues.sort { $0.start < $1.start }
        guard edited != track else { return }
        if !coalescing {
            endTextEditSession()
            registerUndo(restoring: before, actionName: actionName)
        }
        track = edited
        hasUnsavedChanges = true
        refreshUndoState()
    }

    private struct Snapshot {
        var track: SubtitleTrack
        var selectedCueID: Cue.ID?
    }

    private func registerUndo(restoring snapshot: Snapshot, actionName: String) {
        let ownsGroup = !undoManager.isUndoing && !undoManager.isRedoing
        if ownsGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { editor in
            MainActor.assumeIsolated {
                editor.restore(snapshot, actionName: actionName)
            }
        }
        undoManager.setActionName(actionName)
        if ownsGroup { undoManager.endUndoGrouping() }
    }

    /// Undo and redo: puts back `snapshot` and registers the reverse.
    private func restore(_ snapshot: Snapshot, actionName: String) {
        registerUndo(restoring: Snapshot(track: track, selectedCueID: selectedCueID), actionName: actionName)
        track = snapshot.track
        selectedCueID = snapshot.selectedCueID
        hasUnsavedChanges = true
    }

    private func endTextEditSession() {
        textEditCueID = nil
    }

    private func refreshUndoState() {
        canUndo = undoManager.canUndo
        canRedo = undoManager.canRedo
    }

    // MARK: - Playback

    private func playbackDidChange(_ status: PlaybackStatus) {
        if let rate = status.frameRate, rate != self.status.frameRate {
            frameRate = rate
        }
        self.status = status
    }
}

/// A subtitle file on disk and the format it is written in.
public struct SubtitleFileReference: Hashable, Sendable {
    public var url: URL
    public var format: SubtitleFormat

    public init(url: URL, format: SubtitleFormat) {
        self.url = url
        self.format = format
    }
}

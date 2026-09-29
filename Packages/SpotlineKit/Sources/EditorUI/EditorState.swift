import AppKit
import EditorCommands
import MPVPlayer
import Observation
import PlaybackCore
import SubtitleCore
import MediaAnalysis
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
    /// The engine's latest status. Observers see it change only when something
    /// other than the position changes; the position, which changes every frame
    /// during playback, is `position`. Menus and pickers depend on `status`, and
    /// redrawing them every frame breaks open menus.
    public private(set) var status: PlaybackStatus
    /// The timestamp of the frame on screen.
    public private(set) var position: MediaTime
    /// True on the first frame (and with no media). Kept apart from `position`
    /// so menus depending on it redraw only when it flips.
    public private(set) var isAtStart = true
    public var frameRate: FrameRate
    public private(set) var track: SubtitleTrack {
        didSet {
            guard track.cues != oldValue.cues else { return }
            issues = Review.issues(in: track.cues)
            updateCurrentCue()
        }
    }
    /// The cue on screen at the playhead. Kept apart from `position` so the
    /// cue list redraws only when it changes, not every frame.
    public private(set) var currentCueID: Cue.ID?
    /// Cues that need another look, with why. Kept in step with `track`.
    public private(set) var issues: [Cue.ID: [ReviewIssue]] = [:]
    /// Show times as HH:MM:SS,mmm instead of SMPTE frames.
    public private(set) var showsMilliseconds = false
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

    /// The open media's waveform, filled in while it is being read.
    public private(set) var audioAnalysis: AudioAnalysis?
    /// Where people speak in the waveform's audio, filled in while detected.
    public private(set) var speech: [SpeechRegion]?
    /// The open media's shot changes, filled in while they are being found.
    public private(set) var shotChanges: [MediaTime]?
    /// The two analysis jobs while they run, nil once done. They run side by
    /// side: the waveform takes seconds, shot changes take minutes on a feature.
    public private(set) var waveformJob: AnalysisJob?
    public private(set) var shotChangesJob: AnalysisJob?
    public private(set) var speechJob: AnalysisJob?
    @ObservationIgnored private var speechTask: Task<Void, Never>?
    @ObservationIgnored private var waveformTask: Task<Void, Never>?
    @ObservationIgnored private var shotChangesTask: Task<Void, Never>?
    /// The audio stream the running or finished waveform reads, once known.
    @ObservationIgnored private var analyzedAudioStream: Int?
    /// Read a waveform and find shot changes off the main actor. Tests replace them.
    @ObservationIgnored public var analyzeWaveform:
        @Sendable (URL, Int?, @escaping @Sendable (MediaAnalyzer.Progress<AudioAnalysis>) -> Void) async throws -> AudioAnalysis =
        EditorState.waveformAnalyzer(cache: .standard)
    @ObservationIgnored public var analyzeSpeech:
        @Sendable (URL, Int?, @escaping @Sendable (MediaAnalyzer.Progress<[SpeechRegion]>) -> Void) async throws -> [SpeechRegion] =
        EditorState.speechAnalyzer(cache: .standard)
    @ObservationIgnored public var analyzeShotChanges:
        @Sendable (URL, @escaping @Sendable (MediaAnalyzer.Progress<[MediaTime]>) -> Void) async throws -> [MediaTime] =
        EditorState.shotChangeAnalyzer(cache: .standard)

    /// The timeline's visible span in seconds, as it last reported it (view geometry).
    public private(set) var timelineViewport: ClosedRange<Double> = 0...0
    /// Asks the timeline to show a time; the mini-map sets it.
    public private(set) var timelineScrollRequest: TimelineScrollRequest?

    /// Timeline zoom in points per second of media.
    public private(set) var timelineScale: Double = 100
    public static let timelineScaleRange: ClosedRange<Double> = 0.5...2_000
    /// Whether timeline drags snap to shot changes, the playhead and other cues' edges.
    public private(set) var isSnappingEnabled = true
    /// Whether the waveform draws speech brightly and dims music and effects.
    public private(set) var isSpeechHighlighted = true
    /// J/K/L shuttle speed: 0 when not shuttling, negative backward.
    @ObservationIgnored private var shuttleRate: Double = 0

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
        self.position = playback.status.position
        self.frameRate = frameRate
        self.track = track
        self.issues = Review.issues(in: track.cues)
        self.undoManager = UndoManager()
        // One undo step per edit, also where no run loop groups events (unit tests).
        undoManager.groupsByEvent = false
        playback.onStatusChange = { [weak self] status in self?.playbackDidChange(status) }
        if !launchOptions.usesAnalysisCache {
            analyzeWaveform = Self.waveformAnalyzer(cache: nil)
            analyzeSpeech = Self.speechAnalyzer(cache: nil)
            analyzeShotChanges = Self.shotChangeAnalyzer(cache: nil)
        }
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
    public var currentFrame: Int64 { position.nearestFrame(at: frameRate) }
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
        case EditorCommand.deleteCue.id, EditorCommand.splitCue.id, EditorCommand.togglePositionTop.id:
            selectedCue != nil
        case EditorCommand.mergeWithNext.id:
            selectedCueIndex.map { $0 < track.cues.count - 1 } ?? false
        case EditorCommand.previousIssue.id, EditorCommand.nextIssue.id:
            !issues.isEmpty
        case EditorCommand.toggleMilliseconds.id:
            true
        // Commands that depend on where the playhead is are enabled whenever they
        // could apply, and do nothing (returning false) when they would not change
        // anything, so their menu items do not redraw on every frame.
        case EditorCommand.setIn.id, EditorCommand.setOut.id:
            hasMedia && selectedCue != nil
        case EditorCommand.previousShotChange.id, EditorCommand.nextShotChange.id:
            hasMedia && !(shotChanges ?? []).isEmpty
        case EditorCommand.zoomIn.id:
            timelineScale < Self.timelineScaleRange.upperBound
        case EditorCommand.zoomOut.id:
            timelineScale > Self.timelineScaleRange.lowerBound
        case EditorCommand.toggleSnapping.id, EditorCommand.toggleSpeechHighlight.id:
            true
        case EditorCommand.previousCue.id:
            selectedCueIndex.map { $0 > 0 } ?? !track.cues.isEmpty
        case EditorCommand.nextCue.id:
            selectedCueIndex.map { $0 < track.cues.count - 1 } ?? !track.cues.isEmpty
        case EditorCommand.nextAudioTrack.id:
            hasMedia && audioTracks.count > 1
        case EditorCommand.togglePlay.id, EditorCommand.stepForward.id, EditorCommand.shuttleBackward.id,
             EditorCommand.pause.id, EditorCommand.shuttleForward.id:
            hasMedia
        case EditorCommand.stepBackward.id, EditorCommand.goToStart.id:
            hasMedia && !isAtStart
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

    /// The on/off state of a toggle command, nil for other commands.
    public func isOn(_ command: EditorCommand) -> Bool? {
        switch command.id {
        case EditorCommand.toggleSnapping.id: isSnappingEnabled
        case EditorCommand.toggleSpeechHighlight.id: isSpeechHighlighted
        case EditorCommand.toggleMilliseconds.id: showsMilliseconds
        case EditorCommand.togglePositionTop.id: selectedCue.map { $0.position == .top }
        default: nil
        }
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
        case EditorCommand.splitCue.id:
            return splitSelectedCue()
        case EditorCommand.mergeWithNext.id:
            mergeSelectedWithNext()
        case EditorCommand.togglePositionTop.id:
            if let cue = selectedCue { setPosition(cue.position == .top ? .bottom : .top, forCue: cue.id) }
        case EditorCommand.previousIssue.id:
            return selectIssue(forward: false)
        case EditorCommand.nextIssue.id:
            return selectIssue(forward: true)
        case EditorCommand.toggleMilliseconds.id:
            showsMilliseconds.toggle()
        case EditorCommand.shuttleForward.id:
            shuttle(forward: true)
        case EditorCommand.shuttleBackward.id:
            shuttle(forward: false)
        case EditorCommand.pause.id:
            shuttleRate = 0
            playback.setPaused(true)
        case EditorCommand.setIn.id:
            return setInAtPlayhead()
        case EditorCommand.setOut.id:
            return setOutAtPlayhead()
        case EditorCommand.previousShotChange.id:
            guard let frame = shotChangeFrame(before: currentFrame) else { return false }
            seek(toFrame: frame)
        case EditorCommand.nextShotChange.id:
            guard let frame = shotChangeFrame(after: currentFrame) else { return false }
            seek(toFrame: frame)
        case EditorCommand.zoomIn.id:
            setTimelineScale(timelineScale * 1.5)
        case EditorCommand.zoomOut.id:
            setTimelineScale(timelineScale / 1.5)
        case EditorCommand.toggleSnapping.id:
            isSnappingEnabled.toggle()
        case EditorCommand.toggleSpeechHighlight.id:
            isSpeechHighlighted.toggle()
        case EditorCommand.previousCue.id:
            selectNeighbour(offset: -1)
        case EditorCommand.nextCue.id:
            selectNeighbour(offset: 1)
        case EditorCommand.nextAudioTrack.id:
            let tracks = audioTracks
            let current = tracks.firstIndex { $0.id == selectedAudioTrackID } ?? -1
            selectAudioTrack(id: tracks[(current + 1) % tracks.count].id)
        case EditorCommand.togglePlay.id:
            shuttleRate = 0
            if isPlaying { playback.setPaused(true) } else { playback.play(rate: 1) }
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

    /// Selects the previous or next cue. While typing, the cursor moves to its text.
    private func selectNeighbour(offset: Int) {
        guard !track.cues.isEmpty else { return }
        let index = selectedCueIndex.map { $0 + offset } ?? (offset > 0 ? 0 : track.cues.count - 1)
        guard track.cues.indices.contains(index) else { return }
        let keepTyping = isEditingText
        select(track.cues[index].id)
        if keepTyping { textFocusRequest += 1 }
    }

    /// Selects the next (or previous) cue that needs review. Returns false when there is none that way.
    private func selectIssue(forward: Bool) -> Bool {
        let cues = track.cues
        let current = selectedCueIndex ?? (forward ? -1 : cues.count)
        let candidates = forward ? Array((current + 1)..<cues.count) : Array((0..<max(current, 0)).reversed())
        guard let index = candidates.first(where: { issues[cues[$0].id] != nil }) else { return false }
        select(cues[index].id)
        return true
    }

    /// L plays forward and speeds up with each press (1×, 2×, 4×, 8×); J does the same backward.
    private func shuttle(forward: Bool) {
        let sameDirection = isPlaying && (forward ? shuttleRate > 0 : shuttleRate < 0)
        let speed = sameDirection ? min(abs(shuttleRate) * 2, 8) : 1
        shuttleRate = forward ? speed : -speed
        playback.play(rate: shuttleRate)
    }

    // MARK: - Time labels

    /// A cue edge as the editor shows it: the first frame showing (or no longer
    /// showing) the cue as SMPTE timecode, or HH:MM:SS,mmm with milliseconds on.
    public func label(for time: MediaTime) -> String {
        showsMilliseconds
            ? Timestamp.format(time)
            : Timecode(frameNumber: max(time.firstFrame(at: frameRate), 0), rate: frameRate).description
    }

    /// Reads a typed time: SMPTE timecode (HH:MM:SS:FF) or HH:MM:SS,mmm.
    /// Timecodes give the frame's start; milliseconds are kept exactly.
    public func time(from label: String) -> MediaTime? {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        if let time = Timestamp.parse(trimmed) { return time }
        return Timecode(trimmed, rate: frameRate)?.time
    }

    // MARK: - Audio tracks

    /// Copies of the player's track list and selection, so the Audio Track
    /// menu only redraws when they change.
    public private(set) var audioTracks: [AudioTrack] = []
    public private(set) var selectedAudioTrackID: Int?

    public var selectedAudioTrack: AudioTrack? {
        audioTracks.first { $0.id == selectedAudioTrackID }
    }

    /// Plays another audio track; the waveform follows once the player reports it.
    public func selectAudioTrack(id: Int) {
        guard audioTracks.contains(where: { $0.id == id }), id != selectedAudioTrackID else { return }
        playback.selectAudioTrack(id: id)
    }

    // MARK: - Playhead and timeline

    /// Pauses nothing; shows `frame` at the media's rate.
    public func seek(toFrame frame: Int64) {
        guard hasMedia else { return }
        playback.seek(toFrame: max(frame, 0), rate: frameRate)
    }

    /// Called by the timeline when it scrolls, zooms or resizes.
    public func timelineDidShow(_ viewport: ClosedRange<Double>) {
        if viewport != timelineViewport { timelineViewport = viewport }
    }

    /// Scrolls the timeline so `seconds` is in the middle (from the mini-map).
    public func scrollTimeline(toCenter seconds: Double) {
        timelineScrollRequest = TimelineScrollRequest(
            centerSeconds: seconds, serial: (timelineScrollRequest?.serial ?? 0) + 1
        )
    }

    private func updateCurrentCue() {
        let id = cueAtPlayhead?.id
        if id != currentCueID { currentCueID = id }
    }

    public func setTimelineScale(_ scale: Double) {
        timelineScale = min(max(scale, Self.timelineScaleRange.lowerBound), Self.timelineScaleRange.upperBound)
    }

    /// Shot changes as frame numbers at the current rate.
    public var shotChangeFrames: [Int64] {
        (shotChanges ?? []).map { $0.nearestFrame(at: frameRate) }
    }

    private func shotChangeFrame(before frame: Int64) -> Int64? {
        shotChangeFrames.last { $0 < frame }
    }

    private func shotChangeFrame(after frame: Int64) -> Int64? {
        shotChangeFrames.first { $0 > frame }
    }

    /// Times a dragged cue edge snaps to: shot changes, the playhead and the
    /// edges of every other cue.
    public func snapTargets(excluding cueID: Cue.ID?) -> [MediaTime] {
        guard isSnappingEnabled else { return [] }
        var targets = shotChangeFrames.map { MediaTime(frame: $0, rate: frameRate) }
        if hasMedia { targets.append(currentTime) }
        for cue in track.cues where cue.id != cueID {
            targets.append(cue.start)
            targets.append(cue.end)
        }
        return targets
    }

    // MARK: - Editing

    /// Sets a cue's start and end in one undoable step (a timeline drag or nudge).
    public func setTiming(start: MediaTime, end: MediaTime, forCue id: Cue.ID, actionName: String) {
        guard start < end, start >= .zero, let index = track.cues.firstIndex(where: { $0.id == id }) else { return }
        edit(actionName) { track in
            track.cues[index].start = start
            track.cues[index].end = end
        }
    }

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

    /// Splits the selected cue at the playhead when it is inside the cue, else in the middle.
    /// Two or more lines split between lines; one line splits at the word nearest its middle.
    private func splitSelectedCue() -> Bool {
        guard let index = selectedCueIndex else { return false }
        let cue = track.cues[index]
        let oneFrame = MediaTime(frame: 1, rate: frameRate)
        var at = currentTime
        if !(hasMedia && cue.start + oneFrame <= at && at + oneFrame <= cue.end) {
            let middle = cue.start + MediaTime(value: (cue.duration.value), timescale: cue.duration.timescale * 2)
            at = middle.snapped(to: frameRate)
        }
        guard cue.start < at, at < cue.end else { return false }
        let (firstText, secondText) = Self.splitText(cue.text)
        var first = cue
        first.end = at
        first.text = firstText
        let second = Cue(start: at, end: cue.end, text: secondText, position: cue.position)
        edit("Split Cue") { track in
            track.cues[index] = first
            track.cues.insert(second, at: index + 1)
        }
        return true
    }

    static func splitText(_ text: String) -> (String, String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > 1 {
            let half = (lines.count + 1) / 2
            return (lines[..<half].joined(separator: "\n"), lines[half...].joined(separator: "\n"))
        }
        let middle = text.count / 2
        let spaces = text.indices.filter { text[$0] == " " }
        guard let split = spaces.min(by: {
            abs(text.distance(from: text.startIndex, to: $0) - middle) < abs(text.distance(from: text.startIndex, to: $1) - middle)
        }) else { return (text, "") }
        return (String(text[..<split]), String(text[text.index(after: split)...]))
    }

    private func mergeSelectedWithNext() {
        guard let index = selectedCueIndex, index + 1 < track.cues.count else { return }
        let next = track.cues[index + 1]
        edit("Merge Cues") { track in
            var merged = track.cues[index]
            merged.end = max(merged.end, next.end)
            merged.text = [merged.text, next.text].filter { !$0.isEmpty }.joined(separator: "\n")
            track.cues[index] = merged
            track.cues.remove(at: index + 1)
        }
    }

    /// Adds an empty cue after `id`: two frames after it ends (a common
    /// minimum gap), two seconds long or up to the next cue.
    public func addCue(after id: Cue.ID) {
        guard let index = track.cues.firstIndex(where: { $0.id == id }) else { return }
        let gap = MediaTime(frame: 2, rate: frameRate)
        let start = MediaTime(frame: (track.cues[index].end + gap).firstFrame(at: frameRate), rate: frameRate)
        let newCueFrames = MediaTime(value: Self.newCueSeconds, timescale: 1).nearestFrame(at: frameRate)
        var end = start + MediaTime(frame: newCueFrames, rate: frameRate)
        if index + 1 < track.cues.count, track.cues[index + 1].start > start {
            end = min(end, track.cues[index + 1].start)
        }
        let cue = Cue(start: start, end: end, text: "")
        edit("Add Cue") { track in
            track.cues.insert(cue, at: index + 1)
        }
        selectedCueID = cue.id
        textFocusRequest += 1
    }

    /// Shows a cue at the top or bottom of the picture.
    public func setPosition(_ position: CuePosition, forCue id: Cue.ID) {
        guard let index = track.cues.firstIndex(where: { $0.id == id }) else { return }
        edit(position == .top ? "Show Cue at Top" : "Show Cue at Bottom") { track in
            track.cues[index].position = position
        }
    }

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
    private func setInAtPlayhead() -> Bool {
        guard let index = selectedCueIndex, track.cues[index].start != currentTime else { return false }
        let time = currentTime
        edit("Set In") { track in
            let cue = track.cues[index]
            if time >= cue.end { track.cues[index].end = time + cue.duration }
            track.cues[index].start = time
        }
        return true
    }

    /// Moves the selected cue's end to the playhead, which must be after its start.
    private func setOutAtPlayhead() -> Bool {
        guard let index = selectedCueIndex else { return false }
        let cue = track.cues[index]
        let time = currentTime
        guard cue.start < time, cue.end != time else { return false }
        edit("Set Out") { track in
            track.cues[index].end = time
        }
        return true
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
        let mediaChanged = status.mediaURL != self.status.mediaURL
        var withoutPosition = status
        withoutPosition.position = self.status.position
        if withoutPosition != self.status { self.status = status }
        if status.position != position {
            position = status.position
            updateCurrentCue()
        }
        let atStart = !status.hasMedia || status.position.nearestFrame(at: frameRate) <= 0
        if atStart != isAtStart { isAtStart = atStart }
        if status.audioTracks != audioTracks { audioTracks = status.audioTracks }
        if status.selectedAudioTrackID != selectedAudioTrackID { selectedAudioTrackID = status.selectedAudioTrackID }
        // Analyze again when the player switches to another audio track than the waveform shows.
        let audioTrackChanged = status.audioStreamIndex.map { $0 != analyzedAudioStream } ?? false
        if mediaChanged {
            startWaveformAnalysis()
            startShotChangeAnalysis()
        } else if audioTrackChanged {
            startWaveformAnalysis()
        }
    }

    // MARK: - Media analysis

    /// Waveform and shot changes together, nil before either has results.
    public var analysis: MediaAnalysis? {
        guard audioAnalysis != nil || shotChanges != nil else { return nil }
        return MediaAnalysis(
            waveform: audioAnalysis?.waveform,
            shotChanges: shotChanges ?? [],
            audioStreamIndex: audioAnalysis?.audioStreamIndex
        )
    }

    /// While analysis runs, how far into the media every running job has read.
    public var analyzedUntil: MediaTime? {
        [waveformJob, speechJob, shotChangesJob].compactMap { $0?.analyzedUntil }.min()
    }

    /// Starts the waveform and speech jobs for the playing audio track.
    private func startWaveformAnalysis() {
        startSpeechAnalysis()
        waveformTask?.cancel()
        audioAnalysis = nil
        waveformJob = nil
        analyzedAudioStream = status.audioStreamIndex
        guard let url = status.mediaURL else { return }
        waveformJob = AnalysisJob()
        let analyze = analyzeWaveform
        let stream = status.audioStreamIndex
        let report: @Sendable (MediaAnalyzer.Progress<AudioAnalysis>) -> Void = { [weak self] progress in
            guard let editor = self else { return }
            Task { @MainActor in editor.waveformDidProgress(progress, for: url) }
        }
        waveformTask = Task { [weak self] in
            let result = try? await analyze(url, stream, report)
            guard let self, !Task.isCancelled, self.status.mediaURL == url else { return }
            if let result {
                self.audioAnalysis = result
                self.analyzedAudioStream = result.audioStreamIndex
            }
            self.waveformJob = nil
        }
    }

    private func startSpeechAnalysis() {
        speechTask?.cancel()
        speech = nil
        speechJob = nil
        guard let url = status.mediaURL else { return }
        speechJob = AnalysisJob()
        let analyze = analyzeSpeech
        let stream = status.audioStreamIndex
        let report: @Sendable (MediaAnalyzer.Progress<[SpeechRegion]>) -> Void = { [weak self] progress in
            guard let editor = self else { return }
            Task { @MainActor in editor.speechDidProgress(progress, for: url) }
        }
        speechTask = Task { [weak self] in
            let result = try? await analyze(url, stream, report)
            guard let self, !Task.isCancelled, self.status.mediaURL == url else { return }
            if let result { self.speech = result }
            self.speechJob = nil
        }
    }

    private func speechDidProgress(_ progress: MediaAnalyzer.Progress<[SpeechRegion]>, for url: URL) {
        guard status.mediaURL == url, let job = speechJob, let next = job.advanced(by: progress) else { return }
        speechJob = next
        if let partial = progress.partial { speech = partial }
    }

    private func startShotChangeAnalysis() {
        shotChangesTask?.cancel()
        shotChanges = nil
        shotChangesJob = nil
        guard let url = status.mediaURL else { return }
        shotChangesJob = AnalysisJob()
        let analyze = analyzeShotChanges
        let report: @Sendable (MediaAnalyzer.Progress<[MediaTime]>) -> Void = { [weak self] progress in
            guard let editor = self else { return }
            Task { @MainActor in editor.shotChangesDidProgress(progress, for: url) }
        }
        shotChangesTask = Task { [weak self] in
            let result = try? await analyze(url, report)
            guard let self, !Task.isCancelled, self.status.mediaURL == url else { return }
            if let result { self.shotChanges = result }
            self.shotChangesJob = nil
        }
    }

    /// Shows partial results. Reports can arrive out of order, so older ones are ignored.
    private func waveformDidProgress(_ progress: MediaAnalyzer.Progress<AudioAnalysis>, for url: URL) {
        guard status.mediaURL == url, let job = waveformJob, let next = job.advanced(by: progress) else { return }
        waveformJob = next
        if let partial = progress.partial {
            audioAnalysis = partial
            analyzedAudioStream = partial.audioStreamIndex
        }
    }

    private func shotChangesDidProgress(_ progress: MediaAnalyzer.Progress<[MediaTime]>, for url: URL) {
        guard status.mediaURL == url, let job = shotChangesJob, let next = job.advanced(by: progress) else { return }
        shotChangesJob = next
        if let partial = progress.partial { shotChanges = partial }
    }

    private nonisolated static func waveformAnalyzer(
        cache: AnalysisCache?
    ) -> @Sendable (URL, Int?, @escaping @Sendable (MediaAnalyzer.Progress<AudioAnalysis>) -> Void) async throws -> AudioAnalysis {
        { url, stream, progress in
            if let cached = cache?.waveform(for: url, audioStream: stream) { return cached }
            var options = MediaAnalyzer.Options()
            options.audioStreamIndex = stream
            let result = try await runDetached { [options] in
                try MediaAnalyzer.waveform(of: url, options: options) { report in
                    progress(report)
                    return !Task.isCancelled
                }
            }
            cache?.store(result, for: url, audioStream: stream)
            return result
        }
    }

    private nonisolated static func speechAnalyzer(
        cache: AnalysisCache?
    ) -> @Sendable (URL, Int?, @escaping @Sendable (MediaAnalyzer.Progress<[SpeechRegion]>) -> Void) async throws -> [SpeechRegion] {
        { url, stream, progress in
            if let cached = cache?.speech(for: url, audioStream: stream) { return cached }
            var options = MediaAnalyzer.Options()
            options.audioStreamIndex = stream
            let result = try await runDetached { [options] in
                try MediaAnalyzer.speech(in: url, options: options) { report in
                    progress(report)
                    return !Task.isCancelled
                }
            }
            cache?.store(speech: result, for: url, audioStream: stream)
            return result
        }
    }

    private nonisolated static func shotChangeAnalyzer(
        cache: AnalysisCache?
    ) -> @Sendable (URL, @escaping @Sendable (MediaAnalyzer.Progress<[MediaTime]>) -> Void) async throws -> [MediaTime] {
        { url, progress in
            if let cached = cache?.shotChanges(for: url) { return cached }
            let result = try await runDetached {
                try MediaAnalyzer.shotChanges(in: url) { report in
                    progress(report)
                    return !Task.isCancelled
                }
            }
            cache?.store(shotChanges: result, for: url)
            return result
        }
    }

    /// Runs blocking work on a background thread, cancelling it with the caller.
    private nonisolated static func runDetached<Result: Sendable>(
        _ work: @escaping @Sendable () throws -> Result
    ) async throws -> Result {
        let task = Task.detached(priority: .utility, operation: work)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

/// A request for the timeline to scroll; `serial` makes repeated requests distinct.
public struct TimelineScrollRequest: Equatable, Sendable {
    public var centerSeconds: Double
    public var serial: Int
}

/// How far a running analysis job has got.
public struct AnalysisJob: Equatable, Sendable {
    /// 0 to 1.
    public var fraction: Double = 0
    /// Results cover the media before this time.
    public var analyzedUntil: MediaTime = .zero

    /// The job after `progress`, or nil when the report is older than what is shown.
    func advanced<Partial>(by progress: MediaAnalyzer.Progress<Partial>) -> AnalysisJob? {
        guard progress.analyzedUntil >= analyzedUntil else { return nil }
        return AnalysisJob(
            fraction: progress.fraction,
            analyzedUntil: progress.partial != nil ? progress.analyzedUntil : analyzedUntil
        )
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

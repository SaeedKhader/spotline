import AITools
import AppKit
import EditorCommands
import MPVPlayer
import Observation
import PlaybackCore
import QualityControl
import SubtitleCore
import MediaAnalysis
import SubtitleFormats
import SubtitleTranslation

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
    public var frameRate: FrameRate {
        didSet { if frameRate != oldValue { updateIssues() } }
    }
    /// The subtitles being edited; in translation mode, the target (translation).
    public internal(set) var track: SubtitleTrack {
        didSet {
            if track.languageCode != oldValue.languageCode { translationPairDidChange() }
            guard track.cues != oldValue.cues else { return }
            // The review ends when no choice is left open.
            if isReviewingChoices, !track.cues.contains(where: { $0.flag?.isResolved == false }) { isReviewingChoices = false }
            if isReviewingWords, !track.cues.contains(where: { $0.unsureWords?.isEmpty == false }) { isReviewingWords = false }
            updateSourceCues()
            updateIssues()
            updateCurrentCue()
        }
    }

    // MARK: Translation state

    /// The source-language subtitles a translation is made from, shown read-only
    /// beside each target cue. Nil outside translation mode.
    public internal(set) var sourceTrack: SubtitleTrack? {
        didSet {
            if sourceTrack != oldValue, !isLoadingProject { projectDidChange?(.other) }
            updateSourceCues()
            updateGlossaryHits()
            updateIssues()
        }
    }
    /// The file the source subtitles were read from.
    public internal(set) var sourceFile: SubtitleFileReference?
    /// Each target cue's source cue (by link, else by overlap), in translation mode.
    public internal(set) var sourceCues: [Cue.ID: Cue] = [:]
    /// Agreed translations of names and terms for the language pair.
    public internal(set) var glossary = Glossary() {
        didSet {
            guard glossary != oldValue else { return }
            glossaryIndex = GlossaryIndex(glossary)
            updateGlossaryHits()
            updateIssues()
            if !isLoadingTranslationResources { try? translationStore?.save(glossary, pair: translationPair) }
        }
    }
    /// Translations already made for the language pair, suggested for similar lines.
    public internal(set) var memory = TranslationMemory() {
        didSet { memoryMatchCache = [:] }
    }
    /// Where glossaries and memories are kept; nil keeps them in memory only (tests).
    @ObservationIgnored let translationStore: TranslationStore?
    @ObservationIgnored var glossaryIndex = GlossaryIndex(Glossary())
    /// Glossary entries found in each source cue, by source cue ID.
    @ObservationIgnored var glossaryHits: [Cue.ID: [Glossary.Entry]] = [:]
    /// Memory suggestions by source cue ID, until the memory changes.
    @ObservationIgnored var memoryMatchCache: [Cue.ID: [TranslationMemory.Match]] = [:]
    /// The pair the glossary and memory belong to, e.g. "en-ar".
    @ObservationIgnored var translationPair = "und-und"
    /// True while the glossary and memory are replaced by the new pair's, which needs no saving.
    @ObservationIgnored var isLoadingTranslationResources = false
    /// The last target language chosen, for new translations.
    static let targetLanguageKey = "TranslationTargetLanguage"
    /// Opens (or brings forward) the glossary panel. Tests replace it.
    @ObservationIgnored public var showGlossaryPanel: @MainActor (EditorState) -> Void = EditorPanels.showGlossary(editor:)
    /// Asks for a glossary file to import. Tests replace it.
    @ObservationIgnored public var chooseGlossaryToImport: @MainActor () -> URL? = EditorPanels.chooseGlossary
    // MARK: AI state

    /// What the last AI tool proposed, shown as a diff in the cue list until each change is accepted or rejected.
    public internal(set) var pendingReview: ProposedChangeSet?
    /// The AI tool running now, with its progress; nil when none.
    public internal(set) var aiTask: AITaskStatus? {
        didSet { if aiTask != oldValue { onAITaskChange?(aiTask) } }
    }
    /// What the last AI tool did, shown in the AI bar for a few seconds after it finishes.
    public internal(set) var aiSummary: AITaskSummary?
    /// How long `aiSummary` stays. Tests shorten it.
    @ObservationIgnored public var aiSummaryDuration: Duration = .seconds(8)
    /// Tells the app about the running AI tool (the Dock shows its progress).
    @ObservationIgnored public var onAITaskChange: (@MainActor (AITaskStatus?) -> Void)?
    /// Tells the app how an AI tool ended (a notification while Spotline is in the background).
    @ObservationIgnored public var onAITaskEnd: (@MainActor (AITaskEnd) -> Void)?
    /// Counts AI tools started, so reports from one that was cancelled are dropped.
    @ObservationIgnored var aiTaskGeneration = 0
    /// The last progress report taken in; older ones arriving late are dropped.
    @ObservationIgnored var reportSerial = 0
    @ObservationIgnored var aiTaskHandle: Task<Void, Never>?
    /// Cues the running tool has already written, so later results do not write them again.
    @ObservationIgnored var appliedAIChanges: Set<Cue.ID> = []
    /// Counts partial results of the running tool; older ones arriving late are dropped.
    @ObservationIgnored var partialSerial = 0
    /// Cues whose text an agent wrote, for the AI tint's tooltip.
    @ObservationIgnored var agentWrittenCues: Set<Cue.ID> = []
    /// The last error shown to the person once agents have connected, for agents to read.
    @ObservationIgnored var lastAgentVisibleError: String?
    @ObservationIgnored var isRecordingErrorsForAgents = false
    /// Providers and cloud consent (Settings › AI).
    public var aiSettings: AISettings {
        didSet {
            guard aiSettings != oldValue else { return }
            aiSettings.save(to: settings)
            onAISettingsChange?(aiSettings)
        }
    }
    /// Called when the settings change here, so every project window uses them.
    @ObservationIgnored public var onAISettingsChange: (@MainActor (AISettings) -> Void)?
    /// Makes the transcriber and translator the settings ask for. Tests and UI tests use scripted ones.
    @ObservationIgnored public var aiProviders: AIProviderFactory
    /// Reads and chunks the dialogue audio for speech models (cached). Tests replace it.
    @ObservationIgnored public var prepareAudio:
        @Sendable (URL, Int?, @escaping @Sendable (Double) -> Void) async throws -> PreparedAudio =
        EditorState.audioPreparer(cache: .standard)

    /// The cue on screen at the playhead. Kept apart from `position` so the
    /// cue list redraws only when it changes, not every frame.
    public private(set) var currentCueID: Cue.ID?
    /// Cues that break the QC preset's rules, with why. Kept in step with the
    /// cues, the preset, the frame rate and the shot changes.
    public private(set) var issues: [Cue.ID: [QCIssue]] = [:]
    /// The rules cues are checked against.
    public private(set) var qcPreset: QCPreset {
        didSet {
            guard qcPreset != oldValue else { return }
            updateIssues()
            guard !isLoadingProject else { return }
            settings?.set(qcPreset.id, forKey: Self.qcPresetKey)
            projectDidChange?(.other)
        }
    }
    /// Whether the issues panel under the cue list is open.
    public private(set) var isIssuesPanelShown = false
    /// True while the cue list shows only the lines AI translation flagged, least confident first.
    public internal(set) var isReviewingChoices = false
    /// True while the cue list shows only the cues with words to check (AI › Review Words to Check).
    public internal(set) var isReviewingWords = false
    /// Where playback pauses by itself: after a word played for checking.
    @ObservationIgnored var playbackStopTime: MediaTime?
    /// Where the chosen QC preset is remembered; nil in tests.
    @ObservationIgnored let settings: UserDefaults?
    static let qcPresetKey = "QCPreset"
    /// Show times as HH:MM:SS,mmm instead of SMPTE frames.
    public private(set) var showsMilliseconds = false
    public internal(set) var selectedCueID: Cue.ID?
    /// The file the subtitles were last imported from or exported to.
    public internal(set) var subtitleFile: SubtitleFileReference? {
        didSet { if subtitleFile != oldValue, !isLoadingProject { projectDidChange?(.other) } }
    }
    /// True when the subtitles changed since they were last imported or exported.
    public internal(set) var hasUnsavedChanges = false
    /// True while the user types in the cue text editor. Menus turn off
    /// shortcuts that would steal typing keys (see `isShortcutEnabled(for:)`).
    public var isEditingText = false {
        didSet { if !isEditingText { textEditCueID = nil } }
    }
    /// Increments when the text editor should take keyboard focus (after adding a cue).
    public private(set) var textFocusRequest = 0

    // MARK: Project state (EditorState+Project.swift)

    /// The project file (`.spotline`) this editor's window shows, nil while untitled.
    public var projectURL: URL?
    /// Tells the project document that something it saves has changed.
    @ObservationIgnored public var projectDidChange: (@MainActor (ProjectChange) -> Void)?
    /// New, open, save, duplicate and revert, which the project document runs.
    @ObservationIgnored public weak var projectActions: (any ProjectActions)?
    /// Opens media in a new project window instead of this one. Returns true when it did.
    @ObservationIgnored public var openMediaElsewhere: (@MainActor (URL) -> Bool)?
    /// The commands this editor may run; nil for all. The stand-in editor used
    /// while no project window is open allows only new and open.
    @ObservationIgnored public var allowedCommandIDs: Set<String>?
    /// Called as an AI tool starts, so an untitled project can be saved first and keep its results.
    @ObservationIgnored public var aiToolWillStart: (@MainActor () -> Void)?
    /// Where the project's video is; kept while the video is missing, so saving does not lose it.
    @ObservationIgnored var mediaReference: MediaReference?
    /// The video's file name when the project's video could not be found.
    public internal(set) var missingMediaName: String?
    /// Asks where a project's missing video went. Tests replace it.
    @ObservationIgnored public var locateMissingMedia: @MainActor (_ fileName: String) -> URL? = EditorPanels.locateMissingMedia(fileName:)
    /// Analyses of the video kept in the project, so reopening it reads nothing again.
    @ObservationIgnored var storedAnalysis = StoredAnalysis()
    /// Transcribers' raw words kept in the project, so transcribing again uploads nothing.
    @ObservationIgnored var storedTranscripts: [StoredTranscript] = []
    /// True while a project's contents are put in place, which is no change to save.
    @ObservationIgnored var isLoadingProject = false
    /// The media a project opened, whose arrival is no change to save; and where its playhead was.
    @ObservationIgnored var projectMediaURL: URL?
    @ObservationIgnored var projectPlayhead: MediaTime?

    /// The open media's waveform, filled in while it is being read.
    public private(set) var audioAnalysis: AudioAnalysis?
    /// Where people speak in the waveform's audio, filled in while detected.
    public private(set) var speech: [SpeechRegion]?
    /// The open media's shot changes, filled in while they are being found.
    public private(set) var shotChanges: [MediaTime]? {
        didSet { if shotChanges != oldValue, qcPreset.shotChangeFrames != nil { updateIssues() } }
    }
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

    /// The text subtitle tracks muxed into the open media, once read. Image-based
    /// tracks (PGS, VobSub) are left out: they cannot be imported.
    public private(set) var embeddedSubtitles: [EmbeddedSubtitleTrack] = []
    /// Whether the sheet offering to import one of `embeddedSubtitles` is shown.
    public private(set) var isEmbeddedSubtitlesSheetShown = false
    /// How far reading the chosen embedded track has got, nil when not reading.
    public private(set) var embeddedSubtitlesJob: AnalysisJob?
    @ObservationIgnored private var embeddedSubtitlesTask: Task<Void, Never>?
    /// Lists and reads the media's subtitle tracks off the main actor. Tests replace them.
    @ObservationIgnored public var listEmbeddedSubtitles: @Sendable (URL) async throws -> [EmbeddedSubtitleTrack] = { url in
        try await EditorState.runDetached { try MediaAnalyzer.subtitleTracks(in: url) }
    }
    @ObservationIgnored public var readEmbeddedSubtitles:
        @Sendable (URL, Int, @escaping @Sendable (MediaAnalyzer.Progress<Int>) -> Void) async throws -> SubtitleTrack =
        { url, streamIndex, progress in
            try await EditorState.runDetached {
                try MediaAnalyzer.subtitles(in: url, streamIndex: streamIndex) { report in
                    progress(report)
                    return !Task.isCancelled
                }
            }
        }
    /// The media files whose embedded subtitles were offered, so the offer shows once per file.
    static let offeredEmbeddedSubtitlesKey = "OfferedEmbeddedSubtitles"

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
    /// True while the translator notes are being typed, so the typing undoes as one step.
    @ObservationIgnored var translatorNotesSession = false

    /// Asks the user for a media file. Tests replace it.
    @ObservationIgnored public var chooseMedia: @MainActor () -> URL? = EditorPanels.chooseMedia
    /// Asks the user for a subtitle file to import. Tests replace it.
    @ObservationIgnored public var chooseSubtitlesToImport: @MainActor () -> URL? = EditorPanels.chooseSubtitles
    /// Asks the user where to export, suggesting the current file. Tests replace it.
    @ObservationIgnored public var chooseExportDestination: @MainActor (SubtitleFileReference?) -> SubtitleFileReference? =
        EditorPanels.chooseExportDestination(suggesting:)
    /// Asks whether to export unsaved subtitles before new media replaces them. Tests replace it.
    @ObservationIgnored public var confirmReplacingSubtitles: @MainActor () -> ReplaceSubtitlesChoice =
        EditorPanels.confirmReplacingSubtitles
    /// Asks whether to clear the transcript, saying what goes with it. Tests replace it.
    @ObservationIgnored public var confirmClearingTranscript: @MainActor (_ clearsTranslation: Bool) -> Bool =
        EditorPanels.confirmClearingTranscript(clearsTranslation:)
    /// Asks whether to translate while cues still have words the transcription was unsure of. Tests replace it.
    @ObservationIgnored public var confirmTranslatingUnsureCues: @MainActor (_ count: Int) -> UnsureTranscriptChoice =
        EditorPanels.confirmTranslatingUnsureCues(count:)
    /// Shows a failed import or export to the user. Tests replace it.
    @ObservationIgnored public var reportError: @MainActor (_ title: String, _ error: any Error) -> Void = EditorPanels.showError

    public init(
        launchOptions: LaunchOptions = .current,
        playback: any PlaybackEngine,
        frameRate: FrameRate = .fps23_976,
        track: SubtitleTrack = SubtitleTrack(),
        settings: UserDefaults? = nil,
        translationStore: TranslationStore? = nil
    ) {
        self.launchOptions = launchOptions
        self.playback = playback
        self.status = playback.status
        self.position = playback.status.position
        self.frameRate = frameRate
        self.track = track
        self.settings = settings
        self.translationStore = translationStore
        self.qcPreset = settings?.string(forKey: Self.qcPresetKey).flatMap(QCPreset.named) ?? .standard
        self.aiSettings = AISettings.load(from: settings)
        self.aiProviders = launchOptions.isUITestMode ? .scripted : .live()
        self.undoManager = UndoManager()
        updateIssues()
        // One undo step per edit, also where no run loop groups events (unit tests).
        undoManager.groupsByEvent = false
        playback.onStatusChange = { [weak self] status in self?.playbackDidChange(status) }
        if !launchOptions.usesAnalysisCache {
            analyzeWaveform = Self.waveformAnalyzer(cache: nil)
            analyzeSpeech = Self.speechAnalyzer(cache: nil)
            analyzeShotChanges = Self.shotChangeAnalyzer(cache: nil)
            prepareAudio = Self.audioPreparer(cache: nil)
        }
        if let url = launchOptions.mediaURL { open(url) }
        if let url = launchOptions.subtitlesURL {
            importSubtitles(from: url)
            undoManager.removeAllActions()
            refreshUndoState()
        }
        if let url = launchOptions.sourceSubtitlesURL {
            openSourceSubtitles(from: url)
            undoManager.removeAllActions()
            refreshUndoState()
            hasUnsavedChanges = false
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
        // UI tests start from the default preset, an empty glossary and an empty memory every time.
        self.init(
            launchOptions: launchOptions, playback: player, settings: testMode ? nil : .standard,
            translationStore: testMode ? nil : .standard
        )
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

    /// The cues shown on the frame under the playhead: at most one at the
    /// bottom and one at the top (a sign over dialogue).
    public var cuesAtPlayhead: [Cue] {
        guard hasMedia else { return [] }
        let time = currentTime
        return CuePosition.allCases.compactMap { position in
            track.cues.last { $0.position == position && $0.start <= time && time < $0.end }
        }
    }

    // MARK: - Commands

    public func canPerform(_ command: EditorCommand) -> Bool {
        if let allowedCommandIDs, !allowedCommandIDs.contains(command.id) { return false }
        return switch command.id {
        case EditorCommand.newProject.id, EditorCommand.openProject.id, EditorCommand.saveProject.id,
             EditorCommand.duplicateProject.id, EditorCommand.revertProject.id, EditorCommand.browseProjectVersions.id:
            projectActions?.canPerform(command, projectURL: projectURL) ?? false
        case EditorCommand.openMedia.id, EditorCommand.importSubtitles.id, EditorCommand.exportSubtitles.id,
             EditorCommand.addCue.id:
            true
        case EditorCommand.importEmbeddedSubtitles.id:
            hasMedia && !embeddedSubtitles.isEmpty
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
        case EditorCommand.fixOverlaps.id:
            issues.values.contains { $0.contains { $0.kind.isTimingConflict } }
        case EditorCommand.joinShortLines.id:
            track.cues.count > 1 && pendingReview == nil && aiTask == nil
        case EditorCommand.toggleMilliseconds.id, EditorCommand.toggleIssuesPanel.id:
            true
        case EditorCommand.openSourceSubtitles.id:
            true
        case EditorCommand.addNamesToGlossary.id:
            isTranslating && !namesMissingFromGlossary.isEmpty
        case EditorCommand.closeSourceSubtitles.id, EditorCommand.addTranslationsToMemory.id, EditorCommand.showGlossary.id,
             EditorCommand.importGlossary.id:
            isTranslating
        case EditorCommand.copySourceToTarget.id:
            selectedCue.flatMap { sourceCues[$0.id] } != nil
        case EditorCommand.useMemoryMatch.id:
            selectedCue.map { !memoryMatches(for: $0.id).isEmpty } ?? false
        case EditorCommand.fillExactMatches.id:
            isTranslating && !memory.entries.isEmpty
        case EditorCommand.transcribe.id, EditorCommand.translateWithAI.id, EditorCommand.reviewChoices.id, EditorCommand.acceptRemainingChoices.id,
             EditorCommand.clearTranslation.id, EditorCommand.clearTranscript.id, EditorCommand.reviewWords.id, EditorCommand.confirmRemainingWords.id,
             EditorCommand.maskProfanity.id, EditorCommand.removeHearingImpaired.id, EditorCommand.fixPunctuation.id,
             EditorCommand.cancelAITask.id, EditorCommand.acceptChange.id, EditorCommand.rejectChange.id,
             EditorCommand.acceptAllChanges.id, EditorCommand.rejectAllChanges.id:
            canPerformAI(command)
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
        case EditorCommand.goToEnd.id:
            hasMedia && status.duration != nil
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
        case EditorCommand.toggleIssuesPanel.id: isIssuesPanelShown
        case EditorCommand.reviewChoices.id: isReviewingChoices
        case EditorCommand.reviewWords.id: isReviewingWords
        case EditorCommand.togglePositionTop.id: selectedCue.map { $0.position == .top }
        default: nil
        }
    }

    /// Runs `command`. Returns false when it is unknown or not currently possible.
    @discardableResult
    public func perform(_ command: EditorCommand) -> Bool {
        guard canPerform(command) else { return false }
        switch command.id {
        case EditorCommand.newProject.id, EditorCommand.openProject.id, EditorCommand.saveProject.id,
             EditorCommand.duplicateProject.id, EditorCommand.revertProject.id, EditorCommand.browseProjectVersions.id:
            return projectActions?.perform(command) ?? false
        case EditorCommand.openMedia.id:
            if let url = chooseMedia() { open(url) }
        case EditorCommand.importSubtitles.id:
            if let url = chooseSubtitlesToImport() { importSubtitles(from: url) }
        case EditorCommand.importEmbeddedSubtitles.id:
            isEmbeddedSubtitlesSheetShown = true
        case EditorCommand.exportSubtitles.id:
            if let destination = chooseExportDestination(subtitleFile ?? suggestedTranslationFile) { exportSubtitles(to: destination) }
        case EditorCommand.undo.id:
            endTextEditSession()
            undoManager.undo()
            refreshUndoState()
        case EditorCommand.redo.id:
            endTextEditSession()
            undoManager.redo()
            refreshUndoState()
        case EditorCommand.addCue.id:
            return addCueAtPlayhead()
        case EditorCommand.fixOverlaps.id:
            fixOverlaps()
        case EditorCommand.joinShortLines.id:
            let proposal = joinProposal { _ in true }
            guard !proposal.isEmpty else {
                reportError("\(EditorCommand.joinShortLines.title) found nothing to join.", AIError.nothingToDo("No two neighbouring cues fit in one."))
                return false
            }
            presentReview(proposal)
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
        case EditorCommand.toggleIssuesPanel.id:
            isIssuesPanelShown.toggle()
        case EditorCommand.openSourceSubtitles.id:
            if let url = chooseSubtitlesToImport() { openSourceSubtitles(from: url) }
        case EditorCommand.closeSourceSubtitles.id:
            closeSourceSubtitles()
        case EditorCommand.copySourceToTarget.id:
            guard let cue = selectedCue, let source = sourceCues[cue.id] else { return false }
            replaceText(of: cue.id, with: source.text, actionName: EditorCommand.copySourceToTarget.title)
        case EditorCommand.useMemoryMatch.id:
            guard let cue = selectedCue, let match = memoryMatches(for: cue.id).first else { return false }
            useMemoryMatch(match, forCue: cue.id)
        case EditorCommand.fillExactMatches.id:
            return fillExactMatches()
        case EditorCommand.addTranslationsToMemory.id:
            addTranslationsToMemory()
        case EditorCommand.addNamesToGlossary.id:
            let names = namesMissingFromGlossary
            guard !names.isEmpty else { return false }
            glossary.merge(names.map { Glossary.Entry(source: $0.name, target: $0.translatedName ?? "", note: "Name") })
        case EditorCommand.showGlossary.id:
            showGlossaryPanel(self)
        case EditorCommand.importGlossary.id:
            if let url = chooseGlossaryToImport() { importGlossary(from: url) }
        case EditorCommand.transcribe.id, EditorCommand.translateWithAI.id, EditorCommand.reviewChoices.id, EditorCommand.acceptRemainingChoices.id,
             EditorCommand.clearTranslation.id, EditorCommand.clearTranscript.id, EditorCommand.reviewWords.id, EditorCommand.confirmRemainingWords.id,
             EditorCommand.maskProfanity.id, EditorCommand.removeHearingImpaired.id, EditorCommand.fixPunctuation.id,
             EditorCommand.cancelAITask.id, EditorCommand.acceptChange.id, EditorCommand.rejectChange.id,
             EditorCommand.acceptAllChanges.id, EditorCommand.rejectAllChanges.id:
            return performAI(command)
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
            playbackStopTime = nil
            if isPlaying { playback.setPaused(true) } else { playback.play(rate: 1) }
        case EditorCommand.stepForward.id:
            playback.step(by: 1)
        case EditorCommand.stepBackward.id:
            playback.step(by: -1)
        case EditorCommand.goToStart.id:
            playback.setPaused(true)
            playback.seek(toFrame: 0, rate: frameRate)
        case EditorCommand.goToEnd.id:
            guard let duration = status.duration else { return false }
            playback.setPaused(true)
            playback.seek(toFrame: max(duration.nearestFrame(at: frameRate) - 1, 0), rate: frameRate)
        default:
            return false
        }
        return true
    }

    // MARK: - Media and files

    /// Opens a media file. Replacing open media starts over: the subtitles,
    /// the translation source, undo, the selection and the analysis belong to
    /// the old media. Unsaved subtitles can be exported first, or the open cancelled.
    /// Subtitles imported before any media opens are kept for it.
    public func open(_ url: URL) {
        if let openMediaElsewhere, openMediaElsewhere(url) { return }
        if hasMedia {
            if hasUnsavedChanges, !track.cues.isEmpty, !launchOptions.isUITestMode {
                switch confirmReplacingSubtitles() {
                case .export:
                    guard let destination = chooseExportDestination(subtitleFile ?? suggestedTranslationFile) else { return }
                    exportSubtitles(to: destination)
                    guard !hasUnsavedChanges else { return }
                case .discard:
                    break
                case .cancel:
                    return
                }
            }
            resetForNewMedia()
        }
        playback.load(url)
    }

    /// Forgets everything that belongs to the open media. View preferences
    /// (zoom, QC preset, snapping, time display) and the glossary and memory stay.
    func resetForNewMedia() {
        isEditingText = false
        endTextEditSession()
        shuttleRate = 0
        selectedCueID = nil
        isReviewingChoices = false
        isReviewingWords = false
        playbackStopTime = nil
        track = SubtitleTrack()
        subtitleFile = nil
        if sourceTrack != nil { closeSourceSubtitles() }
        undoManager.removeAllActions()
        refreshUndoState()
        hasUnsavedChanges = false
        // What the project kept about the old media.
        storedAnalysis = StoredAnalysis()
        storedTranscripts = []
        mediaReference = nil
        missingMediaName = nil
        projectPlayhead = nil
        // Cleared now, not when the new media loads, so nothing of the old media shows meanwhile.
        cancelAnalysis()
        embeddedSubtitlesTask?.cancel()
        embeddedSubtitles = []
        embeddedSubtitlesJob = nil
        isEmbeddedSubtitlesSheetShown = false
        scrollTimeline(toCenter: 0)
    }

    /// Replaces the cues with the file's. Undoable; reports errors through `reportError`.
    public func importSubtitles(from url: URL) {
        do {
            let (format, imported) = try SubtitleFile.read(from: url)
            replaceTrack(with: imported)
            subtitleFile = SubtitleFileReference(url: url, format: format)
            hasUnsavedChanges = false
        } catch {
            reportError("“\(url.lastPathComponent)” could not be imported.", error)
        }
    }

    /// Replaces the working track with an imported one, linking its cues to the source's in translation mode.
    private func replaceTrack(with imported: SubtitleTrack) {
        let source = sourceTrack
        edit("Import Subtitles") { track in
            track.cues = source.map { Alignment.link(imported.cues, to: $0.cues) } ?? imported.cues
            track.styles = imported.styles
            track.properties = imported.properties
            track.languageCode = imported.languageCode
        }
        selectedCueID = nil
        // Proposals were made for the cues that were replaced.
        pendingReview = nil
    }

    public func exportSubtitles(to destination: SubtitleFileReference) {
        do {
            try SubtitleFile.write(track, as: destination.format, frameRate: frameRate, to: destination.url)
            // A delivered translation is a reviewed one: remember it.
            if isTranslating { addTranslationsToMemory() }
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
        // Leaving a translated cue stores it, so the rest of the file can reuse it.
        if let previous = selectedCueID { recordTranslation(of: previous) }
        selectedCueID = id
        // A proposed new cue is not in the track yet, but can be selected to review it.
        if let cue = selectedCue ?? id.flatMap({ pendingReview?.change(forCue: $0)?.cue }), hasMedia {
            playback.seek(toFrame: cue.start.firstFrame(at: frameRate), rate: frameRate)
        }
    }

    /// Selects the previous or next cue. While typing, the cursor moves to its text.
    private func selectNeighbour(offset: Int) {
        // While reviewing choices, the neighbours are the flagged cues in the list's order.
        let cues = isReviewingChoices ? cuesToChoose : track.cues
        guard !cues.isEmpty else { return }
        let current = selectedCueID.flatMap { id in cues.firstIndex { $0.id == id } }
        let index = current.map { $0 + offset } ?? (offset > 0 ? 0 : cues.count - 1)
        guard cues.indices.contains(index) else { return }
        let keepTyping = isEditingText
        select(cues[index].id)
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

    // MARK: - Quality control

    /// Checks cues against another preset.
    public func selectQCPreset(id: QCPreset.ID) {
        if let preset = QCPreset.named(id) { qcPreset = preset }
    }

    /// Every issue in cue order, for the issues panel.
    public var issueList: [IssueListItem] {
        track.cues.enumerated().flatMap { index, cue in
            (issues[cue.id] ?? []).enumerated().map { offset, issue in
                IssueListItem(cueID: cue.id, cueNumber: index + 1, start: cue.start, offset: offset, issue: issue)
            }
        }
    }

    /// Recomputes `issues`; it changes (and redraws its observers) only when the result differs.
    private func updateIssues() {
        let context = QualityControl.Context(frameRate: frameRate, shotChanges: shotChangeFrames)
        var found = QualityControl.check(track.cues, preset: qcPreset, context: context)
        addTranslationIssues(to: &found)
        if found != issues { issues = found }
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
        let position = cueID.flatMap(cue(withID:))?.position
        for cue in track.cues where cue.id != cueID {
            // Cues in the same position are neighbours: snap to the minimum gap from them.
            let gap = cue.position == position ? minimumGap : .zero
            targets.append(cue.start - gap)
            targets.append(cue.end + gap)
        }
        return targets
    }

    /// The QC preset's minimum gap at the current rate.
    public var minimumGap: MediaTime { MediaTime(frame: qcPreset.minimumGapFrames, rate: frameRate) }

    /// How far a cue can reach without overlapping its neighbours in the same
    /// position, keeping the minimum gap: from the previous one's end to the
    /// next one's start. A top cue may overlap bottom cues and the other way round.
    public func room(for id: Cue.ID) -> (earliestStart: MediaTime, latestEnd: MediaTime?) {
        guard let index = track.cues.firstIndex(where: { $0.id == id }) else { return (.zero, nil) }
        let cue = track.cues[index]
        let previous = track.cues[..<index].last { $0.position == cue.position }
        let next = track.cues[(index + 1)...].first { $0.position == cue.position }
        return (previous.map { $0.end + minimumGap } ?? .zero, next.map { $0.start - minimumGap })
    }

    // MARK: - Editing

    /// Sets a cue's start and end in one undoable step (a timeline drag or nudge).
    /// Clamped to the cue's room (see `room(for:)`), so edits never create overlaps.
    public func setTiming(start: MediaTime, end: MediaTime, forCue id: Cue.ID, actionName: String) {
        let room = room(for: id)
        let start = max(start, room.earliestStart, .zero)
        let end = room.latestEnd.map { min(end, $0) } ?? end
        guard start < end, let index = track.cues.firstIndex(where: { $0.id == id }) else { return }
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
            // Edited by hand: no longer the AI's text, and the choice between its variants is made.
            track.cues[index].isAIGenerated = nil
            // A word edited out of the text was the one to fix; the others still need checking.
            track.cues[index].unsureWords = Self.words(track.cues[index].unsureWords, in: text)
            if track.cues[index].flag?.isResolved == false { track.cues[index].flag?.isResolved = true }
        }
        textEditCueID = id
    }

    /// Adds a bottom cue at the playhead, or just after the cue already showing
    /// there. Returns false when there is no room before the next cue.
    private func addCueAtPlayhead() -> Bool {
        var start = currentTime
        let bottom = track.cues.filter { $0.position == .bottom }
        if let showing = bottom.last(where: { $0.start <= start && start < $0.end + minimumGap }) {
            start = MediaTime(frame: (showing.end + minimumGap).firstFrame(at: frameRate), rate: frameRate)
        }
        let newCueFrames = MediaTime(value: Self.newCueSeconds, timescale: 1).nearestFrame(at: frameRate)
        var end = start + MediaTime(frame: newCueFrames, rate: frameRate)
        if let next = bottom.first(where: { $0.start > start }) {
            end = min(end, next.start - minimumGap)
        }
        guard start < end else { return false }
        let cue = Cue(start: start, end: end, text: "")
        edit("Add Cue") { track in
            track.cues.append(cue)
        }
        selectedCueID = cue.id
        textFocusRequest += 1
        return true
    }

    /// Ends each cue that overlaps the next one in the same position, or ends
    /// too close to it, the minimum gap before it.
    private func fixOverlaps() {
        edit(EditorCommand.fixOverlaps.title) { track in
            for index in track.cues.indices {
                let cue = track.cues[index]
                guard let next = track.cues[(index + 1)...].first(where: { $0.position == cue.position }),
                      next.start < cue.end
                        || next.start.firstFrame(at: frameRate) - cue.end.firstFrame(at: frameRate) < qcPreset.minimumGapFrames
                else { continue }
                let withGap = next.start - minimumGap
                track.cues[index].end = withGap > cue.start ? withGap : next.start
            }
        }
    }

    /// New cues last two seconds, or until the next cue starts.
    static let newCueSeconds: Int64 = 2

    /// Splits the selected cue at the playhead when it is inside the cue, else in the middle.
    private func splitSelectedCue() -> Bool {
        guard let id = selectedCueID else { return false }
        return splitCue(id, at: hasMedia ? currentTime : nil)
    }

    /// Splits a cue at `time` when it is at least a frame inside the cue, else in the middle.
    /// Two or more lines split between lines; one line splits at the word nearest its middle.
    func splitCue(_ id: Cue.ID, at time: MediaTime?) -> Bool {
        guard let index = track.cues.firstIndex(where: { $0.id == id }) else { return false }
        let cue = track.cues[index]
        let oneFrame = MediaTime(frame: 1, rate: frameRate)
        var at = time ?? cue.start
        if !(cue.start + oneFrame <= at && at + oneFrame <= cue.end) {
            let middle = cue.start + MediaTime(value: (cue.duration.value), timescale: cue.duration.timescale * 2)
            at = middle.snapped(to: frameRate)
        }
        guard cue.start < at, at < cue.end else { return false }
        let (firstText, secondText) = Self.splitText(cue.text)
        var first = cue
        first.end = at
        first.text = firstText
        // Variants are whole lines; they no longer fit either half.
        first.flag = nil
        first.unsureWords = Self.words(cue.unsureWords, in: firstText)
        // Both halves still translate the same source cue and share its speaker; a cue
        // joined from several source cues gives the first ones to the first half.
        var second = Cue(
            start: at, end: cue.end, text: secondText, position: cue.position, style: cue.style, speaker: cue.speaker,
            sourceCueID: cue.sourceCueID, voices: cue.voices, unsureWords: Self.words(cue.unsureWords, in: secondText)
        )
        if let joined = cue.joinedSourceCueIDs, !joined.isEmpty, let sourceID = cue.sourceCueID {
            let ids = [sourceID] + joined
            let half = (ids.count + 1) / 2
            first.joinedSourceCueIDs = ids.count > 2 && half > 1 ? Array(ids[1..<half]) : nil
            second.sourceCueID = ids[half]
            second.joinedSourceCueIDs = ids.count - half > 1 ? Array(ids[(half + 1)...]) : nil
        }
        edit("Split Cue") { track in
            track.cues[index] = first
            track.cues.insert(second, at: index + 1)
        }
        return true
    }

    /// The ones of `words` that `text` still has, nil when none.
    static func words(_ words: [UnsureWord]?, in text: String) -> [UnsureWord]? {
        let kept = (words ?? []).filter { text.localizedCaseInsensitiveContains($0.text) }
        return kept.isEmpty ? nil : kept
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
        if let id = selectedCueID { mergeWithNext(id) }
    }

    /// Joins a cue and the next one: their lines, until the later end.
    func mergeWithNext(_ id: Cue.ID) {
        guard let index = track.cues.firstIndex(where: { $0.id == id }), index + 1 < track.cues.count else { return }
        let next = track.cues[index + 1]
        edit("Merge Cues") { track in
            var merged = track.cues[index]
            merged.end = max(merged.end, next.end)
            merged.text = [merged.text, next.text].filter { !$0.isEmpty }.joined(separator: "\n")
            merged.flag = nil
            let unsure = (merged.unsureWords ?? []) + (next.unsureWords ?? [])
            merged.unsureWords = unsure.isEmpty ? nil : unsure
            let voices = (merged.voices ?? []) + (next.voices ?? []).filter { !(merged.voices ?? []).contains($0) }
            merged.voices = voices.isEmpty ? nil : voices
            merged.joinSources(of: next)
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
        if let next = track.cues[(index + 1)...].first(where: { $0.position == .bottom }) {
            end = min(end, next.start - gap)
        }
        guard start < end else { return }
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
        if let id = selectedCueID { deleteCue(id) }
    }

    /// Deletes a cue. When it was selected, the cue that takes its place is.
    func deleteCue(_ id: Cue.ID) {
        guard let index = track.cues.firstIndex(where: { $0.id == id }) else { return }
        edit("Delete Cue") { track in
            track.cues.remove(at: index)
        }
        guard selectedCueID == id else { return }
        let cues = track.cues
        selectedCueID = cues.isEmpty ? nil : cues[min(index, cues.count - 1)].id
    }

    /// Moves the selected cue's start to the playhead. When that passes the
    /// cue's end, the cue keeps its duration.
    /// Moves the selected cue's start to the playhead. Past the cue's end it keeps
    /// its duration (shortened to fit before the next cue). Never overlaps a neighbour.
    private func setInAtPlayhead() -> Bool {
        guard let index = selectedCueIndex, track.cues[index].start != currentTime else { return false }
        let cue = track.cues[index]
        let room = room(for: cue.id)
        let time = currentTime
        guard time >= room.earliestStart, room.latestEnd.map({ time < $0 }) ?? true else { return false }
        var end = time >= cue.end ? time + cue.duration : cue.end
        if let latest = room.latestEnd { end = min(end, latest) }
        edit("Set In") { track in
            track.cues[index].start = time
            track.cues[index].end = end
        }
        return true
    }

    /// Moves the selected cue's end to the playhead, which must be after its start.
    private func setOutAtPlayhead() -> Bool {
        guard let index = selectedCueIndex else { return false }
        let cue = track.cues[index]
        let time = currentTime
        guard cue.start < time, cue.end != time, room(for: cue.id).latestEnd.map({ time <= $0 }) ?? true else { return false }
        edit("Set Out") { track in
            track.cues[index].end = time
        }
        return true
    }

    /// Applies one undoable change to the track and keeps cues ordered by start time.
    /// With `coalescing`, the change joins the previous undo step.
    func edit(_ actionName: String, coalescing: Bool = false, _ change: (inout SubtitleTrack) -> Void) {
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
        projectDidChange?(.edit)
    }

    /// Like `edit(_:_:)`, for a change that also replaces the translation source and
    /// the transcripts the project keeps (Clear Transcript). One undo step puts all of them back.
    func editIncludingSources(_ actionName: String, _ change: (inout SubtitleTrack, inout SourceState) -> Void) {
        let before = Snapshot(track: track, selectedCueID: selectedCueID, sources: sourceState)
        var edited = track
        var sources = sourceState
        change(&edited, &sources)
        edited.cues.sort { $0.start < $1.start }
        guard edited != track || sources != sourceState else { return }
        endTextEditSession()
        registerUndo(restoring: before, actionName: actionName)
        apply(sources)
        track = edited
        if let selected = selectedCueID, cue(withID: selected) == nil { selectedCueID = nil }
        hasUnsavedChanges = true
        refreshUndoState()
        projectDidChange?(.edit)
    }

    /// What a translation is made from, and the transcribers' words the project keeps.
    struct SourceState: Equatable {
        var sourceTrack: SubtitleTrack?
        var sourceFile: SubtitleFileReference?
        var transcripts: [StoredTranscript]
    }

    var sourceState: SourceState {
        SourceState(sourceTrack: sourceTrack, sourceFile: sourceFile, transcripts: storedTranscripts)
    }

    private func apply(_ sources: SourceState) {
        storedTranscripts = sources.transcripts
        sourceFile = sources.sourceFile
        sourceTrack = sources.sourceTrack
    }

    private struct Snapshot {
        var track: SubtitleTrack
        var selectedCueID: Cue.ID?
        /// Set by edits that also change the source and the kept transcripts.
        var sources: SourceState?
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
        let change: ProjectChange = undoManager.isUndoing ? .undo : .redo
        registerUndo(
            restoring: Snapshot(track: track, selectedCueID: selectedCueID, sources: snapshot.sources.map { _ in sourceState }),
            actionName: actionName
        )
        if let sources = snapshot.sources { apply(sources) }
        track = snapshot.track
        selectedCueID = snapshot.selectedCueID
        if snapshot.sources != nil { translationPairDidChange() }
        hasUnsavedChanges = true
        projectDidChange?(change)
    }

    private func endTextEditSession() {
        textEditCueID = nil
        translatorNotesSession = false
    }

    func refreshUndoState() {
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
        // A word played for checking stops just after it.
        if let stop = playbackStopTime, status.position >= stop {
            playbackStopTime = nil
            if !status.isPaused { playback.setPaused(true) }
        }
        let atStart = !status.hasMedia || status.position.nearestFrame(at: frameRate) <= 0
        if atStart != isAtStart { isAtStart = atStart }
        if status.audioTracks != audioTracks { audioTracks = status.audioTracks }
        if status.selectedAudioTrackID != selectedAudioTrackID { selectedAudioTrackID = status.selectedAudioTrackID }
        // Analyze again when the player switches to another audio track than the waveform shows.
        let audioTrackChanged = status.audioStreamIndex.map { $0 != analyzedAudioStream } ?? false
        if mediaChanged {
            mediaDidOpen()
            findEmbeddedSubtitles()
            startWaveformAnalysis()
            startShotChangeAnalysis()
        } else if audioTrackChanged {
            startWaveformAnalysis()
        }
    }

    // MARK: - Embedded subtitles

    /// Lists the new media's text subtitle tracks, and offers them the first time a file opens.
    private func findEmbeddedSubtitles() {
        embeddedSubtitlesTask?.cancel()
        embeddedSubtitles = []
        embeddedSubtitlesJob = nil
        isEmbeddedSubtitlesSheetShown = false
        guard let url = status.mediaURL else { return }
        let list = listEmbeddedSubtitles
        embeddedSubtitlesTask = Task { [weak self] in
            let tracks = ((try? await list(url)) ?? []).filter(\.isText)
            guard let self, !Task.isCancelled, self.status.mediaURL == url else { return }
            self.embeddedSubtitles = tracks
            // A project that has cues already has its subtitles.
            if !tracks.isEmpty, self.track.cues.isEmpty || self.projectURL == nil, self.markEmbeddedSubtitlesOffered(for: url) {
                self.isEmbeddedSubtitlesSheetShown = true
            }
        }
    }

    /// Records that the file's subtitles were offered. False when they had been already.
    private func markEmbeddedSubtitlesOffered(for url: URL) -> Bool {
        guard let settings else { return true }
        var offered = settings.stringArray(forKey: Self.offeredEmbeddedSubtitlesKey) ?? []
        guard !offered.contains(url.path) else { return false }
        offered.append(url.path)
        settings.set(Array(offered.suffix(500)), forKey: Self.offeredEmbeddedSubtitlesKey)
        return true
    }

    /// Replaces the cues with an embedded track's (undoable), then closes the
    /// sheet. With `savesCopy`, asks where to save them as a file next.
    public func importEmbeddedSubtitles(streamIndex: Int, savesCopy: Bool) {
        guard let url = status.mediaURL, embeddedSubtitlesJob == nil,
              let embedded = embeddedSubtitles.first(where: { $0.streamIndex == streamIndex }), embedded.isText
        else { return }
        embeddedSubtitlesJob = AnalysisJob()
        let read = readEmbeddedSubtitles
        let report: @Sendable (MediaAnalyzer.Progress<Int>) -> Void = { [weak self] progress in
            guard let editor = self else { return }
            Task { @MainActor in
                guard editor.status.mediaURL == url, let next = editor.embeddedSubtitlesJob?.advanced(by: progress) else { return }
                editor.embeddedSubtitlesJob = next
            }
        }
        embeddedSubtitlesTask = Task { [weak self] in
            let result: Result<SubtitleTrack, any Error>
            do { result = .success(try await read(url, streamIndex, report)) } catch { result = .failure(error) }
            guard let self, !Task.isCancelled, self.status.mediaURL == url else { return }
            self.embeddedSubtitlesJob = nil
            switch result {
            case .success(let imported):
                self.isEmbeddedSubtitlesSheetShown = false
                self.replaceTrack(with: imported)
                self.subtitleFile = nil
                self.hasUnsavedChanges = true
                if savesCopy, let format = embedded.fileFormat {
                    let language = imported.languageCode == "und" ? "" : ".\(imported.languageCode)"
                    let name = url.deletingPathExtension().lastPathComponent + language + "." + format.fileExtension
                    let suggestion = SubtitleFileReference(url: url.deletingLastPathComponent().appending(path: name), format: format)
                    if let destination = self.chooseExportDestination(suggestion) { self.exportSubtitles(to: destination) }
                }
            case .failure(let error):
                self.reportError("“\(embedded.displayName)” could not be imported.", error)
            }
        }
    }

    /// Closes the embedded subtitles sheet, stopping a running import.
    public func dismissEmbeddedSubtitles() {
        if embeddedSubtitlesJob != nil {
            embeddedSubtitlesTask?.cancel()
            embeddedSubtitlesJob = nil
        }
        isEmbeddedSubtitlesSheetShown = false
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

    func cancelAnalysis() {
        for task in [waveformTask, speechTask, shotChangesTask] { task?.cancel() }
        audioAnalysis = nil
        speech = nil
        shotChanges = nil
        waveformJob = nil
        speechJob = nil
        shotChangesJob = nil
        analyzedAudioStream = nil
    }

    /// Starts the waveform and speech jobs for the playing audio track.
    func startWaveformAnalysis() {
        startSpeechAnalysis()
        waveformTask?.cancel()
        audioAnalysis = nil
        waveformJob = nil
        analyzedAudioStream = status.audioStreamIndex
        guard let url = status.mediaURL else { return }
        let stream = status.audioStreamIndex
        if let stored = storedAnalysis.waveforms[StoredAnalysis.key(forStream: stream)] {
            audioAnalysis = stored
            analyzedAudioStream = stored.audioStreamIndex
            return
        }
        waveformJob = AnalysisJob()
        let analyze = analyzeWaveform
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
                self.storedAnalysis.waveforms[StoredAnalysis.key(forStream: stream)] = result
            }
            self.waveformJob = nil
        }
    }

    private func startSpeechAnalysis() {
        speechTask?.cancel()
        speech = nil
        speechJob = nil
        guard let url = status.mediaURL else { return }
        let stream = status.audioStreamIndex
        if let stored = storedAnalysis.speech[StoredAnalysis.key(forStream: stream)] {
            speech = stored
            return
        }
        speechJob = AnalysisJob()
        let analyze = analyzeSpeech
        let report: @Sendable (MediaAnalyzer.Progress<[SpeechRegion]>) -> Void = { [weak self] progress in
            guard let editor = self else { return }
            Task { @MainActor in editor.speechDidProgress(progress, for: url) }
        }
        speechTask = Task { [weak self] in
            let result = try? await analyze(url, stream, report)
            guard let self, !Task.isCancelled, self.status.mediaURL == url else { return }
            if let result {
                self.speech = result
                self.storedAnalysis.speech[StoredAnalysis.key(forStream: stream)] = result
            }
            self.speechJob = nil
        }
    }

    private func speechDidProgress(_ progress: MediaAnalyzer.Progress<[SpeechRegion]>, for url: URL) {
        guard status.mediaURL == url, let job = speechJob, let next = job.advanced(by: progress) else { return }
        speechJob = next
        if let partial = progress.partial { speech = partial }
    }

    func startShotChangeAnalysis() {
        shotChangesTask?.cancel()
        shotChanges = nil
        shotChangesJob = nil
        guard let url = status.mediaURL else { return }
        if let stored = storedAnalysis.shotChanges {
            shotChanges = stored
            return
        }
        shotChangesJob = AnalysisJob()
        let analyze = analyzeShotChanges
        let report: @Sendable (MediaAnalyzer.Progress<[MediaTime]>) -> Void = { [weak self] progress in
            guard let editor = self else { return }
            Task { @MainActor in editor.shotChangesDidProgress(progress, for: url) }
        }
        shotChangesTask = Task { [weak self] in
            let result = try? await analyze(url, report)
            guard let self, !Task.isCancelled, self.status.mediaURL == url else { return }
            if let result {
                self.shotChanges = result
                self.storedAnalysis.shotChanges = result
            }
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
    nonisolated static func runDetached<Result: Sendable>(
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

/// One row of the issues panel.
public struct IssueListItem: Identifiable, Hashable, Sendable {
    public var cueID: Cue.ID
    /// 1-based, as the cue list shows it.
    public var cueNumber: Int
    public var start: MediaTime
    /// The issue's place among its cue's issues.
    public var offset: Int
    public var issue: QCIssue

    public var id: String { "\(cueID.uuidString).\(offset)" }
}

extension QCIssue.Kind {
    /// Overlaps and short gaps, which Fix Overlaps and Gaps repairs.
    var isTimingConflict: Bool {
        switch self {
        case .overlapsNext, .gapTooShort: true
        default: false
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

/// What to do with unsaved subtitles when new media replaces them.
/// What to do when translating while the transcription has words to check.
public enum UnsureTranscriptChoice: Sendable {
    /// Show the cues to check first.
    case review
    case translateAnyway
    case cancel
}

public enum ReplaceSubtitlesChoice: Sendable {
    case export
    case discard
    case cancel
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

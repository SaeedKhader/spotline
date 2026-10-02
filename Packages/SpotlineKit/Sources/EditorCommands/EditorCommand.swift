/// A named user action.
///
/// Menus, keyboard shortcuts, toolbar buttons, UI tests and AI agents all run
/// the same commands, so anything a person can do is scriptable by ID.
public struct EditorCommand: Identifiable, Hashable, Sendable {
    /// Stable dotted identifier, e.g. "playback.stepForward". Treat as public API.
    public let id: String
    public let title: String
    public let category: Category
    public let defaultShortcut: KeyShortcut?

    public enum Category: String, Sendable, CaseIterable {
        case file
        case playback
        /// Undo and redo.
        case editing
        /// Creating and changing cues.
        case cue
        case navigation
        /// Timeline zoom, snapping and speech highlight (in the View menu).
        case timeline
        /// How things are displayed.
        case view
        /// Quality control: stepping through issues and fixing them.
        case review
        /// Translating from a source track: glossary and translation memory.
        case translation
        /// AI tools: transcription and translation fill the track, and the lines
        /// a translation flagged are reviewed here; cleanup proposes changes, reviewed here too.
        case ai
    }

    public init(id: String, title: String, category: Category, defaultShortcut: KeyShortcut? = nil) {
        self.id = id
        self.title = title
        self.category = category
        self.defaultShortcut = defaultShortcut
    }
}

extension EditorCommand {
    /// A new project window (docs/ARCHITECTURE.md, section 5: `.spotline` projects).
    public static let newProject = EditorCommand(
        id: "file.newProject", title: "New Project", category: .file,
        defaultShortcut: KeyShortcut(.character("n"), modifiers: .command)
    )
    public static let openProject = EditorCommand(
        id: "file.openProject", title: "Open Project…", category: .file,
        defaultShortcut: KeyShortcut(.character("o"), modifiers: [.command, .control])
    )
    /// Saves the project, asking where the first time. Projects also save themselves as you work.
    public static let saveProject = EditorCommand(
        id: "file.saveProject", title: "Save Project…", category: .file,
        defaultShortcut: KeyShortcut(.character("s"), modifiers: .command)
    )
    public static let duplicateProject = EditorCommand(
        id: "file.duplicateProject", title: "Duplicate Project", category: .file,
        defaultShortcut: KeyShortcut(.character("s"), modifiers: [.command, .shift])
    )
    /// Goes back to the project as it was last saved on purpose (⌘S), or when it was opened.
    public static let revertProject = EditorCommand(
        id: "file.revertProject", title: "Revert to Last Saved Version", category: .file
    )
    /// Shows earlier versions of the project, as Time Machine does, to restore one.
    public static let browseProjectVersions = EditorCommand(
        id: "file.browseProjectVersions", title: "Browse All Versions…", category: .file
    )
    public static let openMedia = EditorCommand(
        id: "file.openMedia", title: "Open Media…", category: .file,
        defaultShortcut: KeyShortcut(.character("o"), modifiers: .command)
    )
    public static let importSubtitles = EditorCommand(
        id: "file.importSubtitles", title: "Import Subtitles…", category: .file,
        defaultShortcut: KeyShortcut(.character("o"), modifiers: [.command, .shift])
    )
    /// Offers the subtitle tracks muxed into the open media for import.
    public static let importEmbeddedSubtitles = EditorCommand(
        id: "file.importEmbeddedSubtitles", title: "Import Embedded Subtitles…", category: .file
    )
    public static let exportSubtitles = EditorCommand(
        id: "file.exportSubtitles", title: "Export Subtitles…", category: .file,
        defaultShortcut: KeyShortcut(.character("e"), modifiers: [.command, .shift])
    )
    public static let undo = EditorCommand(
        id: "editing.undo", title: "Undo", category: .editing,
        defaultShortcut: KeyShortcut(.character("z"), modifiers: .command)
    )
    public static let redo = EditorCommand(
        id: "editing.redo", title: "Redo", category: .editing,
        defaultShortcut: KeyShortcut(.character("z"), modifiers: [.command, .shift])
    )
    public static let addCue = EditorCommand(
        id: "cue.addAtPlayhead", title: "Add Cue at Playhead", category: .cue,
        defaultShortcut: KeyShortcut(.character("n"), modifiers: [.command, .shift])
    )
    public static let deleteCue = EditorCommand(
        id: "cue.delete", title: "Delete Cue", category: .cue,
        defaultShortcut: KeyShortcut(.delete, modifiers: .command)
    )
    public static let setIn = EditorCommand(
        id: "cue.setInAtPlayhead", title: "Set In at Playhead", category: .cue,
        defaultShortcut: KeyShortcut(.character("i"))
    )
    public static let setOut = EditorCommand(
        id: "cue.setOutAtPlayhead", title: "Set Out at Playhead", category: .cue,
        defaultShortcut: KeyShortcut(.character("o"))
    )
    /// No cue selected. In the cue list, Esc runs it once the text is left (the first Esc leaves
    /// the text); it has no menu shortcut, which would take that first Esc from the text.
    public static let deselectCue = EditorCommand(
        id: "navigation.deselectCue", title: "Deselect Cue", category: .navigation
    )
    public static let previousCue = EditorCommand(
        id: "navigation.previousCue", title: "Select Previous Cue", category: .navigation,
        defaultShortcut: KeyShortcut(.upArrow, modifiers: .command)
    )
    public static let nextCue = EditorCommand(
        id: "navigation.nextCue", title: "Select Next Cue", category: .navigation,
        defaultShortcut: KeyShortcut(.downArrow, modifiers: .command)
    )
    public static let splitCue = EditorCommand(
        id: "cue.split", title: "Split Cue", category: .cue,
        defaultShortcut: KeyShortcut(.character("s"), modifiers: [.command, .option])
    )
    public static let mergeWithNext = EditorCommand(
        id: "cue.mergeWithNext", title: "Merge with Next Cue", category: .cue,
        defaultShortcut: KeyShortcut(.character("j"), modifiers: [.command, .option])
    )
    /// A toggle: on when the selected cue is shown at the top.
    public static let togglePositionTop = EditorCommand(
        id: "cue.togglePositionTop", title: "Show Cue at Top", category: .cue,
        defaultShortcut: KeyShortcut(.character("t"), modifiers: [.command, .option])
    )
    /// Trims cues that overlap the next one in the same position, or end closer to it than the QC preset's gap.
    public static let fixOverlaps = EditorCommand(
        id: "cue.fixOverlaps", title: "Fix Overlaps and Short Gaps", category: .review
    )
    /// Joins short cues and sentences split over two cues, as a subtitler would
    /// (`CueJoiner`), proposed as changes to review.
    public static let joinShortLines = EditorCommand(
        id: "cue.joinShortLines", title: "Join Short Lines", category: .review
    )
    /// Steps through the review sidebar's cards under its filter.
    public static let previousIssue = EditorCommand(
        id: "navigation.previousIssue", title: "Previous Cue to Review", category: .review,
        defaultShortcut: KeyShortcut(.upArrow, modifiers: [.command, .option])
    )
    public static let nextIssue = EditorCommand(
        id: "navigation.nextIssue", title: "Next Cue to Review", category: .review,
        defaultShortcut: KeyShortcut(.downArrow, modifiers: [.command, .option])
    )
    /// The review sidebar lists everything to review again, leaving a filter.
    public static let showAllCues = EditorCommand(
        id: "review.showAll", title: "Review Everything", category: .review
    )
    /// A toggle: the review sidebar lists only the cues with QC issues. See `EditorState.isOn(_:)`.
    public static let toggleIssuesPanel = EditorCommand(
        id: "review.toggleIssuesPanel", title: "Review Issues", category: .review,
        defaultShortcut: KeyShortcut(.character("i"), modifiers: [.command, .option])
    )
    /// A toggle: the review sidebar right of the video, where every kind of review is decided
    /// (also the button at the right end of the title bar).
    public static let toggleReviewSidebar = EditorCommand(
        id: "view.toggleReview", title: "Show Review", category: .view,
        defaultShortcut: KeyShortcut(.character("0"), modifiers: [.command, .option])
    )
    /// A toggle: the review sidebar lists only the cues with frame issues (shot changes, gaps).
    public static let reviewFrames = EditorCommand(
        id: "review.reviewFrames", title: "Review Frame Issues", category: .review
    )
    public static let shuttleBackward = EditorCommand(
        id: "playback.shuttleBackward", title: "Shuttle Backward", category: .playback,
        defaultShortcut: KeyShortcut(.character("j"))
    )
    /// J and L play backward and forward, faster with each press; K pauses.
    public static let pause = EditorCommand(
        id: "playback.pause", title: "Pause", category: .playback,
        defaultShortcut: KeyShortcut(.character("k"))
    )
    public static let shuttleForward = EditorCommand(
        id: "playback.shuttleForward", title: "Shuttle Forward", category: .playback,
        defaultShortcut: KeyShortcut(.character("l"))
    )
    /// A toggle: see `EditorState.isOn(_:)`.
    public static let toggleMilliseconds = EditorCommand(
        id: "view.toggleMilliseconds", title: "Show Timecodes in Milliseconds", category: .view
    )
    public static let previousShotChange = EditorCommand(
        id: "navigation.previousShotChange", title: "Go to Previous Shot Change", category: .playback,
        defaultShortcut: KeyShortcut(.leftArrow, modifiers: .option)
    )
    public static let nextShotChange = EditorCommand(
        id: "navigation.nextShotChange", title: "Go to Next Shot Change", category: .playback,
        defaultShortcut: KeyShortcut(.rightArrow, modifiers: .option)
    )
    public static let zoomIn = EditorCommand(
        id: "timeline.zoomIn", title: "Zoom In", category: .timeline,
        defaultShortcut: KeyShortcut(.character("="), modifiers: .command)
    )
    public static let zoomOut = EditorCommand(
        id: "timeline.zoomOut", title: "Zoom Out", category: .timeline,
        defaultShortcut: KeyShortcut(.character("-"), modifiers: .command)
    )
    /// A toggle: see `EditorState.isOn(_:)`.
    public static let toggleSnapping = EditorCommand(
        id: "timeline.toggleSnapping", title: "Snap to Shot Changes and Cues", category: .timeline
    )
    public static let nextAudioTrack = EditorCommand(
        id: "playback.nextAudioTrack", title: "Next Audio Track", category: .playback,
        defaultShortcut: KeyShortcut(.character("a"), modifiers: [.command, .option])
    )
    /// A toggle: see `EditorState.isOn(_:)`.
    public static let toggleSpeechHighlight = EditorCommand(
        id: "timeline.toggleSpeechHighlight", title: "Highlight Speech in Waveform", category: .timeline
    )
    public static let togglePlay = EditorCommand(
        id: "playback.togglePlay", title: "Play/Pause", category: .playback,
        defaultShortcut: KeyShortcut(.space)
    )
    public static let stepForward = EditorCommand(
        id: "playback.stepForward", title: "Step Forward One Frame", category: .playback,
        defaultShortcut: KeyShortcut(.rightArrow)
    )
    public static let stepBackward = EditorCommand(
        id: "playback.stepBackward", title: "Step Backward One Frame", category: .playback,
        defaultShortcut: KeyShortcut(.leftArrow)
    )
    public static let goToStart = EditorCommand(
        id: "playback.goToStart", title: "Go to Start", category: .playback,
        defaultShortcut: KeyShortcut(.leftArrow, modifiers: .command)
    )
    /// Pauses on the media's last frame.
    public static let goToEnd = EditorCommand(
        id: "playback.goToEnd", title: "Go to End", category: .playback,
        defaultShortcut: KeyShortcut(.rightArrow, modifiers: .command)
    )

    public static let openSourceSubtitles = EditorCommand(
        id: "translation.openSource", title: "Open Source Subtitles…", category: .translation,
        defaultShortcut: KeyShortcut(.character("o"), modifiers: [.command, .option])
    )
    public static let closeSourceSubtitles = EditorCommand(
        id: "translation.closeSource", title: "Close Source Subtitles", category: .translation
    )
    /// Replaces the selected cue's text with its source cue's (names, numbers, signs).
    public static let copySourceToTarget = EditorCommand(
        id: "translation.copySource", title: "Copy Source to Target", category: .translation,
        defaultShortcut: KeyShortcut(.character("c"), modifiers: [.command, .option])
    )
    /// Uses the translation memory's best suggestion for the selected cue.
    public static let useMemoryMatch = EditorCommand(
        id: "translation.useMemoryMatch", title: "Use Best Memory Match", category: .translation,
        defaultShortcut: KeyShortcut(.character("m"), modifiers: [.command, .control])
    )
    /// Fills every untranslated cue that has an exact (100%) memory match, as one edit.
    public static let fillExactMatches = EditorCommand(
        id: "translation.fillExactMatches", title: "Fill Untranslated Cues from Memory", category: .translation
    )
    /// Stores every translated cue with its source in the translation memory.
    /// Adds how the translation spells each person's name to the glossary, so the
    /// next episodes spell them the same.
    public static let addNamesToGlossary = EditorCommand(
        id: "translation.addNamesToGlossary", title: "Add Names to Glossary", category: .translation
    )
    public static let addTranslationsToMemory = EditorCommand(
        id: "translation.addToMemory", title: "Add All Translations to Memory", category: .translation
    )
    public static let showGlossary = EditorCommand(
        id: "translation.showGlossary", title: "Show Glossary", category: .translation,
        defaultShortcut: KeyShortcut(.character("g"), modifiers: [.command, .option])
    )
    /// Adds terms from a CSV or tab-separated file (source, target, note).
    public static let importGlossary = EditorCommand(
        id: "translation.importGlossary", title: "Import Glossary…", category: .translation
    )

    /// Makes cues from the media's dialogue straight into the gaps of the track.
    public static let transcribe = EditorCommand(
        id: "ai.transcribe", title: "Transcribe Audio", category: .ai,
        defaultShortcut: KeyShortcut(.character("r"), modifiers: [.command, .control])
    )
    /// Fills the empty target cues with context, glossary and memory.
    /// Outside translation mode the current cues become the source first.
    public static let translateWithAI = EditorCommand(
        id: "ai.translate", title: "Translate with AI", category: .ai,
        defaultShortcut: KeyShortcut(.character("t"), modifiers: [.command, .control])
    )
    /// Empties every target cue: text, flagged choices and AI tint go; timing and
    /// source links stay, so Translate with AI can fill them again. One edit.
    public static let clearTranslation = EditorCommand(
        id: "ai.clearTranslation", title: "Clear Translation", category: .ai
    )
    /// Removes the transcribed cues (the source in translation mode, with the
    /// translation made from it) and the transcripts the project keeps, so the next
    /// Transcribe Audio asks the transcriber again. Asks first; one edit.
    /// Who is who in the episode and how names are spelled, built after transcription:
    /// opens it to confirm or edit, or builds one when there is none.
    public static let showEpisodeBrief = EditorCommand(
        id: "ai.episodeBrief", title: "Episode Brief…", category: .ai,
        defaultShortcut: KeyShortcut(.character("b"), modifiers: [.command, .control])
    )
    /// Builds the episode brief again from the transcript, replacing the one there (about 4 cents).
    public static let rebuildEpisodeBrief = EditorCommand(
        id: "ai.rebuildEpisodeBrief", title: "Build Episode Brief Again", category: .ai
    )
    /// The few frames of each scene that show who is there, picked on this Mac for a vision
    /// model to describe: opens them, picking them the first time. Nothing is sent anywhere.
    public static let showSceneFrames = EditorCommand(
        id: "ai.sceneFrames", title: "Scene Frames…", category: .ai
    )
    /// Picks the scene frames again, after the lines changed.
    public static let pickSceneFramesAgain = EditorCommand(
        id: "ai.pickSceneFramesAgain", title: "Pick Scene Frames Again", category: .ai
    )
    /// Writes the picked frames and a list of them with each scene's lines to a folder.
    public static let exportSceneFrames = EditorCommand(
        id: "ai.exportSceneFrames", title: "Export Scene Frames…", category: .ai
    )
    /// Reviews the transcript with the confirmed episode brief, flagging lines that look
    /// wrong with fixes to try. Runs by itself when the brief is first confirmed.
    public static let reviewScriptWithAI = EditorCommand(
        id: "ai.reviewScript", title: "Review Script with AI", category: .ai
    )
    /// A toggle: the review sidebar lists only the lines the AI script review flagged.
    public static let reviewScriptFindings = EditorCommand(
        id: "ai.reviewScriptFindings", title: "Review AI Fixes", category: .ai
    )
    public static let clearTranscript = EditorCommand(
        id: "ai.clearTranscript", title: "Clear Transcript…", category: .ai
    )
    /// A toggle: the review sidebar lists only the lines AI translation could translate
    /// more than one way, each with its variants to pick from.
    public static let reviewChoices = EditorCommand(
        id: "ai.reviewChoices", title: "Review Translation Choices", category: .ai,
        defaultShortcut: KeyShortcut(.character("v"), modifiers: [.command, .control])
    )
    /// Keeps the recommended variant of every line not yet decided, as one edit.
    public static let acceptRemainingChoices = EditorCommand(
        id: "ai.acceptRemainingChoices", title: "Accept Remaining Choices", category: .ai
    )
    /// A toggle: the review sidebar lists only the words the transcriber was unsure of.
    public static let reviewWords = EditorCommand(
        id: "ai.reviewWords", title: "Review Words to Check", category: .ai,
        defaultShortcut: KeyShortcut(.character("w"), modifiers: [.command, .control])
    )
    /// Keeps every word still to check as it is, as one edit.
    public static let confirmRemainingWords = EditorCommand(
        id: "ai.confirmRemainingWords", title: "Confirm Remaining Words", category: .ai
    )
    public static let maskProfanity = EditorCommand(id: "ai.maskProfanity", title: "Mask Profanity", category: .ai)
    public static let removeHearingImpaired = EditorCommand(id: "ai.removeHearingImpaired", title: "Remove Hearing-Impaired Text", category: .ai)
    public static let fixPunctuation = EditorCommand(id: "ai.fixPunctuation", title: "Fix Spacing and Punctuation", category: .ai)
    /// Stops the running AI task; what it already filled in stays (and undoes).
    public static let cancelAITask = EditorCommand(
        id: "ai.cancel", title: "Cancel AI Task", category: .ai,
        defaultShortcut: KeyShortcut(.character("."), modifiers: .command)
    )
    /// Applies the proposed change to the selected cue and selects the next cue with a change.
    public static let acceptChange = EditorCommand(
        id: "ai.acceptChange", title: "Accept Change", category: .ai,
        defaultShortcut: KeyShortcut(.returnKey, modifiers: .command)
    )
    /// Drops the proposed change to the selected cue and selects the next cue with a change.
    public static let rejectChange = EditorCommand(
        id: "ai.rejectChange", title: "Reject Change", category: .ai,
        defaultShortcut: KeyShortcut(.delete, modifiers: [.command, .option])
    )
    /// Applies every proposed change as one undoable edit.
    public static let acceptAllChanges = EditorCommand(
        id: "ai.acceptAll", title: "Accept All Changes", category: .ai,
        defaultShortcut: KeyShortcut(.returnKey, modifiers: [.command, .option])
    )
    /// A toggle: the review sidebar lists only the changes an AI tool proposes.
    public static let reviewChanges = EditorCommand(
        id: "ai.reviewChanges", title: "Review AI Changes", category: .ai
    )
    public static let rejectAllChanges = EditorCommand(
        id: "ai.rejectAll", title: "Reject All Changes", category: .ai,
        defaultShortcut: KeyShortcut(.delete, modifiers: [.command, .option, .shift])
    )

    /// Every command the app knows, in menu order.
    public static let all: [EditorCommand] = [
        newProject, openProject, saveProject, duplicateProject, revertProject, browseProjectVersions,
        openMedia, importSubtitles, importEmbeddedSubtitles, exportSubtitles,
        undo, redo,
        addCue, deleteCue, setIn, setOut, splitCue, mergeWithNext, togglePositionTop,
        previousCue, nextCue, deselectCue, previousShotChange, nextShotChange,
        showAllCues, toggleIssuesPanel, reviewFrames, previousIssue, nextIssue, fixOverlaps, joinShortLines,
        zoomIn, zoomOut, toggleSnapping, toggleSpeechHighlight,
        togglePlay, shuttleBackward, pause, shuttleForward, stepBackward, stepForward, goToStart, goToEnd, nextAudioTrack,
        toggleMilliseconds, toggleReviewSidebar,
        openSourceSubtitles, closeSourceSubtitles, copySourceToTarget, useMemoryMatch, fillExactMatches,
        addTranslationsToMemory, addNamesToGlossary, showGlossary, importGlossary,
        transcribe, translateWithAI, showEpisodeBrief, rebuildEpisodeBrief, showSceneFrames, pickSceneFramesAgain, exportSceneFrames, reviewScriptWithAI, reviewScriptFindings, clearTranslation, clearTranscript, reviewWords, confirmRemainingWords, reviewChoices, acceptRemainingChoices, maskProfanity, removeHearingImpaired, fixPunctuation, cancelAITask,
        reviewChanges, acceptChange, rejectChange, acceptAllChanges, rejectAllChanges,
    ]

    public static func named(_ id: String) -> EditorCommand? {
        all.first { $0.id == id }
    }
}

/// A UI-framework-neutral key binding.
public struct KeyShortcut: Hashable, Sendable {
    public enum Key: Hashable, Sendable {
        case character(Character)
        case space
        case leftArrow
        case rightArrow
        case upArrow
        case downArrow
        case returnKey
        case delete
        case escape
    }

    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
    }

    public let key: Key
    public let modifiers: Modifiers

    public init(_ key: Key, modifiers: Modifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    /// True when a text field uses this key for typing or moving the cursor
    /// (letters, Space, arrows, Delete, including with Command). Menus turn
    /// these shortcuts off while the user edits text, so typing "i" inserts
    /// an "i" instead of setting the in-point.
    public var conflictsWithTextEditing: Bool {
        switch key {
        // Command-Up/Down move between cues, which is useful while typing;
        // in a two-line editor the text system barely needs them.
        case .upArrow, .downArrow: !modifiers.contains(.command)
        case .leftArrow, .rightArrow, .delete: true
        case .character, .space, .returnKey, .escape: modifiers.isDisjoint(with: [.command, .control])
        }
    }
}

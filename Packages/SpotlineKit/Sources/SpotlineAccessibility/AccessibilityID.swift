import Foundation

/// Every accessibility identifier the app exposes, in one place.
///
/// UI tests, automation scripts and AI agents find controls by these IDs, so
/// treat them as public API: add new ones freely, never rename existing ones
/// casually, and never use string literals for identifiers in views.
public enum AccessibilityID {
    /// The button (or other control) that runs an editor command, keyed by command ID.
    public static func command(_ commandID: String) -> String { "command.\(commandID)" }

    public enum Video {
        public static let surface = "video.surface"
        /// The subtitle shown over the video (at the bottom); its value is the cue's visible text.
        public static let subtitle = "video.subtitle"
        /// A cue shown at the top of the picture, e.g. a sign over dialogue.
        public static let topSubtitle = "video.subtitle.top"
        /// The hint shown before any media is open.
        public static let emptyState = "video.empty"
    }

    /// The editing strip above the mini-map (In and Out, add, split, merge, delete, snapping, zoom).
    public enum ActionsBar {
        public static let root = "actionsBar"
    }

    /// The strip under the video: timecode, transport buttons and frame rate.
    public enum Transport {
        public static let root = "transport"
        public static let timecode = "transport.timecode"
        public static let frameRate = "transport.frameRate"
        /// Media analysis state: "Analyzing 40%", or the number of shot changes found.
        public static let analysis = "transport.analysis"
    }

    public enum Timeline {
        public static let root = "timeline"
        /// Its value is the playhead's timecode.
        public static let playhead = "timeline.playhead"
        /// A cue block; its value is "<in> – <out>".
        public static func cue(_ cueID: UUID) -> String { "timeline.cue.\(cueID.uuidString)" }
        /// Draggable, adjustable edges of a cue block (increment moves one frame later).
        public static func inHandle(_ cueID: UUID) -> String { "\(cue(cueID)).inHandle" }
        public static func outHandle(_ cueID: UUID) -> String { "\(cue(cueID)).outHandle" }
        /// The n-th shot change marker (0-based); its value is its timecode.
        public static func shotChange(_ index: Int) -> String { "timeline.shotChange.\(index)" }
    }

    /// The cue list, where each row is also the cue's editor.
    public enum CueList {
        public static let root = "cueList"
        public static func row(_ cueID: UUID) -> String { "cueList.row.\(cueID.uuidString)" }
        /// One field of a cue's row, e.g. `cueList.row.<id>.text` (the text editor).
        public static func cell(_ cueID: UUID, _ column: Column) -> String { "\(row(cueID)).\(column.rawValue)" }
        /// A row's button for an editor command, e.g. `cueList.row.<id>.command.cue.delete`.
        public static func action(_ cueID: UUID, _ commandID: String) -> String { "\(row(cueID)).\(command(commandID))" }
        /// The review sidebar's "All" filter chip; its value is e.g. "12 to review".
        public static let allScope = "cueList.all"
        /// The review sidebar's Issues filter chip; its value is e.g. "7 cues need review".
        public static let reviewSummary = "cueList.review"
        /// The hint shown while there are no cues; its value says what to do first.
        public static let emptyState = "cueList.empty"
        /// In translation mode, the n-th glossary term found in a cue's source (0-based);
        /// its value is the agreed translation and whether the target uses it.
        public static func glossaryTerm(_ cueID: UUID, _ index: Int) -> String { "\(row(cueID)).glossary.\(index)" }
        /// The n-th translation memory suggestion under the selected cue (0-based); its value is the suggested text.
        public static func memoryMatch(_ cueID: UUID, _ index: Int) -> String { "\(row(cueID)).memory.\(index)" }
        /// The AI activity in the title bar while an AI tool runs, and for a few seconds after.
        public static let aiBar = "cueList.ai"
        /// The running AI tool; its value is e.g. "Transcription: Uploading 6.1 of 18 MB".
        public static let aiTask = "cueList.ai.task"
        /// What the last AI tool did, for a few seconds after; its value is e.g. "2 lines translated · 1 flagged".
        public static let aiSummary = "cueList.ai.summary"
        /// Over a row whose line a translator is working on now.
        public static func inFlight(_ cueID: UUID) -> String { "\(row(cueID)).inFlight" }
        /// The review sidebar's AI Changes filter chip; its value is e.g. "Fix Spacing and Punctuation: 12 changes to review".
        public static let aiReview = "cueList.ai.review"
        /// A cue an AI tool proposes to add, shown between the real rows until accepted or rejected (in the review sidebar).
        public static func proposedRow(_ cueID: UUID) -> String { "cueList.proposed.\(cueID.uuidString)" }
        /// A proposed cue's field, e.g. `cueList.proposed.<id>.text`.
        public static func proposedCell(_ cueID: UUID, _ column: Column) -> String { "\(proposedRow(cueID)).\(column.rawValue)" }
        /// The review sidebar's Frames filter chip: how many cues are too close to a shot change or the next cue.
        public static let framesSummary = "cueList.frames"
        /// The review sidebar's Choices filter chip: how many lines still read more than one way.
        public static let choicesSummary = "cueList.choices"
        /// The AI Review chip: lines the AI script review flagged.
        public static let scriptSummary = "cueList.script"
        /// The review sidebar's Words filter chip: how many words the transcriber was unsure of.
        public static let wordsSummary = "cueList.words"

        public enum Column: String, CaseIterable, Sendable {
            case number
            case inPoint = "in"
            case outPoint = "out"
            case readingSpeed = "cps"
            /// Who says the line, when known; the value is the names.
            case speaker
            /// The button that shows the cue at the top or bottom; its value is "top" or "bottom".
            case position
            /// Review warnings; the value lists them.
            case issues
            /// The dot beside the number of a cue with something to review; its value names the kinds.
            case review
            case text
            /// In translation mode, the source cue's text (read-only).
            case source
            /// A row hover action listing the variants of a line whose choice is made.
            case variantsMenu
        }
    }

    /// The glossary panel (Translation › Show Glossary).
    public enum Glossary {
        public static let root = "glossary"
        public static let addEntry = "glossary.add"
        public static let removeEntries = "glossary.remove"
        /// The notes for the AI translator under the terms.
        public static let translatorNotes = "glossary.translatorNotes"
        /// One term's field: `glossary.entry.<id>.source`, `.target` or `.note`.
        public static func field(_ entryID: UUID, _ field: Field) -> String { "glossary.entry.\(entryID.uuidString).\(field.rawValue)" }

        public enum Field: String, CaseIterable, Sendable {
            case source, target, note
        }
    }

    /// QC issues, reviewed in the review sidebar's Issues filter (Review › Review Issues).
    public enum Issues {
        /// The QC preset's name, in the review sidebar while its Issues filter is on; its help explains the limits.
        public static let preset = "issues.preset"
    }

    /// The review sidebar right of the video (View › Show Review): a card per thing to decide.
    public enum Review {
        public static let root = "review"
        /// Shown when nothing is left under the filter.
        public static let emptyState = "review.empty"
        /// The "Show settled" checkbox.
        public static let showSettled = "review.showSettled"
        /// The note after a decision, with Undo; its value says what was decided.
        public static let undoNote = "review.undo"
        public static let undoButton = "review.undo.button"
        /// One card, by `ReviewItem.id` ("<cue id>.choice", "<cue id>.word.0.Duncan", "<cue id>.change",
        /// "<cue id>.issues"); its label is the kind and cue number, its value what to decide.
        /// Selected while it is the current card.
        public static func card(_ itemID: String) -> String { "review.card.\(itemID)" }
        /// A card's button: `accept`, `reject`, `confirm`, `keep`, `edit`, `play`, `ignore` (a reading speed no fix can bring down), or `done` while editing in the card.
        public static func action(_ itemID: String, _ action: Action) -> String { "\(card(itemID)).\(action.rawValue)" }
        /// The n-th reading (0-based) on a choice card; its label says who it assumes,
        /// its value is its text, and it is selected when in use.
        public static func variant(_ itemID: String, _ index: Int) -> String { "\(card(itemID)).variant.\(index)" }
        /// The n-th (0-based) suggested fix on an issue card; its label says what it does,
        /// its value what the text becomes, for text fixes.
        public static func suggestion(_ itemID: String, _ index: Int) -> String { "\(card(itemID)).suggestion.\(index)" }
        /// The n-th (0-based) fix on an AI Review card; its label says how sure the review is,
        /// its value is the line as it would read, and it is selected while it is in the line.
        public static func fix(_ itemID: String, _ index: Int) -> String { "\(card(itemID)).fix.\(index)" }
        /// The cue's text, edited in its card (after Fix, Edit or E); its value is the text.
        public static func text(_ itemID: String) -> String { "\(card(itemID)).text" }
        /// The title bar button that shows and hides the sidebar; its value is how many things are left to review.
        public static let toggle = "review.toggle"
        /// A settled card, while Show settled is on; its value says how it was settled.
        public static func settled(_ itemID: String) -> String { "review.settled.\(itemID)" }

        public enum Action: String, CaseIterable, Sendable {
            case accept, reject, confirm, keep, edit, play, done, ignore
        }
    }

    /// Settings › AI.
    public enum AISettings {
        public static let transcriptionProvider = "settings.ai.transcription"
        public static let transcriptionLanguage = "settings.ai.language"
        public static let translationProvider = "settings.ai.translation"
        public static let reasoningEffort = "settings.ai.reasoningEffort"
        public static let allowsCloud = "settings.ai.allowsCloud"
        public static func apiKey(_ provider: String) -> String { "settings.ai.key.\(provider)" }
        /// Beside a key field; its value is "saved" once the Keychain has the key.
        public static func apiKeySaved(_ provider: String) -> String { "\(apiKey(provider)).saved" }
        /// Shown when a chosen cloud provider can't run yet (cloud off, or no key); its value says why.
        public static let providerProblem = "settings.ai.problem"
        public static let joinsLines = "settings.ai.joinsLines"
        public static let soundDescriptions = "settings.ai.soundDescriptions"
        public static let leavesOutWalla = "settings.ai.leavesOutWalla"
        public static let leavesOutFictionalLanguages = "settings.ai.leavesOutFictionalLanguages"
        public static let register = "settings.ai.register"
        public static let dropsFinalPunctuation = "settings.ai.dropsFinalPunctuation"
        public static let namesInParentheses = "settings.ai.namesInParentheses"
    }

    /// Settings › Agents.
    public enum AgentSettings {
        public static let enabled = "settings.agents.enabled"
        /// Its value says whether agents can connect.
        public static let status = "settings.agents.status"
        public static let claudeCodeCommand = "settings.agents.claudeCode"
        public static let copyClaudeCodeCommand = "settings.agents.claudeCode.copy"
        public static let claudeDesktopConfig = "settings.agents.claudeDesktop"
        public static let copyClaudeDesktopConfig = "settings.agents.claudeDesktop.copy"
    }

    /// The sheet offering the subtitle tracks muxed into the media for import.
    /// The question whether to move a subtitle file's cues onto the audio (AI › Sync Subtitles to Audio…).
    public enum Sync {
        public static let apply = "sync.apply"
        public static let leave = "sync.leave"
    }

    /// The episode brief dialog (AI › Episode Brief…).
    public enum Brief {
        public static let sheet = "brief"
        /// One person's row, by `EpisodeBrief.Person.id`; its value is the voices and how sure the brief is.
        public static func person(_ id: UUID) -> String { "brief.person.\(id.uuidString)" }
        public static func name(_ id: UUID) -> String { "\(person(id)).name" }
        public static func gender(_ id: UUID) -> String { "\(person(id)).gender" }
        /// The name as the target language spells it.
        public static func spelling(_ id: UUID) -> String { "\(person(id)).spelling" }
        /// Plays the person's first line.
        public static func play(_ id: UUID) -> String { "\(person(id)).play" }
        /// Merge into another person, or remove.
        public static func menu(_ id: UUID) -> String { "\(person(id)).menu" }
        /// One term's row, by `EpisodeBrief.Term.id`.
        public static func term(_ id: UUID) -> String { "brief.term.\(id.uuidString)" }
        public static func termText(_ id: UUID) -> String { "\(term(id)).text" }
        public static func termTranslation(_ id: UUID) -> String { "\(term(id)).translation" }
        public static func termNote(_ id: UUID) -> String { "\(term(id)).note" }
        /// The term's Add to glossary checkbox.
        public static func termGlossary(_ id: UUID) -> String { "\(term(id)).glossary" }
        public static func removeTerm(_ id: UUID) -> String { "\(term(id)).remove" }
        public static let addTerm = "brief.addTerm"
        /// The plot, as editable text.
        public static let plot = "brief.plot"
        /// Scene by scene, who talks to whom, as editable text.
        public static let scenes = "brief.scenes"
        public static let confirmButton = "brief.confirm"
        public static let notNowButton = "brief.notNow"
        /// In the review sidebar while the review waits for the brief.
        public static let waiting = "review.briefWaiting"
    }

    public enum EmbeddedSubtitles {
        public static let sheet = "embeddedSubtitles"
        /// One text track's row, by FFmpeg stream index; selected when chosen.
        public static func track(_ streamIndex: Int) -> String { "embeddedSubtitles.track.\(streamIndex)" }
        public static let saveCopy = "embeddedSubtitles.saveCopy"
        public static let importButton = "embeddedSubtitles.import"
        public static let cancelButton = "embeddedSubtitles.cancel"
        /// Shown while the chosen track is read.
        public static let progress = "embeddedSubtitles.progress"
    }

    /// The overview strip of the whole media between the actions bar and the timeline.
    public enum MiniMap {
        public static let root = "miniMap"
    }
}

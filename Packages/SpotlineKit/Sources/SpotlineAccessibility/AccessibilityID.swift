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

    /// The actions bar above the timeline (transport, editing buttons, timecode).
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
        /// The count of cues that need review, in the actions bar; its value is e.g. "7 cues need review".
        public static let reviewSummary = "cueList.review"
        /// The hint shown while there are no cues; its value says what to do first.
        public static let emptyState = "cueList.empty"
        /// In translation mode, the n-th glossary term found in a cue's source (0-based);
        /// its value is the agreed translation and whether the target uses it.
        public static func glossaryTerm(_ cueID: UUID, _ index: Int) -> String { "\(row(cueID)).glossary.\(index)" }
        /// The n-th translation memory suggestion under the selected cue (0-based); its value is the suggested text.
        public static func memoryMatch(_ cueID: UUID, _ index: Int) -> String { "\(row(cueID)).memory.\(index)" }
        /// The bar over the cue list while an AI tool runs or its changes wait for review.
        public static let aiBar = "cueList.ai"
        /// The running AI tool; its value is e.g. "Transcription: Uploading 6.1 of 18 MB".
        public static let aiTask = "cueList.ai.task"
        /// What the last AI tool did, for a few seconds after; its value is e.g. "2 lines translated · 1 flagged".
        public static let aiSummary = "cueList.ai.summary"
        /// Over a row whose line a translator is working on now.
        public static func inFlight(_ cueID: UUID) -> String { "\(row(cueID)).inFlight" }
        /// Proposed AI changes waiting for review; its value is e.g. "Transcription: 12 changes".
        public static let aiReview = "cueList.ai.review"
        /// A cue an AI tool proposes to add, shown between the real rows until accepted or rejected.
        public static func proposedRow(_ cueID: UUID) -> String { "cueList.proposed.\(cueID.uuidString)" }
        /// A proposed cue's field, e.g. `cueList.proposed.<id>.text`.
        public static func proposedCell(_ cueID: UUID, _ column: Column) -> String { "\(proposedRow(cueID)).\(column.rawValue)" }
        /// The accept or reject button of a proposed change, keyed by `ai.acceptChange` or `ai.rejectChange`.
        public static func reviewAction(_ cueID: UUID, _ commandID: String) -> String { "cueList.review.\(cueID.uuidString).\(command(commandID))" }
        /// One variant (0-based) of a line that reads more than one way; its label says who it
        /// assumes, its value is its text, and it is selected when in use.
        public static func variant(_ cueID: UUID, _ index: Int) -> String { "\(cell(cueID, .choices)).\(index)" }
        /// Over the cue list while it shows only the lines to choose for; its value explains the review.
        public static let choiceReview = "cueList.choiceReview"
        /// In the actions bar: how many lines still read more than one way; it opens the review.
        public static let choicesSummary = "cueList.choices"
        /// In the actions bar: how many words the transcriber was unsure of; it opens their review.
        public static let wordsSummary = "cueList.words"
        /// Over the cue list while it shows only the cues with words to check; its value explains the review.
        public static let wordReview = "cueList.wordReview"
        /// The n-th word to check in a cue (0-based); its value is the word and how sure the transcriber was.
        public static func word(_ cueID: UUID, _ index: Int) -> String { "\(cell(cueID, .words)).\(index)" }
        /// Plays the n-th word to check.
        public static func playWord(_ cueID: UUID, _ index: Int) -> String { "\(word(cueID, index)).play" }
        /// Selects the n-th word to check in the cue's text, to type over it.
        public static func selectWord(_ cueID: UUID, _ index: Int) -> String { "\(word(cueID, index)).select" }
        /// Confirms the n-th word to check is right.
        public static func confirmWord(_ cueID: UUID, _ index: Int) -> String { "\(word(cueID, index)).confirm" }

        public enum Column: String, CaseIterable, Sendable {
            case number
            case inPoint = "in"
            case outPoint = "out"
            case readingSpeed = "cps"
            /// The button that shows the cue at the top or bottom; its value is "top" or "bottom".
            case position
            /// Review warnings; the value lists them.
            case issues
            /// The words the transcriber was unsure of, under the text.
            case words
            case text
            /// In translation mode, the source cue's text (read-only).
            case source
            /// The variants of a line AI translation could translate more than one way, while the choice is open.
            case choices
            /// A row hover action listing the variants of a line whose choice is made.
            case variantsMenu
            /// An AI tool's proposed change to the cue, shown as a diff; its value is the proposed text.
            case proposal
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

    /// The issues panel under the cue list (View › Show Issues).
    public enum Issues {
        public static let root = "issues"
        /// The QC preset's name, beside the review count in the actions bar; its help explains the limits.
        public static let preset = "issues.preset"
        /// One issue; its label is the cue number and its value the message.
        public static func item(_ cueID: UUID, _ offset: Int) -> String { "issues.item.\(cueID.uuidString).\(offset)" }
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

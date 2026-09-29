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
        /// The footer counting cues that need review; its value is e.g. "7 cues need review".
        public static let reviewSummary = "cueList.review"

        public enum Column: String, CaseIterable, Sendable {
            case number
            case inPoint = "in"
            case outPoint = "out"
            case readingSpeed = "cps"
            /// The Default/Top position switch.
            case position
            /// Review warnings; the value lists them.
            case issues
            case text
        }
    }

    /// The issues panel under the cue list (Review › Show Issues).
    public enum Issues {
        public static let root = "issues"
        /// The QC preset's name; its help explains the limits.
        public static let preset = "issues.preset"
        /// One issue; its label is the cue number and its value the message.
        public static func item(_ cueID: UUID, _ offset: Int) -> String { "issues.item.\(cueID.uuidString).\(offset)" }
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

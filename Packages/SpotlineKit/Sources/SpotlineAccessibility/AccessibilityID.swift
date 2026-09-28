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
        /// The subtitle shown over the video; its value is the cue's visible text.
        public static let subtitle = "video.subtitle"
    }

    public enum Transport {
        public static let root = "transport"
        public static let timecode = "transport.timecode"
        public static let frameRate = "transport.frameRate"
        /// Media analysis state: "Analyzing 40%", or the number of shot changes found.
        public static let analysis = "transport.analysis"
        /// The audio track picker; its value is the playing track's name.
        public static let audioTrack = "transport.audioTrack"
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

    public enum CueList {
        public static let root = "cueList"
        public static func row(_ cueID: UUID) -> String { "cueList.row.\(cueID.uuidString)" }
        /// One cell of a cue's row, e.g. `cueList.row.<id>.text`.
        public static func cell(_ cueID: UUID, _ column: Column) -> String { "\(row(cueID)).\(column.rawValue)" }

        public enum Column: String, CaseIterable, Sendable {
            case number, inPoint = "in", outPoint = "out", duration, text
        }
    }

    public enum Inspector {
        public static let root = "inspector"
        /// The selected cue's text editor.
        public static let text = "inspector.text"
        public static let inPoint = "inspector.in"
        public static let outPoint = "inspector.out"
        public static let duration = "inspector.duration"
        /// Characters per line against the guideline, e.g. "38/42 · 12/42".
        public static let lineLengths = "inspector.lineLengths"
    }
}

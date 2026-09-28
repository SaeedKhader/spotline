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
    }

    public enum Transport {
        public static let root = "transport"
        public static let timecode = "transport.timecode"
        public static let frameRate = "transport.frameRate"
    }

    public enum Timeline {
        public static let root = "timeline"
    }

    public enum CueList {
        public static let root = "cueList"
        public static func row(_ cueID: UUID) -> String { "cueList.row.\(cueID.uuidString)" }
    }

    public enum Inspector {
        public static let root = "inspector"
    }
}

import Foundation

/// One subtitle event: text shown between `start` (inclusive) and `end` (exclusive).
public struct Cue: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var start: MediaTime
    public var end: MediaTime
    public var text: String
    public var position: CuePosition

    public init(id: UUID = UUID(), start: MediaTime, end: MediaTime, text: String, position: CuePosition = .bottom) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.position = position
    }

    public var duration: MediaTime { end - start }

    /// Characters per second: visible characters (without markup or line
    /// breaks) over the duration, the reading-speed measure style guides use.
    public var readingSpeed: Double {
        let characters = SubtitleText.visibleLines(of: text).reduce(0) { $0 + $1.count }
        let seconds = duration.seconds
        return seconds > 0 ? Double(characters) / seconds : 0
    }
}

/// Where a cue is shown on screen.
public enum CuePosition: String, Hashable, Sendable, Codable, CaseIterable {
    /// The default: bottom center.
    case bottom
    /// Top center, used when the bottom holds on-screen text.
    case top
}

/// The cues for one language and purpose (e.g. English SDH, Arabic translation).
public struct SubtitleTrack: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    /// BCP 47 language tag, "und" when unknown.
    public var languageCode: String
    public var cues: [Cue]

    public init(id: UUID = UUID(), languageCode: String = "und", cues: [Cue] = []) {
        self.id = id
        self.languageCode = languageCode
        self.cues = cues
    }
}

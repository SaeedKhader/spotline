import Foundation

/// One subtitle event: text shown between `start` (inclusive) and `end` (exclusive).
public struct Cue: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var start: MediaTime
    public var end: MediaTime
    public var text: String

    public init(id: UUID = UUID(), start: MediaTime, end: MediaTime, text: String) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
    }

    public var duration: MediaTime { end - start }
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

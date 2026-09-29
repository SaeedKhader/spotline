import Foundation

/// One subtitle event: text shown between `start` (inclusive) and `end` (exclusive).
public struct Cue: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var start: MediaTime
    public var end: MediaTime
    public var text: String
    public var position: CuePosition
    /// The name of the track style the cue uses (ASS/SSA), nil for the track's default.
    public var style: String?
    /// Who speaks the line (the ASS "Name" field).
    public var speaker: String?
    /// In a translation, the source-language cue this one translates.
    public var sourceCueID: UUID?
    /// The speaker in the track's cast list (`SubtitleTrack.speakers`), once known.
    public var speakerID: Speaker.ID?
    /// Who the line is spoken to, for languages whose grammar depends on it (docs/ARCHITECTURE.md, 7b).
    public var addressee: AddresseeTag?

    public init(
        id: UUID = UUID(), start: MediaTime, end: MediaTime, text: String, position: CuePosition = .bottom,
        style: String? = nil, speaker: String? = nil, sourceCueID: UUID? = nil, speakerID: Speaker.ID? = nil,
        addressee: AddresseeTag? = nil
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.position = position
        self.style = style
        self.speaker = speaker
        self.sourceCueID = sourceCueID
        self.speakerID = speakerID
        self.addressee = addressee
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
    /// Named text styles cues refer to (ASS/SSA), in file order. Empty for formats without styles.
    public var styles: [SubtitleStyle]
    /// Header fields kept for round trips, e.g. the ASS `[Script Info]` keys (`PlayResX`, `Title`).
    public var properties: [String: String]
    /// The cast: who speaks, with their gender when known. Cues refer to them by `speakerID`.
    public var speakers: [Speaker]

    public init(
        id: UUID = UUID(), languageCode: String = "und", cues: [Cue] = [], styles: [SubtitleStyle] = [],
        properties: [String: String] = [:], speakers: [Speaker] = []
    ) {
        self.id = id
        self.languageCode = languageCode
        self.cues = cues
        self.styles = styles
        self.properties = properties
        self.speakers = speakers
    }

    /// The style named `name`, else the one named "Default", else the first.
    public func style(named name: String?) -> SubtitleStyle? {
        styles.first { $0.name == name } ?? styles.first { $0.name == SubtitleStyle.defaultName } ?? styles.first
    }
}

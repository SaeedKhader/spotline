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
    /// The transcriber's labels for who says the line ("speaker_0"), one per
    /// speaker in order; two for a dialogue cue. Nil when not transcribed with speakers.
    public var voices: [String]?
    /// Set when AI translation found the line could be translated more than one
    /// way: every variant, the one in use and why (docs/ARCHITECTURE.md, 7b).
    public var flag: TranslationFlag?
    /// True while the text is as an AI tool wrote it (transcription, translation);
    /// cleared when the user edits it. The cue list tints these.
    public var isAIGenerated: Bool?

    public init(
        id: UUID = UUID(), start: MediaTime, end: MediaTime, text: String, position: CuePosition = .bottom,
        style: String? = nil, speaker: String? = nil, sourceCueID: UUID? = nil, voices: [String]? = nil,
        flag: TranslationFlag? = nil
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.position = position
        self.style = style
        self.speaker = speaker
        self.sourceCueID = sourceCueID
        self.voices = voices
        self.flag = flag
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
    /// The people in the episode, as AI translation came to know them (names from the
    /// dialogue, genders, voices). Picks confirm them; nobody enters them by hand.
    public var cast: [CastMember]

    public init(
        id: UUID = UUID(), languageCode: String = "und", cues: [Cue] = [], styles: [SubtitleStyle] = [],
        properties: [String: String] = [:], cast: [CastMember] = []
    ) {
        self.id = id
        self.languageCode = languageCode
        self.cues = cues
        self.styles = styles
        self.properties = properties
        self.cast = cast
    }

    private enum CodingKeys: String, CodingKey {
        case id, languageCode, cues, styles, properties, cast
    }

    /// Projects saved before the cast existed have none.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        languageCode = try container.decode(String.self, forKey: .languageCode)
        cues = try container.decode([Cue].self, forKey: .cues)
        styles = try container.decodeIfPresent([SubtitleStyle].self, forKey: .styles) ?? []
        properties = try container.decodeIfPresent([String: String].self, forKey: .properties) ?? [:]
        cast = try container.decodeIfPresent([CastMember].self, forKey: .cast) ?? []
    }

    /// The style named `name`, else the one named "Default", else the first.
    public func style(named name: String?) -> SubtitleStyle? {
        styles.first { $0.name == name } ?? styles.first { $0.name == SubtitleStyle.defaultName } ?? styles.first
    }
}

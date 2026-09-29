import SubtitleCore

/// The limits one client or broadcaster sets for deliveries. A nil limit is not checked.
public struct QCPreset: Identifiable, Hashable, Sendable {
    /// Stable identifier, stored in settings. Treat as public API.
    public let id: String
    public let name: String
    /// Where the numbers come from, in a sentence.
    public let summary: String
    public var maxLines: Int?
    public var maxCharactersPerLine: Int?
    /// Reading speed in characters per second (visible characters, no line breaks).
    public var maxCharactersPerSecond: Double?
    public var minimumDuration: MediaTime?
    public var maximumDuration: MediaTime?
    /// Frames between one cue's end and the next one's start in the same position.
    /// The editor also keeps edits this far apart.
    public var minimumGapFrames: Int64
    /// A cue's start within this many frames of a shot change should be on it,
    /// and its end on it or `minimumGapFrames` before it.
    public var shotChangeFrames: Int64?

    public init(
        id: String, name: String, summary: String, maxLines: Int? = nil, maxCharactersPerLine: Int? = nil,
        maxCharactersPerSecond: Double? = nil, minimumDuration: MediaTime? = nil, maximumDuration: MediaTime? = nil,
        minimumGapFrames: Int64 = 2, shotChangeFrames: Int64? = nil
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.maxLines = maxLines
        self.maxCharactersPerLine = maxCharactersPerLine
        self.maxCharactersPerSecond = maxCharactersPerSecond
        self.minimumDuration = minimumDuration
        self.maximumDuration = maximumDuration
        self.minimumGapFrames = minimumGapFrames
        self.shotChangeFrames = shotChangeFrames
    }

    /// The Netflix Timed Text Style Guide's general rules for adult programs in
    /// most Latin-script languages (the per-language guides adjust them).
    public static let netflix = QCPreset(
        id: "netflix", name: "Netflix (Adult)",
        summary: "Netflix style guide for adult programs: 42 characters a line, 2 lines, 20 c/s, 5/6 s to 7 s, 2-frame gaps, cues on or 12 frames from shot changes.",
        maxLines: 2, maxCharactersPerLine: 42, maxCharactersPerSecond: 20,
        minimumDuration: MediaTime(value: 5, timescale: 6), maximumDuration: MediaTime(value: 7, timescale: 1),
        minimumGapFrames: 2, shotChangeFrames: 12
    )

    /// Netflix's children's programs read slower.
    public static let netflixChildren = QCPreset(
        id: "netflixChildren", name: "Netflix (Children)",
        summary: "Netflix style guide for children's programs: as for adults, with at most 17 c/s.",
        maxLines: 2, maxCharactersPerLine: 42, maxCharactersPerSecond: 17,
        minimumDuration: MediaTime(value: 5, timescale: 6), maximumDuration: MediaTime(value: 7, timescale: 1),
        minimumGapFrames: 2, shotChangeFrames: 12
    )

    /// Conservative television limits in the spirit of the BBC and EBU guidelines:
    /// shorter lines and slower reading than streaming.
    public static let broadcast = QCPreset(
        id: "broadcast", name: "Broadcast",
        summary: "Conservative TV limits, in the spirit of BBC and EBU practice: 37 characters a line, 2 lines, 15 c/s, 1 s to 7 s, 2-frame gaps, cues on or 12 frames from shot changes.",
        maxLines: 2, maxCharactersPerLine: 37, maxCharactersPerSecond: 15,
        minimumDuration: MediaTime(value: 1, timescale: 1), maximumDuration: MediaTime(value: 7, timescale: 1),
        minimumGapFrames: 2, shotChangeFrames: 12
    )

    /// Only what makes subtitles unreadable: text, overlaps, line length and count, reading speed.
    public static let basic = QCPreset(
        id: "basic", name: "Basic",
        summary: "Only the essentials: no empty cues or overlaps, 42 characters a line, 2 lines, 20 c/s.",
        maxLines: 2, maxCharactersPerLine: 42, maxCharactersPerSecond: 20, minimumGapFrames: 2
    )

    public static let all: [QCPreset] = [netflix, netflixChildren, broadcast, basic]
    public static let standard = netflix

    public static func named(_ id: String) -> QCPreset? {
        all.first { $0.id == id }
    }
}

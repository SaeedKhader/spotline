import Foundation
import SubtitleCore

/// A subtitle file format Spotline reads and writes.
///
/// Cue text is kept exactly as written in SRT and WebVTT files, including
/// inline tags such as `<i>` and entities such as `&amp;`, so import followed
/// by export changes nothing but layout (numbering, timestamp padding, line
/// endings). ASS/SSA and TTML convert their markup to the same conventions
/// (see `Markup`), and keep their styles and header in the track. EBU STL is
/// binary (see `EBUSTL`); read and write it with `decode(_:)` and `encode(_:frameRate:)`.
public enum SubtitleFormat: String, CaseIterable, Sendable {
    case srt
    case webVTT
    case ass
    case ssa
    case ttml
    case ebuSTL

    public var fileExtension: String {
        switch self {
        case .srt: "srt"
        case .webVTT: "vtt"
        case .ass: "ass"
        case .ssa: "ssa"
        case .ttml: "ttml"
        case .ebuSTL: "stl"
        }
    }

    /// Other extensions files in this format use.
    public var alternativeExtensions: [String] {
        self == .ttml ? ["dfxp", "xml"] : []
    }

    public var displayName: String {
        switch self {
        case .srt: "SubRip (.srt)"
        case .webVTT: "WebVTT (.vtt)"
        case .ass: "Advanced SubStation Alpha (.ass)"
        case .ssa: "SubStation Alpha (.ssa)"
        case .ttml: "TTML / IMSC 1.1 (.ttml)"
        case .ebuSTL: "EBU STL (.stl)"
        }
    }

    public init?(fileExtension: String) {
        guard let format = SubtitleFormat.allCases.first(where: { format in
            ([format.fileExtension] + format.alternativeExtensions).contains {
                $0.caseInsensitiveCompare(fileExtension) == .orderedSame
            }
        }) else { return nil }
        self = format
    }

    /// Binary formats are read and written as bytes, not text.
    public var isBinary: Bool { self == .ebuSTL }

    /// The format of a text file, from its extension or else its contents.
    public static func detect(fileExtension: String, text: String) -> SubtitleFormat? {
        if let format = SubtitleFormat(fileExtension: fileExtension), format == .ebuSTL {
            // A text .stl is Spruce STL, which Spotline doesn't read.
            return nil
        }
        if let format = SubtitleFormat(fileExtension: fileExtension), format != .ttml || fileExtension.lowercased() != "xml" || text.contains("<tt") {
            return format
        }
        let start = text.drop(while: { $0 == "\u{FEFF}" || $0.isWhitespace })
        let firstLine = start.prefix(while: { !$0.isNewline })
        if firstLine.hasPrefix("WEBVTT") { return .webVTT }
        if firstLine.lowercased().hasPrefix("[script info]") {
            let isSSA = text.range(of: "ScriptType: v4.00\n") != nil || text.range(of: "ScriptType: v4.00\r") != nil
                || text.range(of: "[V4 Styles]") != nil
            return isSSA ? .ssa : .ass
        }
        if start.hasPrefix("<"), text.contains("<tt") { return .ttml }
        if text.contains("-->") { return .srt }
        return nil
    }

    /// The cues of a file in this format.
    public func parse(_ text: String) throws(SubtitleParseError) -> [Cue] {
        try parseTrack(text).cues
    }

    /// The cues of a file, with its styles, header fields and language where the format has them.
    public func parseTrack(_ text: String) throws(SubtitleParseError) -> SubtitleTrack {
        switch self {
        case .srt: SubtitleTrack(cues: try SRT.parse(text))
        case .webVTT: SubtitleTrack(cues: try WebVTT.parse(text))
        case .ass, .ssa: try ASS.parse(text)
        case .ttml: try TTML.parse(text)
        case .ebuSTL: throw SubtitleParseError(line: 1, reason: "EBU STL is binary; read it with decode(_:)")
        }
    }

    /// The track in a file's bytes: EBU STL, or text in any encoding `SubtitleFile.decode(_:)` reads.
    public func decode(_ data: Data) throws -> SubtitleTrack {
        if self == .ebuSTL { return try EBUSTL.parse(data) }
        return try parseTrack(SubtitleFile.decode(data))
    }

    /// The file's bytes: UTF-8 text, or EBU STL frames at `frameRate`.
    public func encode(_ track: SubtitleTrack, frameRate: FrameRate) -> Data {
        if self == .ebuSTL { return EBUSTL.serialize(track, frameRate: frameRate) }
        return Data(serialize(track).utf8)
    }

    /// The file contents for `cues`, with `\n` line endings.
    public func serialize(_ cues: [Cue]) -> String {
        serialize(SubtitleTrack(cues: cues))
    }

    /// The file contents for a track, with `\n` line endings.
    public func serialize(_ track: SubtitleTrack) -> String {
        switch self {
        case .srt: SRT.serialize(track.cues)
        case .webVTT: WebVTT.serialize(track.cues)
        case .ass: ASS.serialize(track, variant: .ass)
        case .ssa: ASS.serialize(track, variant: .ssa)
        case .ttml: TTML.serialize(track)
        case .ebuSTL: preconditionFailure("EBU STL is binary; write it with encode(_:frameRate:)")
        }
    }
}

extension SubtitleTrack {
    /// A track from an ASS subtitle stream muxed in a video file: its header
    /// (`[Script Info]` and styles, the stream's codec private data) and its
    /// events, each a Dialogue line's fields without its times
    /// (`ReadOrder, Layer, Style, Name, MarginL, MarginR, MarginV, Effect, Text`),
    /// the form Matroska stores and FFmpeg's text subtitle decoders return.
    public init(
        assHeader: String, events: [(start: MediaTime, end: MediaTime, fields: String)]
    ) throws(SubtitleParseError) {
        self = try ASS.parse(header: assHeader, events: events)
    }
}

/// Why a subtitle file could not be read, with the 1-based line where it went wrong.
public struct SubtitleParseError: Error, Equatable, Sendable, CustomStringConvertible {
    public let line: Int
    public let reason: String

    public init(line: Int, reason: String) {
        self.line = line
        self.reason = reason
    }

    public var description: String { "Line \(line): \(reason)" }
}

/// Reading and writing subtitle files on disk.
public enum SubtitleFile {
    /// Reads `url`, choosing the format from its extension or contents.
    public static func read(from url: URL) throws -> (format: SubtitleFormat, track: SubtitleTrack) {
        let data = try Data(contentsOf: url)
        if EBUSTL.isEBUSTL(data) { return (.ebuSTL, try EBUSTL.parse(data)) }
        let text = try decode(data)
        guard let format = SubtitleFormat.detect(fileExtension: url.pathExtension, text: text) else {
            throw SubtitleParseError(line: 1, reason: "Not a subtitle file Spotline can read (SRT, WebVTT, ASS, SSA, TTML or EBU STL)")
        }
        return (format, try format.parseTrack(text))
    }

    /// Writes a track to `url`: text as UTF-8 without a byte order mark, EBU STL
    /// with times in frames at `frameRate`.
    public static func write(_ track: SubtitleTrack, as format: SubtitleFormat, frameRate: FrameRate = .fps25, to url: URL) throws {
        try format.encode(track, frameRate: frameRate).write(to: url, options: .atomic)
    }

    /// Writes `cues` to `url` (see `write(_:as:frameRate:to:)`).
    public static func write(_ cues: [Cue], as format: SubtitleFormat, frameRate: FrameRate = .fps25, to url: URL) throws {
        try write(SubtitleTrack(cues: cues), as: format, frameRate: frameRate, to: url)
    }

    /// Decodes subtitle file bytes: UTF-8 or UTF-16 with a byte order mark,
    /// else UTF-8, else Windows-1252 (common for older SRT files).
    public static func decode(_ data: Data) throws -> String {
        let bytes = [UInt8](data.prefix(3))
        let text: String? = if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            String(data: data.dropFirst(3), encoding: .utf8)
        } else if bytes.starts(with: [0xFF, 0xFE]) {
            String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        } else if bytes.starts(with: [0xFE, 0xFF]) {
            String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        } else {
            String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
        }
        guard let text else { throw SubtitleParseError(line: 1, reason: "Unknown text encoding") }
        return text
    }
}

// MARK: - Shared helpers

/// The file's lines with any byte order mark removed and CRLF or CR endings treated as LF.
func splitLines(_ text: String) -> [Substring] {
    var text = Substring(text)
    if text.first == "\u{FEFF}" { text = text.dropFirst() }
    // Swift treats "\r\n" as one Character, so split on each line-ending form.
    return text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
}

func isBlank(_ line: Substring) -> Bool {
    line.allSatisfy(\.isWhitespace)
}

/// Parses the start and end of a timing line (`start --> end [settings]`).
/// Anything after the end timestamp (SRT coordinates, WebVTT cue settings) is ignored.
func parseTimingLine(_ line: Substring, lineNumber: Int) throws(SubtitleParseError) -> (MediaTime, MediaTime) {
    guard let arrow = line.range(of: "-->") else {
        throw SubtitleParseError(line: lineNumber, reason: "Expected a timing line (start --> end)")
    }
    let startField = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
    let endField = line[arrow.upperBound...].split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
    guard let start = parseTimestamp(startField) else {
        throw SubtitleParseError(line: lineNumber, reason: "Invalid start time \"\(startField)\"")
    }
    guard let end = parseTimestamp(endField) else {
        throw SubtitleParseError(line: lineNumber, reason: "Invalid end time \"\(endField)\"")
    }
    return (start, end)
}

func parseTimestamp(_ field: String) -> MediaTime? {
    Timestamp.parse(field)
}

func formatTimestamp(_ time: MediaTime, fractionSeparator: Character) -> String {
    Timestamp.format(time, fractionSeparator: fractionSeparator)
}

/// The cue's text as lines safe to write inside one block: blank lines would end the block, so they are dropped.
func payloadLines(_ text: String) -> [Substring] {
    splitLines(text).filter { !isBlank($0) }
}

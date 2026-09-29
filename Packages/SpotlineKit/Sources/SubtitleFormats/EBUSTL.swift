import Foundation
import SubtitleCore

/// EBU STL (EBU Tech 3264-E), the binary exchange format of European broadcast.
///
/// A file is a 1024-byte General Subtitle Information (GSI) block followed by
/// 128-byte Text and Timing Information (TTI) blocks. Times are timecodes at
/// 25 fps (`STL25.01`) or 30 fps (`STL30.01`, read as NTSC 29.97 non-drop, the
/// usual meaning). Text is in one of five 8-bit character tables: Latin
/// (ISO 6937), Latin/Cyrillic, Latin/Arabic, Latin/Greek or Latin/Hebrew
/// (ISO 8859-5 to -8).
///
/// Read: italics and underline (0x80–0x83) become `<i>` and `<u>`, line breaks
/// (0x8A, doubled for double height) become one newline, teletext colour and
/// size codes are dropped, a vertical position in the top half of the screen
/// makes a top cue, extension blocks join, comments are skipped, and times are
/// taken relative to the programme's start timecode (TCP) when every cue is after it.
///
/// Written: `STL25.01` for 25 and 50 fps media, else `STL30.01`; teletext
/// (DSC 1, 23 rows, 40 characters); centred; the character table the text
/// needs (Arabic text is written with table 02). The title, language and start
/// timecode read from a file are kept in the track and written back.
public enum EBUSTL {
    static let gsiSize = 1024
    static let ttiSize = 128
    static let textSize = 112

    /// Track property keys for GSI fields kept for round trips.
    public enum Property {
        /// The original programme title (OPT); shared with ASS's `Title`.
        public static let title = "Title"
        /// The programme's start timecode (TCP) as HHMMSSFF.
        public static let startOfProgramme = "EBU.TCP"
        /// Country of origin (CO), e.g. "GBR".
        public static let country = "EBU.CO"
        public static let publisher = "EBU.PUB"
        public static let translatedTitle = "EBU.TPT"
        public static let translator = "EBU.TN"
    }

    /// True when `data` starts like an EBU STL file ("850STL25.01" and similar).
    public static func isEBUSTL(_ data: Data) -> Bool {
        data.count >= 11 && String(decoding: data[data.startIndex + 3 ..< data.startIndex + 6], as: UTF8.self) == "STL"
    }

    // MARK: - Reading

    public static func parse(_ data: Data) throws(SubtitleParseError) -> SubtitleTrack {
        let bytes = [UInt8](data)
        guard bytes.count >= gsiSize, isEBUSTL(data) else {
            throw SubtitleParseError(line: 1, reason: "Not an EBU STL file (no STL25.01 or STL30.01 header)")
        }
        let gsi = GSI(bytes: Array(bytes[0..<gsiSize]))
        let rate = gsi.frameRate
        let table = CharacterTable(code: gsi.field(12, 2)) ?? .latin
        let displayRows = Int(gsi.field(253, 2)) ?? 23

        // Blocks of one subtitle (same number) join; the last has extension number 0xFF.
        var subtitles: [(start: Timecode?, end: Timecode?, row: Int, text: [UInt8])] = []
        var current: (number: Int, start: Timecode?, end: Timecode?, row: Int, text: [UInt8])?
        var offset = gsiSize
        var blockNumber = 0
        while offset + ttiSize <= bytes.count {
            let block = Array(bytes[offset..<offset + ttiSize])
            offset += ttiSize
            blockNumber += 1
            let number = Int(block[1]) | Int(block[2]) << 8
            let extensionNumber = block[3]
            let isComment = block[15] == 1
            // 0xFE: user data, not text.
            guard extensionNumber != 0xFE, !isComment else { continue }
            let text = Array(block[16..<ttiSize])
            if var open = current, open.number == number {
                open.text += text
                current = open
            } else {
                if let open = current { subtitles.append((open.start, open.end, open.row, open.text)) }
                current = (
                    number,
                    timecode(block[5..<9], rate: rate),
                    timecode(block[9..<13], rate: rate),
                    Int(block[13]),
                    text
                )
            }
            if extensionNumber == 0xFF, let open = current {
                subtitles.append((open.start, open.end, open.row, open.text))
                current = nil
            }
        }
        if let open = current { subtitles.append((open.start, open.end, open.row, open.text)) }

        // Times are timecodes on the programme's clock; show them from its start.
        let programmeStart = Timecode(hhmmssff: gsi.field(256, 8), rate: rate)
        let starts = subtitles.compactMap(\.start)
        let origin: MediaTime = if let programmeStart, starts.allSatisfy({ $0.frameNumber >= programmeStart.frameNumber }) {
            programmeStart.time
        } else {
            .zero
        }

        var cues: [Cue] = []
        for (index, subtitle) in subtitles.enumerated() {
            guard let start = subtitle.start, let end = subtitle.end else {
                throw SubtitleParseError(line: index + 1, reason: "Subtitle \(index + 1) has an invalid timecode")
            }
            let text = decodeText(subtitle.text, table: table)
            cues.append(Cue(
                start: start.time - origin,
                end: end.time - origin,
                text: text,
                position: subtitle.row > 0 && subtitle.row < max(displayRows, 2) / 2 ? .top : .bottom
            ))
        }
        cues.sort { $0.start < $1.start }

        var properties: [String: String] = [:]
        func keep(_ key: String, _ value: String) { if !value.isEmpty { properties[key] = value } }
        keep(Property.title, gsi.text(16, 32, table: table))
        keep(Property.translatedTitle, gsi.text(80, 32, table: table))
        keep(Property.translator, gsi.text(144, 32, table: table))
        keep(Property.country, gsi.field(274, 3))
        keep(Property.publisher, gsi.text(277, 32, table: table))
        if let programmeStart, programmeStart.frameNumber > 0 { keep(Property.startOfProgramme, gsi.field(256, 8)) }
        return SubtitleTrack(
            languageCode: LanguageCode.bcp47(forEBU: gsi.field(14, 2)) ?? "und",
            cues: cues,
            properties: properties
        )
    }

    /// Four bytes: hours, minutes, seconds, frames.
    private static func timecode(_ bytes: ArraySlice<UInt8>, rate: FrameRate) -> Timecode? {
        let b = Array(bytes)
        return Timecode(hours: Int(b[0]), minutes: Int(b[1]), seconds: Int(b[2]), frames: Int(b[3]), rate: rate)
    }

    /// The text field as the editor's markup: lines, `<i>` and `<u>`.
    static func decodeText(_ bytes: [UInt8], table: CharacterTable) -> String {
        var lines: [String] = []
        var line: [UInt8] = []
        var markup = ""
        var italic = false, underline = false

        func flushRun() {
            markup += table.decode(line)
            line = []
        }
        func endLine() {
            flushRun()
            if italic { markup += "</i>" }
            if underline { markup += "</u>" }
            lines.append(markup)
            markup = ""
            if underline { markup += "<u>" }
            if italic { markup += "<i>" }
        }
        loop: for byte in bytes {
            switch byte {
            case 0x8F: break loop
            case 0x8A: endLine()
            case 0x80: flushRun(); if !italic { markup += "<i>"; italic = true }
            case 0x81: flushRun(); if italic { markup += "</i>"; italic = false }
            case 0x82: flushRun(); if !underline { markup += "<u>"; underline = true }
            case 0x83: flushRun(); if underline { markup += "</u>"; underline = false }
            // Teletext spacing attributes (colours, size, boxes) show as spaces.
            case 0x00...0x1F: line.append(0x20)
            // Other control codes (boxing 0x84/0x85, reserved) have no text.
            case 0x80...0x9F: break
            default: line.append(byte)
            }
        }
        endLine()
        return lines
            .map { cleanLine($0) }
            .filter { !SubtitleText.visibleLines(of: $0).joined().allSatisfy(\.isWhitespace) }
            .joined(separator: "\n")
    }

    /// Trims spaces (teletext attributes) inside and outside the line's markup and drops empty tag pairs.
    private static func cleanLine(_ line: String) -> String {
        var result = line
        for (open, close) in [("<i>", "</i>"), ("<u>", "</u>")] {
            result = result.replacing(open + close, with: "")
        }
        // Spaces just inside an opening tag or before a closing one belong outside it.
        result = result.replacing(/(<[iu]>)(\ +)/) { match in String(match.output.2 + match.output.1) }
        result = result.replacing(/(\ +)(<\/[iu]>)/) { match in String(match.output.2 + match.output.1) }
        result = result.replacing(/\ {2,}/, with: " ")
        return result.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Writing

    /// The file for a track. Times become frames at `frameRate`'s STL rate.
    public static func serialize(_ track: SubtitleTrack, frameRate: FrameRate, creationDate: Date = Date()) -> Data {
        let is25 = frameRate.timecodeBase == 25 || frameRate.timecodeBase == 50
        let rate: FrameRate = is25 ? .fps25 : .fps29_97
        let text = track.cues.map(\.text).joined(separator: "\n")
        let table = CharacterTable.best(for: text, languageCode: track.languageCode)
        let programmeStart = track.properties[Property.startOfProgramme].flatMap { Timecode(hhmmssff: $0, rate: rate) }
        let origin = programmeStart?.time ?? .zero

        var blocks: [[UInt8]] = []
        var subtitleNumber = 0
        for cue in track.cues {
            let lines = encodeLines(cue.text, table: table)
            let fields = splitIntoBlocks(lines)
            // The first frame showing the cue and the first frame without it, on the programme's clock.
            let startFrame = (cue.start + origin).firstFrame(at: rate)
            let endFrame = max((cue.end + origin).firstFrame(at: rate), startFrame + 1)
            let lineCount = max(SubtitleText.visibleLines(of: cue.text).count, 1)
            let row = cue.position == .top ? 1 : 22 - (lineCount - 1)
            for (extensionIndex, field) in fields.enumerated() {
                var block = [UInt8](repeating: 0, count: ttiSize)
                block[0] = 0
                block[1] = UInt8(subtitleNumber & 0xFF)
                block[2] = UInt8(subtitleNumber >> 8 & 0xFF)
                block[3] = extensionIndex == fields.count - 1 ? 0xFF : UInt8(extensionIndex)
                block[4] = 0
                block.replaceSubrange(5..<9, with: timecodeBytes(frame: startFrame, rate: rate))
                block.replaceSubrange(9..<13, with: timecodeBytes(frame: endFrame, rate: rate))
                block[13] = UInt8(max(row, 1))
                block[14] = 2
                block[15] = 0
                block.replaceSubrange(16..<ttiSize, with: field)
                blocks.append(block)
            }
            subtitleNumber += 1
        }

        var gsi = [UInt8](repeating: 0x20, count: gsiSize)
        func put(_ offset: Int, _ length: Int, _ value: String) {
            let encoded = Array(value.utf8.prefix(length))
            gsi.replaceSubrange(offset..<offset + encoded.count, with: encoded)
        }
        func putText(_ offset: Int, _ length: Int, _ value: String?) {
            guard let value else { return }
            let encoded = Array(table.encode(value).prefix(length))
            gsi.replaceSubrange(offset..<offset + encoded.count, with: encoded)
        }
        func number(_ value: Int, width: Int) -> String {
            let digits = String(value)
            return String(repeating: "0", count: max(width - digits.count, 0)) + digits
        }
        let date = dateString(creationDate)
        put(0, 3, "850")
        put(3, 8, is25 ? "STL25.01" : "STL30.01")
        put(11, 1, "1")
        put(12, 2, table.code)
        put(14, 2, LanguageCode.ebu(forBCP47: track.languageCode))
        putText(16, 32, track.properties[Property.title])
        putText(80, 32, track.properties[Property.translatedTitle])
        putText(144, 32, track.properties[Property.translator])
        put(224, 6, date)
        put(230, 6, date)
        put(236, 2, "00")
        put(238, 5, number(blocks.count, width: 5))
        put(243, 5, number(subtitleNumber, width: 5))
        put(248, 3, "001")
        put(251, 2, "40")
        put(253, 2, "23")
        put(255, 1, "1")
        put(256, 8, programmeStart.map(hhmmssff) ?? "00000000")
        let firstFrame = track.cues.first.map { ($0.start + origin).firstFrame(at: rate) }
        put(264, 8, firstFrame.map { hhmmssff(Timecode(frameNumber: $0, rate: rate)) } ?? "00000000")
        put(272, 1, "1")
        put(273, 1, "1")
        put(274, 3, track.properties[Property.country] ?? "   ")
        putText(277, 32, track.properties[Property.publisher])
        return Data(gsi + blocks.joined())
    }

    /// The cue's lines as table bytes with italics and underline codes, joined by 0x8A.
    static func encodeLines(_ text: String, table: CharacterTable) -> [UInt8] {
        var result: [UInt8] = []
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for (index, line) in lines.enumerated() {
            if index > 0 { result.append(0x8A) }
            var rest = Substring(line)
            while !rest.isEmpty {
                let lowered = rest.prefix(4).lowercased()
                if let tag = ["<i>", "</i>", "<u>", "</u>"].first(where: { lowered.hasPrefix($0) }) {
                    result.append(["<i>": 0x80, "</i>": 0x81, "<u>": 0x82, "</u>": 0x83][tag]!)
                    rest = rest.dropFirst(tag.count)
                } else if let open = rest.first, open == "<" || open == "{",
                          let close = rest.firstIndex(of: open == "<" ? ">" : "}")
                {
                    // Other markup (<b>, {\an8}) has no STL code.
                    rest = rest[rest.index(after: close)...]
                } else {
                    let end = rest.dropFirst().firstIndex { $0 == "<" || $0 == "{" } ?? rest.endIndex
                    result += table.encode(SubtitleText.decodeEntities(String(rest[..<end])))
                    rest = rest[end...]
                }
            }
        }
        return result
    }

    /// Text fields of 112 bytes, padded with 0x8F; long text continues in extension blocks.
    private static func splitIntoBlocks(_ bytes: [UInt8]) -> [[UInt8]] {
        var fields: [[UInt8]] = []
        var index = 0
        repeat {
            let chunk = Array(bytes[index..<min(index + textSize, bytes.count)])
            fields.append(chunk + [UInt8](repeating: 0x8F, count: textSize - chunk.count))
            index += textSize
        } while index < bytes.count
        return fields
    }

    private static func timecodeBytes(frame: Int64, rate: FrameRate) -> [UInt8] {
        let timecode = Timecode(frameNumber: max(frame, 0), rate: rate)
        return [UInt8(min(timecode.hours, 23)), UInt8(timecode.minutes), UInt8(timecode.seconds), UInt8(timecode.frames)]
    }

    private static func hhmmssff(_ timecode: Timecode) -> String {
        [timecode.hours, timecode.minutes, timecode.seconds, timecode.frames]
            .map { $0 < 10 ? "0\($0)" : "\($0)" }
            .joined()
    }

    private static func dateString(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return [(parts.year ?? 2000) % 100, parts.month ?? 1, parts.day ?? 1]
            .map { $0 < 10 ? "0\($0)" : "\($0)" }
            .joined()
    }

    /// The General Subtitle Information block.
    private struct GSI {
        let bytes: [UInt8]

        /// An ASCII field, trimmed.
        func field(_ offset: Int, _ length: Int) -> String {
            String(decoding: bytes[offset..<offset + length], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }

        /// A text field in the file's character table, trimmed.
        func text(_ offset: Int, _ length: Int, table: CharacterTable) -> String {
            table.decode(Array(bytes[offset..<offset + length]).filter { $0 >= 0x20 && $0 != 0x8F })
                .trimmingCharacters(in: .whitespaces)
        }

        var frameRate: FrameRate {
            field(3, 8) == "STL30.01" ? .fps29_97 : .fps25
        }
    }
}

extension Timecode {
    /// Parses the GSI's HHMMSSFF fields.
    init?(hhmmssff: String, rate: FrameRate) {
        let digits = Array(hhmmssff)
        guard digits.count == 8, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { return nil }
        func pair(_ index: Int) -> Int { Int(String(digits[index..<index + 2]))! }
        self.init(hours: pair(0), minutes: pair(2), seconds: pair(4), frames: pair(6), rate: rate)
    }
}

// MARK: - Character tables

/// The five character code tables (CCT) EBU STL text can use.
enum CharacterTable: String, CaseIterable, Sendable {
    case latin = "00"
    case cyrillic = "01"
    case arabic = "02"
    case greek = "03"
    case hebrew = "04"

    init?(code: String) { self.init(rawValue: code) }

    var code: String { rawValue }

    /// The table that can write `text`: the one its script needs, else Latin.
    static func best(for text: String, languageCode: String) -> CharacterTable {
        let scalars = text.unicodeScalars
        if scalars.contains(where: { (0x0600...0x06FF).contains($0.value) }) { return .arabic }
        if scalars.contains(where: { (0x0590...0x05FF).contains($0.value) }) { return .hebrew }
        if scalars.contains(where: { (0x0400...0x04FF).contains($0.value) }) { return .cyrillic }
        if scalars.contains(where: { (0x0370...0x03FF).contains($0.value) }) { return .greek }
        return .latin
    }

    private var encoding: String.Encoding? {
        let cf: CFStringEncodings? = switch self {
        case .latin: nil
        case .cyrillic: .isoLatinCyrillic
        case .arabic: .isoLatinArabic
        case .greek: .isoLatinGreek
        case .hebrew: .isoLatinHebrew
        }
        return cf.map { String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding($0.rawValue))) }
    }

    func decode(_ bytes: [UInt8]) -> String {
        if let encoding { return String(data: Data(bytes), encoding: encoding) ?? String(decoding: bytes, as: UTF8.self) }
        return ISO6937.decode(bytes)
    }

    /// Characters the table lacks are written as "?".
    func encode(_ text: String) -> [UInt8] {
        guard let encoding else { return ISO6937.encode(text) }
        var bytes: [UInt8] = []
        for character in text {
            if let data = String(character).data(using: encoding), !data.isEmpty {
                bytes += data
            } else if let data = String(character).decomposedStringWithCanonicalMapping.unicodeScalars.first
                .flatMap({ String($0).data(using: encoding) })
            {
                bytes += data
            } else {
                bytes.append(0x3F)
            }
        }
        return bytes
    }
}

/// ISO 6937, EBU STL's Latin table: ASCII, plus accents written as a
/// non-spacing diacritic byte before the letter.
enum ISO6937 {
    private static let upper: [UInt8: Character] = [
        0xA1: "¡", 0xA2: "¢", 0xA3: "£", 0xA5: "¥", 0xA7: "§", 0xA8: "¤", 0xA9: "‘", 0xAA: "“", 0xAB: "«",
        0xAC: "←", 0xAD: "↑", 0xAE: "→", 0xAF: "↓", 0xB0: "°", 0xB1: "±", 0xB2: "²", 0xB3: "³", 0xB4: "×",
        0xB5: "µ", 0xB6: "¶", 0xB7: "·", 0xB8: "÷", 0xB9: "’", 0xBA: "”", 0xBB: "»", 0xBC: "¼", 0xBD: "½",
        0xBE: "¾", 0xBF: "¿", 0xD0: "―", 0xD1: "¹", 0xD2: "®", 0xD3: "©", 0xD4: "™", 0xD5: "♪", 0xD6: "¬",
        0xD7: "¦", 0xDC: "⅛", 0xDD: "⅜", 0xDE: "⅝", 0xDF: "⅞", 0xE0: "Ω", 0xE1: "Æ", 0xE2: "Đ", 0xE3: "ª",
        0xE4: "Ħ", 0xE6: "Ĳ", 0xE7: "Ŀ", 0xE8: "Ł", 0xE9: "Ø", 0xEA: "Œ", 0xEB: "º", 0xEC: "Þ", 0xED: "Ŧ",
        0xEE: "Ŋ", 0xEF: "ŉ", 0xF0: "ĸ", 0xF1: "æ", 0xF2: "đ", 0xF3: "ð", 0xF4: "ħ", 0xF5: "ı", 0xF6: "ĳ",
        0xF7: "ŀ", 0xF8: "ł", 0xF9: "ø", 0xFA: "œ", 0xFB: "ß", 0xFC: "þ", 0xFD: "ŧ", 0xFE: "ŋ", 0xFF: "\u{00AD}",
    ]
    /// Non-spacing diacritics, written before the letter they go on.
    private static let diacritics: [UInt8: Unicode.Scalar] = [
        0xC1: "\u{0300}", 0xC2: "\u{0301}", 0xC3: "\u{0302}", 0xC4: "\u{0303}", 0xC5: "\u{0304}",
        0xC6: "\u{0306}", 0xC7: "\u{0307}", 0xC8: "\u{0308}", 0xCA: "\u{030A}", 0xCB: "\u{0327}",
        0xCD: "\u{030B}", 0xCE: "\u{0328}", 0xCF: "\u{030C}",
    ]
    private static let reverseUpper = Dictionary(uniqueKeysWithValues: upper.map { ($1, $0) })
    private static let reverseDiacritics = Dictionary(uniqueKeysWithValues: diacritics.map { ($1, $0) })

    static func decode(_ bytes: [UInt8]) -> String {
        var result = ""
        var pending: Unicode.Scalar?
        for byte in bytes {
            if let mark = diacritics[byte] {
                pending = mark
                continue
            }
            var piece: String
            if (0x20...0x7E).contains(byte) {
                piece = String(UnicodeScalar(byte))
            } else if let character = upper[byte] {
                piece = String(character)
            } else if byte == 0xA0 {
                piece = "\u{00A0}"
            } else {
                piece = ""
            }
            if let mark = pending, !piece.isEmpty {
                piece = (piece + String(mark)).precomposedStringWithCanonicalMapping
                pending = nil
            }
            result += piece
        }
        return result
    }

    static func encode(_ text: String) -> [UInt8] {
        var bytes: [UInt8] = []
        for character in text {
            if let ascii = character.asciiValue, (0x20...0x7E).contains(ascii) {
                bytes.append(ascii)
            } else if let byte = reverseUpper[character] {
                bytes.append(byte)
            } else if character == "\u{00A0}" {
                bytes.append(0xA0)
            } else {
                let scalars = Array(String(character).decomposedStringWithCanonicalMapping.unicodeScalars)
                if scalars.count == 2, let base = scalars.first, base.isASCII, let mark = reverseDiacritics[scalars[1]] {
                    bytes += [mark, UInt8(base.value)]
                } else if let base = scalars.first, base.isASCII, (0x20...0x7E).contains(base.value) {
                    bytes.append(UInt8(base.value))
                } else {
                    bytes.append(0x3F)
                }
            }
        }
        return bytes
    }
}

/// EBU STL language codes (Tech 3264 appendix 3) and BCP 47 tags.
enum LanguageCode {
    private static let table: [(ebu: String, bcp47: String)] = [
        ("01", "sq"), ("03", "ca"), ("04", "hr"), ("05", "cy"), ("06", "cs"), ("07", "da"), ("08", "de"),
        ("09", "en"), ("0A", "es"), ("0C", "et"), ("0D", "eu"), ("0F", "fr"), ("11", "ga"), ("12", "gd"),
        ("13", "gl"), ("14", "is"), ("15", "it"), ("18", "lv"), ("19", "lb"), ("1A", "lt"), ("1B", "hu"),
        ("1C", "mt"), ("1D", "nl"), ("1E", "no"), ("20", "pl"), ("21", "pt"), ("22", "ro"), ("24", "sr"),
        ("25", "sk"), ("26", "sl"), ("27", "fi"), ("28", "sv"), ("29", "tr"),
        ("48", "ur"), ("49", "uk"), ("4A", "th"), ("56", "ru"), ("5A", "fa"), ("65", "ko"), ("69", "ja"),
        ("6B", "hi"), ("6C", "he"), ("70", "el"), ("75", "zh"), ("77", "bg"), ("7E", "ar"),
    ]

    static func bcp47(forEBU code: String) -> String? {
        table.first { $0.ebu.caseInsensitiveCompare(code) == .orderedSame }?.bcp47
    }

    /// "00" (unknown) for languages the table lacks.
    static func ebu(forBCP47 tag: String) -> String {
        let language = tag.split(separator: "-").first.map { $0.lowercased() } ?? ""
        return table.first { $0.bcp47 == language }?.ebu ?? "00"
    }
}

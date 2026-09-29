import SubtitleCore

/// WebVTT (.vtt), per https://www.w3.org/TR/webvtt1/.
///
/// Reads cues and skips NOTE, STYLE and REGION blocks. A `line` setting in
/// the upper half becomes the top position; cue identifiers and other
/// settings (position, align, size) are not kept yet. Writing is canonical: a bare `WEBVTT` header and
/// `HH:MM:SS.mmm` times.
enum WebVTT {
    static func parse(_ text: String) throws(SubtitleParseError) -> [Cue] {
        let lines = splitLines(text)
        guard let header = lines.first, header.hasPrefix("WEBVTT"),
              header.count == 6 || header.dropFirst(6).first == " " || header.dropFirst(6).first == "\t"
        else {
            throw SubtitleParseError(line: 1, reason: "A WebVTT file must start with \"WEBVTT\"")
        }

        var cues: [Cue] = []
        var index = 1
        // Header lines run until the first blank line.
        while index < lines.count, !isBlank(lines[index]) { index += 1 }

        while index < lines.count {
            if isBlank(lines[index]) {
                index += 1
                continue
            }
            let blockStart = index
            while index < lines.count, !isBlank(lines[index]) { index += 1 }
            let block = lines[blockStart..<index]

            let first = block[blockStart]
            if !first.contains("-->"), ["NOTE", "STYLE", "REGION"].contains(where: { isKeyword($0, first) }) {
                continue
            }
            // An optional cue identifier comes before the timing line.
            let timingIndex = first.contains("-->") ? blockStart : blockStart + 1
            guard timingIndex < index, block[timingIndex].contains("-->") else {
                throw SubtitleParseError(line: blockStart + 1, reason: "Expected a timing line (start --> end)")
            }
            let (start, end) = try parseTimingLine(block[timingIndex], lineNumber: timingIndex + 1)
            let payload = block[(timingIndex + 1)...].joined(separator: "\n")
            cues.append(Cue(start: start, end: end, text: payload, position: position(settings: block[timingIndex])))
        }
        return cues
    }

    static func serialize(_ cues: [Cue]) -> String {
        var output = "WEBVTT\n"
        for cue in cues {
            output += "\n"
            output += formatTimestamp(cue.start, fractionSeparator: ".")
            output += " --> "
            output += formatTimestamp(cue.end, fractionSeparator: ".")
            if cue.position == .top { output += " line:0" }
            output += "\n"
            // "-->" may not appear in a cue payload.
            for line in payloadLines(cue.text) { output += line.replacing("-->", with: "--&gt;") + "\n" }
        }
        return output
    }

    /// Top when the `line` setting puts the cue in the upper half: a line
    /// number counted from the top (0 or more) or a percentage under 50.
    static func position(settings timingLine: Substring) -> CuePosition {
        guard let arrow = timingLine.range(of: "-->") else { return .bottom }
        for setting in timingLine[arrow.upperBound...].split(whereSeparator: \.isWhitespace) where setting.hasPrefix("line:") {
            let value = setting.dropFirst(5).prefix { $0 != "," }
            if value.hasSuffix("%"), let percent = Double(value.dropLast()) { return percent < 50 ? .top : .bottom }
            if let line = Int(value) { return line >= 0 ? .top : .bottom }
        }
        return .bottom
    }

    /// True when `line` is `keyword` alone or followed by a space or tab.
    private static func isKeyword(_ keyword: String, _ line: Substring) -> Bool {
        guard line.hasPrefix(keyword) else { return false }
        let next = line.dropFirst(keyword.count).first
        return next == nil || next == " " || next == "\t"
    }
}

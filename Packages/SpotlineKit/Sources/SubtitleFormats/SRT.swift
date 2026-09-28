import SubtitleCore

/// SubRip (.srt): numbered blocks of `HH:MM:SS,mmm --> HH:MM:SS,mmm` and text, separated by blank lines.
///
/// Reading is lenient, as real-world SRT files are: cue numbers may be missing
/// or wrong, timestamps may use `.` or fewer millisecond digits, and a missing
/// blank line between cues is tolerated. Writing is canonical: cues are
/// renumbered from 1 and times use three millisecond digits.
enum SRT {
    static func parse(_ text: String) throws(SubtitleParseError) -> [Cue] {
        let lines = splitLines(text)
        var cues: [Cue] = []
        var index = 0

        func isTiming(_ i: Int) -> Bool { i < lines.count && lines[i].contains("-->") }
        func isCueNumber(_ i: Int) -> Bool {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            return !line.isEmpty && line.allSatisfy { $0.isASCII && $0.isNumber }
        }

        while index < lines.count {
            if isBlank(lines[index]) {
                index += 1
                continue
            }
            // The cue number line is optional; its value is ignored.
            if !isTiming(index) {
                guard isTiming(index + 1) else {
                    throw SubtitleParseError(line: index + 1, reason: "Expected a cue number or timing line")
                }
                index += 1
            }
            let (start, end) = try parseTimingLine(lines[index], lineNumber: index + 1)
            index += 1

            var textLines: [Substring] = []
            while index < lines.count, !isBlank(lines[index]) {
                // A cue number directly followed by a timing line starts the next cue.
                if isTiming(index) || (isCueNumber(index) && isTiming(index + 1)) { break }
                textLines.append(lines[index])
                index += 1
            }
            cues.append(Cue(start: start, end: end, text: textLines.joined(separator: "\n")))
        }
        return cues
    }

    static func serialize(_ cues: [Cue]) -> String {
        cues.enumerated().map { number, cue in
            var block = "\(number + 1)\n"
            block += formatTimestamp(cue.start, fractionSeparator: ",")
            block += " --> "
            block += formatTimestamp(cue.end, fractionSeparator: ",")
            block += "\n"
            for line in payloadLines(cue.text) { block += line + "\n" }
            return block
        }
        .joined(separator: "\n")
    }
}

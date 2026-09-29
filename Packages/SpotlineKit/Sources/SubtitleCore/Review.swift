/// A reason a cue needs another look before delivery.
///
/// These are the basic checks shown while editing. Full QC with per-client
/// presets (minimum gaps, durations, shot-change distance) comes in M4.
public enum ReviewIssue: Hashable, Sendable {
    case empty
    /// The cue is still showing when the next one in the same position starts.
    case overlapsNext
    /// Characters per second above `SubtitleGuidelines.maxCharactersPerSecond`.
    case readingSpeed(Double)
    /// A line (0-based) longer than `SubtitleGuidelines.maxCharactersPerLine`.
    case lineTooLong(line: Int, characters: Int)
    case tooManyLines(Int)

    public var message: String {
        switch self {
        case .empty: "No text"
        case .overlapsNext: "Overlaps the next cue"
        case .readingSpeed(let speed): "Reading speed \(Int(speed.rounded())) c/s (max \(Int(SubtitleGuidelines.maxCharactersPerSecond)))"
        case .lineTooLong(let line, let characters):
            "Line \(line + 1) has \(characters) characters (max \(SubtitleGuidelines.maxCharactersPerLine))"
        case .tooManyLines(let count): "\(count) lines (max \(SubtitleGuidelines.maxLines))"
        }
    }
}

public enum Review {
    /// The issues of each cue that has any, for cues sorted by start time.
    public static func issues(in cues: [Cue]) -> [Cue.ID: [ReviewIssue]] {
        var result: [Cue.ID: [ReviewIssue]] = [:]
        for (index, cue) in cues.enumerated() {
            var issues: [ReviewIssue] = []
            let lines = SubtitleText.visibleLines(of: cue.text)
            if lines.allSatisfy({ $0.allSatisfy(\.isWhitespace) }) {
                issues.append(.empty)
            } else {
                if lines.count > SubtitleGuidelines.maxLines { issues.append(.tooManyLines(lines.count)) }
                for (number, line) in lines.enumerated() where line.count > SubtitleGuidelines.maxCharactersPerLine {
                    issues.append(.lineTooLong(line: number, characters: line.count))
                }
                if cue.readingSpeed > SubtitleGuidelines.maxCharactersPerSecond { issues.append(.readingSpeed(cue.readingSpeed)) }
            }
            // A top cue (a sign) may run alongside bottom dialogue; only the same position overlaps.
            if let next = cues[(index + 1)...].first(where: { $0.position == cue.position }), next.start < cue.end {
                issues.append(.overlapsNext)
            }
            if !issues.isEmpty { result[cue.id] = issues }
        }
        return result
    }
}

import SubtitleCore
import SubtitleTranslation

/// Text as the benchmark scores it: what a viewer reads, normalized like the
/// translation tools compare text (`MatchText`), without hearing-impaired
/// descriptions ("[door slams]", "(laughs)"), speaker labels ("JOHN:") or music notes.
public enum ScoringText {
    public static func words(_ text: String) -> [String] {
        let spoken = SubtitleText.visibleLines(of: text).map(spokenPart).joined(separator: " ")
        return MatchText.normalize(spoken)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// A line as spoken: without descriptions, a leading speaker label or extra spaces. Empty when nothing is said.
    public static func spokenText(_ line: String) -> String {
        let spoken = spokenPart(of: line).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return spoken.contains { $0.isLetter || $0.isNumber } ? spoken : ""
    }

    /// The line without descriptions and a leading speaker label.
    static func spokenPart(of line: String) -> String {
        var result = ""
        var closing: Character?
        for character in line {
            if let end = closing {
                if character == end { closing = nil }
            } else if character == "[" {
                closing = "]"
            } else if character == "(" {
                closing = ")"
            } else if character != "♪" {
                result.append(character)
            }
        }
        // "JOHN: Hello" and "- MARY: Hi": a label is upper case (in scripts that have case).
        if let colon = result.firstIndex(of: ":") {
            let label = result[..<colon].trimmingCharacters(in: .whitespaces.union(["-"]))
            if !label.isEmpty, label.count <= 20, label.contains(where: \.isLetter), label == label.uppercased(), label != label.lowercased() {
                result = String(result[result.index(after: colon)...])
            }
        }
        return result
    }
}

/// The word-level edit (Levenshtein) alignment of a hypothesis to a reference.
public struct WordAlignment: Sendable, Equatable {
    public enum Step: Sendable, Equatable {
        /// Reference word, hypothesis word, same text.
        case match(Int, Int)
        case substitution(Int, Int)
        /// A reference word the hypothesis missed.
        case deletion(Int)
        /// A hypothesis word the reference does not have.
        case insertion(Int)
    }

    public var steps: [Step]

    public init(reference: [String], hypothesis: [String]) {
        let n = reference.count, m = hypothesis.count
        // Two rows of costs, and every cell's move for the way back (0 match/sub, 1 deletion, 2 insertion).
        var previous = Array(0...m)
        var current = [Int](repeating: 0, count: m + 1)
        var moves = [UInt8](repeating: 2, count: (n + 1) * (m + 1))
        for i in 0...n { moves[i * (m + 1)] = 1 }
        for i in stride(from: 1, through: n, by: 1) {
            current[0] = i
            for j in stride(from: 1, through: m, by: 1) {
                let diagonal = previous[j - 1] + (reference[i - 1] == hypothesis[j - 1] ? 0 : 1)
                let up = previous[j] + 1
                let left = current[j - 1] + 1
                if diagonal <= up, diagonal <= left {
                    current[j] = diagonal
                    moves[i * (m + 1) + j] = 0
                } else if up <= left {
                    current[j] = up
                    moves[i * (m + 1) + j] = 1
                } else {
                    current[j] = left
                    moves[i * (m + 1) + j] = 2
                }
            }
            swap(&previous, &current)
        }
        var steps: [Step] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            switch i > 0 && j > 0 ? moves[i * (m + 1) + j] : (i > 0 ? 1 : 2) {
            case 0:
                steps.append(reference[i - 1] == hypothesis[j - 1] ? .match(i - 1, j - 1) : .substitution(i - 1, j - 1))
                i -= 1
                j -= 1
            case 1:
                steps.append(.deletion(i - 1))
                i -= 1
            default:
                steps.append(.insertion(j - 1))
                j -= 1
            }
        }
        self.steps = steps.reversed()
    }

    public var matches: Int { steps.count { if case .match = $0 { true } else { false } } }
    public var substitutions: Int { steps.count { if case .substitution = $0 { true } else { false } } }
    public var deletions: Int { steps.count { if case .deletion = $0 { true } else { false } } }
    public var insertions: Int { steps.count { if case .insertion = $0 { true } else { false } } }

    /// Hypothesis index for each reference word that was heard exactly.
    public var matchedPairs: [(reference: Int, hypothesis: Int)] {
        steps.compactMap { if case .match(let r, let h) = $0 { (r, h) } else { nil } }
    }
}

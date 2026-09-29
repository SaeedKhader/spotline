import Foundation
import SubtitleCore

/// Cleanup tools that rewrite cue text on-device, by rule. Like every AI tool
/// they only propose: the result is a change set the user reviews.
public enum CleanupTool: String, Sendable, CaseIterable {
    /// Masks swear words: "f*** off".
    case maskProfanity
    /// Removes sound descriptions ([door slams], (laughs), ♪) and speaker labels (JOHN:) for non-SDH deliveries.
    case removeHearingImpaired
    /// Fixes spacing and punctuation: double spaces, spaces before punctuation, "..." as "…", Arabic comma and question mark.
    case fixSpacingAndPunctuation

    public var title: String {
        switch self {
        case .maskProfanity: "Mask Profanity"
        case .removeHearingImpaired: "Remove Hearing-Impaired Text"
        case .fixSpacingAndPunctuation: "Fix Spacing and Punctuation"
        }
    }

    /// The proposed edits for `cues`; cues left without text are proposed for removal.
    public func propose(for cues: [Cue], languageCode: String) -> ProposedChangeSet {
        let changes: [ProposedChange] = cues.compactMap { cue in
            let cleaned = clean(cue.text, languageCode: languageCode)
            guard cleaned != cue.text else { return nil }
            if SubtitleText.visibleLines(of: cleaned).joined().allSatisfy(\.isWhitespace), !cue.text.isEmpty {
                return ProposedChange(kind: .delete, cue: cue, note: "Nothing left to show")
            }
            var after = cue
            after.text = cleaned
            // Variants describe the old text; they no longer apply.
            if after.variants != nil { after.variants = nil }
            return ProposedChange.update(from: cue, to: after)
        }
        return ProposedChangeSet(title: title, changes: changes)
    }

    public func clean(_ text: String, languageCode: String) -> String {
        switch self {
        case .maskProfanity: ProfanityFilter.mask(text)
        case .removeHearingImpaired: HearingImpaired.remove(from: text)
        case .fixSpacingAndPunctuation: Punctuation.fix(text, languageCode: languageCode)
        }
    }
}

/// Word lists per language; a listed stem matches the words that start with it.
enum ProfanityFilter {
    static let stems: [String] = [
        // English
        "fuck", "motherfuck", "shit", "bullshit", "bitch", "bastard", "asshole", "dickhead", "cunt", "goddamn", "damn",
        "prick", "wanker", "bollocks", "piss", "slut", "whore", "crap",
        // French
        "merde", "putain", "connard", "connasse", "salaud", "salope", "enculé", "bordel",
        // Spanish
        "mierda", "joder", "cabrón", "cabron", "puta", "coño", "gilipollas", "pendejo",
        // German
        "scheiße", "scheisse", "arschloch", "fotze", "wichser", "verdammt",
        // Arabic
        "كس", "زب", "شرموط", "عاهر", "منيوك", "خول", "لعنة", "تبا",
    ]

    /// Short stems that are also parts of ordinary words match only whole words.
    static let wholeWordOnly: Set<String> = ["crap", "piss", "damn", "puta", "كس", "زب", "تبا"]

    static func mask(_ text: String) -> String {
        var result = ""
        var word = ""
        func flush() {
            result += isProfane(word) ? masked(word) : word
            word = ""
        }
        for character in text {
            if character.isLetter || character == "'" {
                word.append(character)
            } else {
                flush()
                result.append(character)
            }
        }
        flush()
        return result
    }

    static func isProfane(_ word: String) -> Bool {
        let lower = word.lowercased()
        return stems.contains { stem in
            wholeWordOnly.contains(stem) ? lower == stem : lower.hasPrefix(stem)
        }
    }

    /// Keeps the first letter: "f***ing".
    static func masked(_ word: String) -> String {
        guard let first = word.first else { return word }
        return String(first) + String(repeating: "*", count: word.count - 1)
    }
}

enum HearingImpaired {
    static func remove(from text: String) -> String {
        var cleaned = text
        // Sound descriptions in brackets or parentheses, and music notes with what they enclose.
        cleaned = cleaned.replacing(/\[[^\]]*\]/, with: "")
        cleaned = cleaned.replacing(/\([^)]*\)/, with: "")
        cleaned = cleaned.replacing(/♪[^♪\n]*♪?/, with: "")
        cleaned = cleaned.replacing(/[♪♫]/, with: "")
        let lines = cleaned.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            var line = String(line)
            // Speaker labels: "JOHN:" or "MAN 2:" at the start of a line (after an optional dash).
            line = line.replacing(/^(\s*-?\s*)[\p{Lu}][\p{Lu}0-9 .'’-]*:\s*/, with: { $0.output.1 })
            return line.trimmingCharacters(in: .whitespaces)
        }
        let kept = lines.filter { !$0.isEmpty && $0 != "-" }
        // A dialogue dash on a single remaining line is no longer needed.
        if kept.count == 1, let only = kept.first, only.hasPrefix("-") {
            return String(only.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return kept.joined(separator: "\n")
    }
}

enum Punctuation {
    static func fix(_ text: String, languageCode: String) -> String {
        let arabicScript = ["ar", "fa", "ur"].contains(String(languageCode.prefix(2)))
            || text.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var line = String(line)
            line = line.replacing(/[ \t]{2,}/, with: " ")
            line = line.replacing("...", with: "…")
            // No space before closing punctuation (French keeps its spaces before ; : ! ?).
            if languageCode.hasPrefix("fr") {
                line = line.replacing(/\s+([,.…])/, with: { $0.output.1 })
            } else {
                line = line.replacing(/\s+([,.;:!?…؟،])/, with: { $0.output.1 })
            }
            // A space after a comma or full stop that runs into a letter ("Hi,John").
            line = line.replacing(/([,;!?؟،])(\p{L})/, with: { "\($0.output.1) \($0.output.2)" })
            line = line.replacing(/(\p{Ll})\.(\p{Lu})/, with: { "\($0.output.1). \($0.output.2)" })
            if arabicScript {
                line = line.replacing(",", with: "،").replacing("?", with: "؟").replacing(";", with: "؛")
            }
            return line.trimmingCharacters(in: .whitespaces)
        }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

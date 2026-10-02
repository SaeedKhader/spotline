import Foundation
import SubtitleCore

/// Text as translation tools compare it: what a viewer reads, in lower case,
/// without accents or Arabic and Hebrew vowel marks (so أ, إ and آ match ا),
/// without tatweel, with one space between words.
public enum MatchText {
    public static func normalize(_ text: String) -> String {
        let visible = SubtitleText.visibleLines(of: text).joined(separator: " ")
        let folded = visible
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .decomposedStringWithCanonicalMapping
            // Vowel marks and hamza (أ is ا plus a mark once decomposed), which folding leaves on Arabic and Hebrew.
            .unicodeScalars.filter { $0.properties.generalCategory != .nonspacingMark }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
            .replacing("\u{0640}", with: "")
            // Arabic letters that are commonly typed interchangeably.
            .replacing("ى", with: "ي")
            .replacing("ة", with: "ه")
        return folded.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Words (letters and digits) of normalized text.
    static func words(_ normalized: String) -> [Substring] {
        normalized.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
    }

    /// Whether `term` occurs in `text` as whole words. Both are normalized.
    public static func contains(_ text: String, term: String) -> Bool {
        !ranges(of: term, in: text, limit: 1).isEmpty
    }

    /// What Arabic writes onto the front of a word: "the" (ال), and "and", "so", "in", "to", "like"
    /// before it, alone or with the article (والـ, بالـ, للـ).
    static let arabicPrefixes: Set<String> = {
        var prefixes: Set<String> = []
        for conjunction in ["", "و", "ف"] {
            for preposition in ["", "ب", "ل", "ك"] {
                prefixes.insert(conjunction + preposition)
                prefixes.insert(conjunction + preposition + "ال")
            }
            // "to the": the article's alif drops after ل.
            prefixes.insert(conjunction + "لل")
        }
        return prefixes
    }()

    /// Whether `text` uses the translation `term`, as whole words. In Arabic the word may
    /// take the article or a particle on its front, or leave the term's own article off:
    /// "البطولة", "للبطولة" and "وبطولة" all use "بطولة". Both are normalized.
    public static func usesTranslation(_ text: String, of term: String) -> Bool {
        if contains(text, term: term) { return true }
        guard term.unicodeScalars.contains(where: { (0x0600...0x06FF).contains($0.value) }) else { return false }
        let bare = term.hasPrefix("ال") && term.count > 3 ? String(term.dropFirst(2)) : term
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: bare, range: searchRange) {
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            if !(after.map(isWordCharacter) ?? false) {
                // The letters of the same word before it.
                var start = range.lowerBound
                while start > text.startIndex, isWordCharacter(text[text.index(before: start)]) { start = text.index(before: start) }
                if arabicPrefixes.contains(String(text[start..<range.lowerBound])) { return true }
            }
            searchRange = text.index(after: range.lowerBound)..<text.endIndex
        }
        return false
    }

    /// Where `term` occurs in `text` as whole words, in order. Both are normalized.
    static func ranges(of term: String, in text: String, limit: Int = .max) -> [Range<String.Index>] {
        guard !term.isEmpty else { return [] }
        var found: [Range<String.Index>] = []
        var searchRange = text.startIndex..<text.endIndex
        while found.count < limit, let range = text.range(of: term, range: searchRange) {
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            if !(before.map(isWordCharacter) ?? false), !(after.map(isWordCharacter) ?? false) {
                found.append(range)
            }
            searchRange = text.index(after: range.lowerBound)..<text.endIndex
        }
        return found
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    /// 0 to 1: one minus the word-level edit distance over the longer text's word count.
    /// Word level, as translation memories score, so a changed name costs one word.
    static func similarity(_ a: [Substring], _ b: [Substring]) -> Double {
        let longest = max(a.count, b.count)
        guard longest > 0 else { return 1 }
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        let distance = previous[b.count]
        return 1 - Double(distance) / Double(longest)
    }
}

/// Which way a language or a text runs.
public enum TextDirection: Sendable, Equatable {
    case leftToRight
    case rightToLeft

    /// Right to left for Arabic, Hebrew, Persian, Urdu and other RTL languages;
    /// for an unknown language ("und"), from the text's first letters.
    /// (`sample` is only read for an unknown language.)
    public static func of(languageCode: String, sample: @autoclosure () -> String = "") -> TextDirection {
        let language = Locale.Language(identifier: languageCode)
        if languageCode != "und", !languageCode.isEmpty, language.languageCode != nil {
            return language.characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
        }
        return of(text: sample())
    }

    /// From the text's letters: right to left when most are in an RTL script.
    public static func of(text: String) -> TextDirection {
        var rtl = 0, ltr = 0
        for scalar in SubtitleText.visibleLines(of: text).joined().unicodeScalars.prefix(2_000) where scalar.properties.isAlphabetic {
            if isRightToLeft(scalar) { rtl += 1 } else { ltr += 1 }
        }
        return rtl > ltr ? .rightToLeft : .leftToRight
    }

    static func isRightToLeft(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF: true
        default: false
        }
    }
}

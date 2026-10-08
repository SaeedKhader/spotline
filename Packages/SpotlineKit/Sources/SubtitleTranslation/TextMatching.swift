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
            // Curly and straight apostrophes: "King’s Landing" is "King's Landing".
            .replacing(/[\u{2018}\u{2019}\u{02BC}\u{0060}\u{00B4}]/, with: "'")
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

    /// Whether `text` uses the translation `term`, as whole words. In Arabic each word may take
    /// the article, the first a particle too, or leave the term's own article off, and take an
    /// ending: "البطولة", "للبطولة" and "وبطولة" use "بطولة", and "الفارس الجوال" uses "فارس جوال"
    /// (an adjective takes the article with its noun). A name may also be spelled another common
    /// way (`arabicSkeleton`): "لايندينق" uses "لاندينغ". Both are normalized.
    public static func usesTranslation(_ text: String, of term: String) -> Bool {
        if contains(text, term: term) { return true }
        guard isArabic(term) else { return false }
        let stems = term.split(separator: " ").map { word in
            let word = String(word)
            return word.hasPrefix("ال") && word.count > 3 ? String(word.dropFirst(2)) : word
        }
        let words = Self.words(text).map(String.init)
        if usesWithAffixes(words, stems: stems, prefixes: arabicPrefixes, laterPrefixes: ["", "ال"], suffixes: arabicSuffixes, pronouns: arabicPronounSuffixes) {
            return true
        }
        // Short words collide once their vowels go ("سير" and "سار" are both "سر"): only longer names are heard.
        let skeletons = stems.map(arabicSkeleton)
        guard skeletons.joined().count >= 3, !skeletons.contains(where: \.isEmpty) else { return false }
        return usesWithAffixes(
            words.map(arabicSkeleton), stems: skeletons, prefixes: Set(arabicPrefixes.map(arabicSkeleton)), laterPrefixes: ["", "ل"],
            suffixes: Set(arabicSuffixes.map(arabicSkeleton)), pronouns: Set(arabicPronounSuffixes.map(arabicSkeleton))
        )
    }

    /// The stems as consecutive words of `words`, each with only those letters before and after it:
    /// the first word's prefixes, the article on later words, and an ending on any. A word ending in ة
    /// (normalized to ه) writes it ت before a pronoun: بطولة, بطولته.
    private static func usesWithAffixes(
        _ words: [String], stems: [String], prefixes: Set<String>, laterPrefixes: Set<String>, suffixes: Set<String>, pronouns: Set<String>
    ) -> Bool {
        guard !stems.isEmpty, words.count >= stems.count else { return false }
        func matches(_ word: String, _ stem: String, prefixes: Set<String>) -> Bool {
            let forms = [(stem, suffixes)] + (stem.hasSuffix("ه") && stem.count > 2 ? [(String(stem.dropLast()) + "ت", pronouns)] : [])
            for prefix in prefixes where word.hasPrefix(prefix) {
                let rest = word.dropFirst(prefix.count)
                for (form, endings) in forms where rest.hasPrefix(form) && endings.contains(String(rest.dropFirst(form.count))) {
                    return true
                }
            }
            return false
        }
        for start in 0...(words.count - stems.count) {
            let found = stems.indices.allSatisfy { index in
                matches(words[start + index], stems[index], prefixes: index == 0 ? prefixes : laterPrefixes)
            }
            if found { return true }
        }
        return false
    }

    static func isArabic(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) }
    }

    /// Normalized Arabic as a name is heard, not spelled: without the long vowels and hamza
    /// (ا و ي ى ء), and with the letters foreign sounds are written with in different ways
    /// made one (غ, ق, گ and ڨ for "g"; ڤ for "v"; پ for "p"; چ for "ch"). Names transliterated
    /// two ways then agree: "لايندينق" and "لاندينغ" are both "لندنق". Other letters stay.
    public static func arabicSkeleton(_ normalized: String) -> String {
        var result = ""
        for character in normalized {
            switch character {
            case "ا", "و", "ي", "ى", "ء": continue
            case "غ", "گ", "ڨ": result.append("ق")
            case "ڤ": result.append("ف")
            case "پ": result.append("ب")
            case "چ": result.append("ج")
            default: result.append(character)
            }
        }
        return result.split(separator: " ").joined(separator: " ")
    }

    /// Whether two translations are the same word or name: the same once normalized, or for
    /// Arabic, the same as heard (`arabicSkeleton`), so "كينغز لاندينغ" is "كينقز لاندينق".
    public static func sameTranslation(_ a: String, _ b: String) -> Bool {
        let a = normalize(a), b = normalize(b)
        if a == b { return true }
        guard isArabic(a), isArabic(b) else { return false }
        let skeleton = arabicSkeleton(a)
        return skeleton.count >= 3 && skeleton == arabicSkeleton(b)
    }

    /// What Arabic writes onto the end of a word, vowel marks removed: the accusative alif (مرافقًا),
    /// "my", "his", "her", "your", "our", "their" (مرافقه, سيفها), the dual and the sound plurals.
    static let arabicPronounSuffixes: Set<String> = ["ي", "ه", "ها", "هم", "هما", "هن", "ك", "كم", "كما", "كن", "نا"]
    static let arabicSuffixes: Set<String> = arabicPronounSuffixes.union(["", "ا", "ان", "ين", "ون", "ات"])

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

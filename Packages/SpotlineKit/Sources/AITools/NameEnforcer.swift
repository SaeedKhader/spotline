import Foundation
import SubtitleCore

/// Keeps a name spelled one way in a translation: where the source line says
/// a known person's name and the translation spells it differently ("دنك"
/// for "دانك", "آرلن" for "أرلان"), the agreed spelling goes in. Spellings
/// drifted within one episode in the akotsk review; the translator is told
/// them, and this catches what slips through.
public struct NameEnforcer: Sendable {
    /// Source name and agreed spelling.
    public var names: [(source: String, target: String)]

    public init(names: [(source: String, target: String)]) {
        self.names = names.filter { $0.source.count >= 2 && Self.normalize($0.target).count >= 3 }
    }

    public init(cast: [CastMember]) {
        self.init(names: cast.compactMap { person in person.translatedName.map { (person.name, $0) } })
    }

    public var isEmpty: Bool { names.isEmpty }

    /// The translation with every drifted spelling of a name the source uses replaced.
    public func apply(to text: String, source: String) -> String {
        var text = text
        for name in names where Self.mentions(source, name.source) {
            let agreed = Self.normalize(name.target)
            var words = text.components(separatedBy: " ")
            for (index, word) in words.enumerated() {
                let (prefix, _, normalized, suffix) = Self.core(of: word)
                guard normalized.count >= 3, normalized != agreed, Self.isDrift(normalized, of: agreed) else { continue }
                words[index] = prefix + name.target + suffix
            }
            text = words.joined(separator: " ")
        }
        return text
    }

    /// True when `source` has `name` as a whole word (or words), ignoring case.
    static func mentions(_ source: String, _ name: String) -> Bool {
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: name) + "(?![\\p{L}\\p{N}])"
        return source.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// A word split into what surrounds the name: a one-letter Arabic prefix
    /// (و ف ب ل ك), punctuation and brackets before and after.
    static func core(of word: String) -> (prefix: String, core: String, normalized: String, suffix: String) {
        let punctuation = CharacterSet.punctuationCharacters.union(.symbols).union(["(", ")", "«", "»", "\"", "\u{200F}", "\u{202B}", "\u{202C}"])
        var prefix = String(word.prefix { $0.unicodeScalars.allSatisfy(punctuation.contains) })
        var rest = String(word.dropFirst(prefix.count))
        let suffix = String(rest.reversed().prefix { $0.unicodeScalars.allSatisfy(punctuation.contains) }.reversed())
        rest = String(rest.dropLast(suffix.count))
        var normalized = normalize(rest)
        if let first = rest.first, "وفبلك".contains(first), rest.count > 3 {
            let stripped = String(rest.dropFirst())
            // Only when the rest is the name's length or so; "وحده" is not a prefixed name.
            if normalize(stripped).count >= 3 {
                prefix += String(first)
                rest = stripped
                normalized = normalize(stripped)
            }
        }
        return (prefix, rest, normalized, suffix)
    }

    /// One or two letters off, by length: a spelling of the same name.
    static func isDrift(_ word: String, of agreed: String) -> Bool {
        let allowed = min(word.count, agreed.count) >= 5 ? 2 : 1
        guard abs(word.count - agreed.count) <= allowed, word.first == agreed.first || word.last == agreed.last else { return false }
        return distance(word, agreed) <= allowed
    }

    /// Arabic letters without diacritics or tatweel, with alef, yeh and teh marbuta forms unified.
    static func normalize(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x064B...0x065F, 0x0670, 0x0640: continue
            case 0x0622, 0x0623, 0x0625, 0x0671: result.unicodeScalars.append("ا")
            case 0x0649: result.unicodeScalars.append("ي")
            case 0x0629: result.unicodeScalars.append("ه")
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result.lowercased()
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var previous = row[0]
            row[0] = i
            for j in 1...max(b.count, 1) where !b.isEmpty {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return a.isEmpty ? b.count : row[b.count]
    }
}

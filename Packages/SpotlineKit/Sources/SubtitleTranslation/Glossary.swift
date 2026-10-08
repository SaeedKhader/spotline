import Foundation

/// Agreed translations of names and terms for one language pair.
public struct Glossary: Hashable, Sendable, Codable {
    public var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    public struct Entry: Identifiable, Hashable, Sendable, Codable {
        public let id: UUID
        public var source: String
        public var target: String
        public var note: String
        /// The show it belongs to ("A Knight of the Seven Kingdoms"), nil for every show of the language pair.
        public var show: String?
        /// Other translations accepted for the term ("السبعة" beside "الآلهة السبعة"): a line using
        /// one uses the term. The translator is given `target`.
        public var alternatives: [String]

        public init(id: UUID = UUID(), source: String, target: String, note: String = "", show: String? = nil, alternatives: [String] = []) {
            self.id = id
            self.source = source
            self.target = target
            self.note = note
            self.show = show
            self.alternatives = alternatives
        }

        private enum CodingKeys: String, CodingKey {
            case id, source, target, note, show, alternatives
        }

        /// Entries saved before alternatives have none.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            source = try container.decode(String.self, forKey: .source)
            target = try container.decode(String.self, forKey: .target)
            note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
            show = try container.decodeIfPresent(String.self, forKey: .show)
            alternatives = try container.decodeIfPresent([String].self, forKey: .alternatives) ?? []
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(source, forKey: .source)
            try container.encode(target, forKey: .target)
            try container.encode(note, forKey: .note)
            try container.encodeIfPresent(show, forKey: .show)
            if !alternatives.isEmpty { try container.encode(alternatives, forKey: .alternatives) }
        }
    }

    /// A term as the glossary tells terms apart: normalized (`MatchText`), without a leading
    /// "the", "a" or "an". "The Reach", "the Reach" and "Reach" are one term.
    public static func key(_ source: String) -> String {
        var key = MatchText.normalize(source)
        for article in ["the ", "a ", "an "] where key.hasPrefix(article) && key.count > article.count {
            key.removeFirst(article.count)
            break
        }
        return key
    }

    /// The entry for a term, by `key`.
    public func entry(for source: String) -> Entry? {
        let key = Self.key(source)
        return entries.first { Self.key($0.source) == key }
    }

    /// Joins entries that are one term with the same translation (or the same name spelled another
    /// common way, `MatchText.sameTranslation`), keeping the first (a show's over the general one)
    /// with the notes of both. Ones that disagree stay, for the user to pick.
    public mutating func mergeDuplicates() {
        var kept: [Entry] = []
        for entry in entries {
            let key = Self.key(entry.source)
            if let index = kept.firstIndex(where: { Self.key($0.source) == key && MatchText.sameTranslation($0.target, entry.target) }) {
                if kept[index].note.isEmpty { kept[index].note = entry.note }
                if kept[index].show == nil { kept[index].show = entry.show }
                for alternative in entry.alternatives where !kept[index].alternatives.contains(alternative) { kept[index].alternatives.append(alternative) }
            } else {
                kept.append(entry)
            }
        }
        entries = kept
    }

    /// For each entry another entry of the same term translates differently: that other translation.
    public var disagreements: [UUID: String] {
        var result: [UUID: String] = [:]
        let keyed = entries.map { (entry: $0, key: Self.key($0.source)) }
        for item in keyed {
            if let other = keyed.first(where: {
                $0.entry.id != item.entry.id && $0.key == item.key && !MatchText.sameTranslation($0.entry.target, item.entry.target)
            }) {
                result[item.entry.id] = other.entry.target
            }
        }
        return result
    }

    /// A glossary term found in a source cue, and whether the target uses its translation.
    public struct Match: Hashable, Sendable {
        public var entry: Entry
        /// True when the target text contains the agreed translation (or it has none); in
        /// Arabic, with or without the article or a particle on its front (`MatchText.usesTranslation`).
        public var isUsed: Bool

        public init(entry: Entry, isUsed: Bool) {
            self.entry = entry
            self.isUsed = isUsed
        }
    }

    /// The entries whose source term occurs in `source` as whole words (ignoring
    /// case and accents), in source order, and whether `target` uses them.
    public func matches(source: String, target: String) -> [Match] {
        let index = GlossaryIndex(self)
        let normalizedTarget = MatchText.normalize(target)
        return index.entries(inSource: source).map { Match(entry: $0, isUsed: index.isUsed($0, inNormalizedTarget: normalizedTarget)) }
    }

    /// Entries read from CSV or tab-separated text: source, target and an optional
    /// note per line. A header line ("source,target…") is skipped.
    public static func entries(fromDelimited text: String) -> [Entry] {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let first = lines.first else { return [] }
        let separator: Character = first.contains("\t") ? "\t" : first.contains(";") && !first.contains(",") ? ";" : ","
        var entries: [Entry] = []
        for (index, line) in lines.enumerated() {
            let fields = parseFields(line.replacing("\u{FEFF}", with: ""), separator: separator)
            guard fields.count >= 2 else { continue }
            let source = fields[0].trimmingCharacters(in: .whitespaces)
            let target = fields[1].trimmingCharacters(in: .whitespaces)
            if index == 0, ["source", "term", "source term"].contains(source.lowercased()) { continue }
            guard !source.isEmpty else { continue }
            let note = fields.count > 2 ? fields[2].trimmingCharacters(in: .whitespaces) : ""
            entries.append(Entry(source: source, target: target, note: note))
        }
        return entries
    }

    /// Adds entries; one with the same term (`key`) as an existing entry replaces its translation and note,
    /// and moves it to the new entry's show.
    public mutating func merge(_ new: [Entry]) {
        for entry in new {
            if let index = entries.firstIndex(where: { Self.key($0.source) == Self.key(entry.source) }) {
                entries[index].target = entry.target
                if !entry.note.isEmpty { entries[index].note = entry.note }
                if entry.show != nil { entries[index].show = entry.show }
            } else {
                entries.append(entry)
            }
        }
    }

    /// Splits one CSV line, honouring double quotes.
    private static func parseFields(_ line: String, separator: Character) -> [String] {
        var fields: [String] = []
        var field = ""
        var quoted = false
        var iterator = line.makeIterator()
        var previousWasQuote = false
        while let character = iterator.next() {
            if character == "\"" {
                if quoted, previousWasQuote {
                    field.append("\"")
                    previousWasQuote = false
                    continue
                }
                quoted.toggle()
                previousWasQuote = !quoted
                continue
            }
            previousWasQuote = false
            if character == separator, !quoted {
                fields.append(field)
                field = ""
            } else {
                field.append(character)
            }
        }
        fields.append(field)
        return fields
    }
}

/// A glossary with its terms normalized once, for checking many cues.
public struct GlossaryIndex: Sendable {
    private let terms: [(entry: Glossary.Entry, term: String, translations: [String])]

    public init(_ glossary: Glossary) {
        // Matched with its article: "the Seven" (the gods) is not "seven" (the number). Duplicates are told apart by `Glossary.key`.
        terms = glossary.entries.map { ($0, MatchText.normalize($0.source), ([$0.target] + $0.alternatives).map(MatchText.normalize)) }
    }

    public var isEmpty: Bool { terms.isEmpty }

    /// Entries whose source term occurs in `source` as whole words, in source order.
    /// The longest term wins: where a term sits inside a longer one that is there too
    /// ("the Seven" in "the Seven Kingdoms"), only the longer one counts. The shorter
    /// one still counts where it stands by itself.
    public func entries(inSource source: String) -> [Glossary.Entry] {
        guard !terms.isEmpty else { return [] }
        let source = MatchText.normalize(source)
        guard !source.isEmpty else { return [] }
        let found = terms.map { MatchText.ranges(of: $0.term, in: source) }
        let all = found.joined()
        return zip(terms, found).compactMap { item, ranges -> (Glossary.Entry, String.Index)? in
            let standing = ranges.first { range in
                !all.contains { $0 != range && $0.lowerBound <= range.lowerBound && range.upperBound <= $0.upperBound }
            }
            return standing.map { (item.entry, $0.lowerBound) }
        }
        .sorted { $0.1 < $1.1 }
        .map(\.0)
    }

    /// Whether normalized target text (see `MatchText.normalize`) uses the entry's translation, or one of its alternatives.
    public func isUsed(_ entry: Glossary.Entry, inNormalizedTarget target: String) -> Bool {
        let translations = terms.first { $0.entry.id == entry.id }?.translations ?? ([entry.target] + entry.alternatives).map(MatchText.normalize)
        return translations.first?.isEmpty == true || translations.contains { !$0.isEmpty && MatchText.usesTranslation(target, of: $0) }
    }
}

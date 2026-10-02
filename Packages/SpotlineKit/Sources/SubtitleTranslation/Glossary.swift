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

        public init(id: UUID = UUID(), source: String, target: String, note: String = "") {
            self.id = id
            self.source = source
            self.target = target
            self.note = note
        }
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

    /// Adds entries; one with the same source term as an existing entry replaces its translation and note.
    public mutating func merge(_ new: [Entry]) {
        for entry in new {
            if let index = entries.firstIndex(where: { MatchText.normalize($0.source) == MatchText.normalize(entry.source) }) {
                entries[index].target = entry.target
                if !entry.note.isEmpty { entries[index].note = entry.note }
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
    private let terms: [(entry: Glossary.Entry, term: String, translation: String)]

    public init(_ glossary: Glossary) {
        terms = glossary.entries.map { ($0, MatchText.normalize($0.source), MatchText.normalize($0.target)) }
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

    /// Whether normalized target text (see `MatchText.normalize`) uses the entry's translation.
    public func isUsed(_ entry: Glossary.Entry, inNormalizedTarget target: String) -> Bool {
        let translation = terms.first { $0.entry.id == entry.id }?.translation ?? MatchText.normalize(entry.target)
        return translation.isEmpty || MatchText.usesTranslation(target, of: translation)
    }
}

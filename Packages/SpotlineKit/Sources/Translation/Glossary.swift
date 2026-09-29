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
        /// True when the target text contains the agreed translation (or it has none).
        public var isUsed: Bool
    }

    /// The entries whose source term occurs in `source` as whole words (ignoring
    /// case and accents), in source order, and whether `target` uses them.
    public func matches(source: String, target: String) -> [Match] {
        let source = MatchText.normalize(source)
        guard !source.isEmpty else { return [] }
        let target = MatchText.normalize(target)
        return entries.compactMap { entry -> (Match, String.Index)? in
            let term = MatchText.normalize(entry.source)
            guard MatchText.contains(source, term: term), let position = source.range(of: term)?.lowerBound else { return nil }
            let translation = MatchText.normalize(entry.target)
            let isUsed = translation.isEmpty || MatchText.contains(target, term: translation)
            return (Match(entry: entry, isUsed: isUsed), position)
        }
        .sorted { $0.1 < $1.1 }
        .map(\.0)
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

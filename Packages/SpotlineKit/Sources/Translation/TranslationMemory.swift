import Foundation

/// Source and target pairs already translated, suggested again when the same
/// or a similar line comes up (in this file, the next episode or a sequel).
public struct TranslationMemory: Hashable, Sendable, Codable {
    public private(set) var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    public struct Entry: Hashable, Sendable, Codable {
        public var source: String
        public var target: String
        public var updated: Date

        public init(source: String, target: String, updated: Date = Date()) {
            self.source = source
            self.target = target
            self.updated = updated
        }
    }

    public struct Match: Hashable, Sendable {
        public var entry: Entry
        /// 0 to 1; 1 for an exact match.
        public var score: Double
        /// Same text once case, accents, markup and spacing are ignored.
        public var isExact: Bool

        /// "100%", "87%".
        public var percent: String { "\(Int((score * 100).rounded(.down)))%" }
    }

    /// Scores below this are not suggested (the usual fuzzy threshold of translation tools).
    public static let fuzzyThreshold = 0.7

    /// Remembers a translation. A pair whose source is already stored replaces it.
    /// Empty sources or targets are ignored.
    public mutating func record(source: String, target: String, at date: Date = Date()) {
        let key = MatchText.normalize(source)
        guard !key.isEmpty, !MatchText.normalize(target).isEmpty else { return }
        if let index = entries.firstIndex(where: { MatchText.normalize($0.source) == key }) {
            guard entries[index].target != target || entries[index].source != source else { return }
            entries.remove(at: index)
        }
        entries.append(Entry(source: source, target: target, updated: date))
    }

    /// The best matches for `source`, best first: exact ones, then fuzzy ones
    /// scoring at least `fuzzyThreshold`. Ties go to the most recent.
    public func matches(for source: String, limit: Int = 3) -> [Match] {
        let key = MatchText.normalize(source)
        guard !key.isEmpty else { return [] }
        let words = MatchText.words(key)
        var found: [Match] = []
        for entry in entries {
            let other = MatchText.normalize(entry.source)
            if other == key {
                found.append(Match(entry: entry, score: 1, isExact: true))
                continue
            }
            let otherWords = MatchText.words(other)
            // Skip pairs whose lengths alone rule out the threshold.
            let shorter = Double(min(words.count, otherWords.count)), longer = Double(max(words.count, otherWords.count))
            guard longer > 0, shorter / longer >= Self.fuzzyThreshold else { continue }
            var score = MatchText.similarity(words, otherWords)
            // Same words, different punctuation: nearly exact.
            if score == 1 { score = 0.99 }
            if score >= Self.fuzzyThreshold { found.append(Match(entry: entry, score: score, isExact: false)) }
        }
        return Array(found.sorted { ($0.score, $0.entry.updated) > ($1.score, $1.entry.updated) }.prefix(limit))
    }

    /// The exact match for `source`, if any.
    public func exactMatch(for source: String) -> Entry? {
        let key = MatchText.normalize(source)
        guard !key.isEmpty else { return nil }
        return entries.last { MatchText.normalize($0.source) == key }
    }
}

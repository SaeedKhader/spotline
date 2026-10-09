import Foundation

/// Where glossaries and translation memories are kept: one folder per language
/// pair (e.g. `en-ar`) with `glossary.json` (terms for every show), `shows/<show>.json`
/// (one show's names and terms) and `memory.json`.
///
/// Until Spotline has project files, both live in Application Support and are
/// shared by every file of the pair. The glossary moves into the project
/// package when there is one; the memory stays shared, as in translation tools.
public struct TranslationStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Application Support/<bundle id>/Translation`.
    public static var standard: TranslationStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let bundle = Bundle.main.bundleIdentifier ?? "Spotline"
        return TranslationStore(directory: support.appending(path: bundle).appending(path: "Translation"))
    }

    /// "en-ar": the base languages of the two tags ("und" when unknown).
    public static func pairKey(source: String, target: String) -> String {
        func base(_ tag: String) -> String {
            let language = tag.split(separator: "-").first.map { $0.lowercased() } ?? ""
            return language.isEmpty ? "und" : language
        }
        return "\(base(source))-\(base(target))"
    }

    /// The pair's glossary: the show's terms (`shows/<show>.json`) first, then those for every show
    /// (`glossary.json`), each entry knowing which. Duplicates with one translation are joined.
    public func glossary(pair: String, show: String? = nil) -> Glossary {
        let general = load(Glossary.self, pair: pair, file: "glossary.json") ?? Glossary()
        var entries = general.entries.map { entry -> Glossary.Entry in
            var entry = entry
            entry.show = nil
            return entry
        }
        if let show, let file = Self.showFile(show), let own = load(Glossary.self, pair: pair, file: file) {
            entries = own.entries.map { entry -> Glossary.Entry in
                var entry = entry
                entry.show = show
                return entry
            } + entries
        }
        var glossary = Glossary(entries: entries)
        glossary.mergeDuplicates()
        return glossary
    }

    /// "shows/a-knight-of-the-seven-kingdoms.json", nil for a name with no letters or digits.
    static func showFile(_ show: String) -> String? {
        let slug = show.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "-")
        return slug.isEmpty ? nil : "shows/\(slug).json"
    }

    public func memory(pair: String) -> TranslationMemory {
        load(TranslationMemory.self, pair: pair, file: "memory.json") ?? TranslationMemory()
    }

    /// Saves the general terms to `glossary.json` and `show`'s to its own file. Terms of
    /// another show are not in a loaded glossary, so they are left as they are.
    public func save(_ glossary: Glossary, pair: String, show: String? = nil) throws {
        func stripped(_ entries: [Glossary.Entry]) -> Glossary {
            Glossary(entries: entries.map { entry in
                var entry = entry
                entry.show = nil
                return entry
            })
        }
        try save(stripped(glossary.entries.filter { $0.show == nil }), pair: pair, file: "glossary.json")
        if let show, let file = Self.showFile(show) {
            try save(stripped(glossary.entries.filter { $0.show == show }), pair: pair, file: file)
        }
    }

    public func save(_ memory: TranslationMemory, pair: String) throws {
        try save(memory, pair: pair, file: "memory.json")
    }

    private func load<Value: Decodable>(_ type: Value.Type, pair: String, file: String) -> Value? {
        let url = directory.appending(path: pair).appending(path: file)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    private func save<Value: Encodable>(_ value: Value, pair: String, file: String) throws {
        let url = directory.appending(path: pair).appending(path: file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

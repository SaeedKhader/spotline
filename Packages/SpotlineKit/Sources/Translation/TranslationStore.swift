import Foundation

/// Where glossaries and translation memories are kept: one folder per language
/// pair (e.g. `en-ar`) with `glossary.json` and `memory.json`.
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

    public func glossary(pair: String) -> Glossary {
        load(Glossary.self, pair: pair, file: "glossary.json") ?? Glossary()
    }

    public func memory(pair: String) -> TranslationMemory {
        load(TranslationMemory.self, pair: pair, file: "memory.json") ?? TranslationMemory()
    }

    public func save(_ glossary: Glossary, pair: String) throws {
        try save(glossary, pair: pair, file: "glossary.json")
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
        let folder = directory.appending(path: pair)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: folder.appending(path: file), options: .atomic)
    }
}

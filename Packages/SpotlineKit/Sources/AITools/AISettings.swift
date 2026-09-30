import Foundation
import Security

/// Which providers the AI tools use, and whether anything may leave the Mac.
/// On-device is the default; cloud is opt-in, since pro content is often under NDA.
public struct AISettings: Sendable, Equatable {
    public enum TranscriptionProvider: String, Sendable, CaseIterable, Identifiable {
        /// Apple's SpeechAnalyzer: models managed by macOS, nothing leaves the Mac.
        case appleSpeech
        /// OpenAI's Whisper API, sent as Opus audio.
        case openAIWhisper
        /// ElevenLabs Scribe, sent as Opus audio.
        case elevenLabsScribe

        public var id: String { rawValue }
        public var isCloud: Bool { self != .appleSpeech }
        public var title: String {
            switch self {
            case .appleSpeech: "On this Mac (Apple Speech)"
            case .openAIWhisper: "OpenAI Whisper (cloud)"
            case .elevenLabsScribe: "ElevenLabs Scribe (cloud)"
            }
        }
    }

    public enum TranslationProvider: String, Sendable, CaseIterable, Identifiable {
        /// Apple's Translation framework with downloaded languages.
        case appleTranslation
        /// Claude Opus, with the scene, glossary and memory as context; flags lines that read
        /// more than one way and writes their variants.
        case claude
        /// The same with Claude Sonnet, at half the price.
        case claudeSonnet

        public var id: String { rawValue }
        public var isCloud: Bool { self != .appleTranslation }
        public var title: String {
            switch self {
            case .appleTranslation: "On this Mac (Apple Translation)"
            case .claude: "Claude Opus (cloud)"
            case .claudeSonnet: "Claude Sonnet (cloud, half the price)"
            }
        }

        /// The Claude model, for the Claude providers.
        public var claudeModel: String? {
            switch self {
            case .appleTranslation: nil
            case .claude: ClaudeTranslator.defaultModel
            case .claudeSonnet: ClaudeTranslator.sonnetModel
            }
        }
    }

    public var transcription: TranscriptionProvider = .appleSpeech
    public var translation: TranslationProvider = .appleTranslation
    /// Off by default: the user allows sending audio and text to cloud providers.
    public var allowsCloud = false
    /// The spoken language for transcription, nil to use the audio track's language (else the Mac's).
    public var transcriptionLanguage: String?
    /// After translating, joins short lines and sentences split over two cues (`CueJoiner`).
    public var joinsLinesAfterTranslating = true
    /// House style for translations.
    public var translationStyle = TranslationStyle()

    public init() {}

    static let transcriptionKey = "AITranscriptionProvider"
    static let translationKey = "AITranslationProvider"
    static let allowsCloudKey = "AIAllowsCloud"
    static let languageKey = "AITranscriptionLanguage"
    static let joinsLinesKey = "AIJoinsLinesAfterTranslating"
    static let registerKey = "AITranslationRegister"
    static let dropsFinalPunctuationKey = "AIDropsFinalPunctuation"
    static let namesInParenthesesKey = "AINamesInParentheses"

    public static func load(from defaults: UserDefaults?) -> AISettings {
        var settings = AISettings()
        guard let defaults else { return settings }
        settings.transcription = defaults.string(forKey: transcriptionKey).flatMap(TranscriptionProvider.init) ?? .appleSpeech
        settings.translation = defaults.string(forKey: translationKey).flatMap(TranslationProvider.init) ?? .appleTranslation
        settings.allowsCloud = defaults.bool(forKey: allowsCloudKey)
        settings.transcriptionLanguage = defaults.string(forKey: languageKey)
        settings.joinsLinesAfterTranslating = defaults.object(forKey: joinsLinesKey) as? Bool ?? true
        settings.translationStyle.register = defaults.string(forKey: registerKey).flatMap(TranslationStyle.Register.init) ?? .faithful
        settings.translationStyle.dropsFinalPunctuation = defaults.object(forKey: dropsFinalPunctuationKey) as? Bool ?? true
        settings.translationStyle.namesInParentheses = defaults.bool(forKey: namesInParenthesesKey)
        return settings
    }

    public func save(to defaults: UserDefaults?) {
        guard let defaults else { return }
        defaults.set(transcription.rawValue, forKey: Self.transcriptionKey)
        defaults.set(translation.rawValue, forKey: Self.translationKey)
        defaults.set(allowsCloud, forKey: Self.allowsCloudKey)
        defaults.set(transcriptionLanguage, forKey: Self.languageKey)
        defaults.set(joinsLinesAfterTranslating, forKey: Self.joinsLinesKey)
        defaults.set(translationStyle.register.rawValue, forKey: Self.registerKey)
        defaults.set(translationStyle.dropsFinalPunctuation, forKey: Self.dropsFinalPunctuationKey)
        defaults.set(translationStyle.namesInParentheses, forKey: Self.namesInParenthesesKey)
    }
}

/// API keys for cloud providers, in the login Keychain.
public struct APIKeyStore: Sendable {
    public enum Provider: String, Sendable, CaseIterable {
        case openAI
        case anthropic
        case elevenLabs

        public var displayName: String {
            switch self {
            case .openAI: "OpenAI"
            case .anthropic: "Anthropic"
            case .elevenLabs: "ElevenLabs"
            }
        }
    }

    public let service: String

    public init(service: String = (Bundle.main.bundleIdentifier ?? "Spotline") + ".ai") {
        self.service = service
    }

    public func key(for provider: Provider) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stores the key, or removes it when `key` is empty.
    @discardableResult
    public func setKey(_ key: String, for provider: Provider) -> Bool {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
        SecItemDelete(match as CFDictionary)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        var item = match
        item[kSecValueData as String] = Data(trimmed.utf8)
        item[kSecAttrLabel as String] = "Spotline \(provider.displayName) API key"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

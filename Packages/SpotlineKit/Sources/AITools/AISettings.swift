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
        /// The same with Claude Haiku, at GPT-6 Luna's price.
        case claudeHaiku
        /// The same prompt and output with OpenAI's GPT-6 Luna, far cheaper still.
        case openAILuna

        public var id: String { rawValue }
        public var isCloud: Bool { self != .appleTranslation }
        public var title: String {
            switch self {
            case .appleTranslation: "On this Mac (Apple Translation)"
            case .claude: "Claude Opus (cloud)"
            case .claudeSonnet: "Claude Sonnet (cloud, half the price)"
            case .claudeHaiku: "Claude Haiku (cloud, as cheap as Luna)"
            case .openAILuna: "OpenAI GPT-6 Luna (cloud, cheapest)"
            }
        }

        /// The provider name for messages ("… needs an API key").
        public var providerName: String {
            switch self {
            case .appleTranslation: "Apple Translation"
            case .claude, .claudeSonnet, .claudeHaiku: "Claude"
            case .openAILuna: "OpenAI GPT-6 Luna"
            }
        }

        /// Whose API key the provider needs, for the cloud providers.
        public var apiKeyProvider: APIKeyStore.Provider? {
            switch self {
            case .appleTranslation: nil
            case .claude, .claudeSonnet, .claudeHaiku: .anthropic
            case .openAILuna: .openAI
            }
        }

        /// The Claude model, for the Claude providers.
        public var claudeModel: String? {
            switch self {
            case .appleTranslation, .openAILuna: nil
            case .claude: ClaudeTranslator.defaultModel
            case .claudeSonnet: ClaudeTranslator.sonnetModel
            case .claudeHaiku: ClaudeTranslator.haikuModel
            }
        }
    }

    /// How long a cloud translator thinks before it answers. More catches more lines
    /// that read two ways and more misheard source, but each batch takes longer.
    public enum ReasoningEffort: String, Sendable, CaseIterable, Identifiable {
        case low
        case medium
        case high

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .low: "Low (fastest)"
            case .medium: "Medium"
            case .high: "High (slowest, most careful)"
            }
        }
    }

    /// The model a helper step uses: the episode brief, the scene descriptions, the script review.
    public enum HelperModel: String, Sendable, CaseIterable, Identifiable {
        case luna = "gpt-6-luna"
        case haiku = "claude-haiku-5-5"
        case sol = "gpt-6.1-sol"

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .luna: "GPT-6 Luna (cheapest)"
            case .haiku: "Claude Haiku (as cheap as Luna)"
            case .sol: "GPT-6.1 Sol (20× the price)"
            }
        }

        /// "GPT-6 Luna", for messages.
        public var name: String {
            switch self {
            case .luna: "GPT-6 Luna"
            case .haiku: "Claude Haiku"
            case .sol: "GPT-6.1 Sol"
            }
        }

        /// What the step needs before it can run.
        public var setupHint: String {
            "It needs \(name): allow cloud AI and add \(self == .haiku ? "an Anthropic" : "an OpenAI") API key in Settings › AI."
        }

        /// Whose API key the step needs.
        public var apiKeyProvider: APIKeyStore.Provider { self == .haiku ? .anthropic : .openAI }

        /// List price next to Luna's, for the plan's rough costs.
        public var priceFactor: Double { self == .sol ? 20 : 1 }
    }

    /// The model and effort of one helper step, chosen in the Translate with AI plan.
    public struct Step: Sendable, Equatable {
        public var model: HelperModel
        public var effort: ReasoningEffort

        public init(model: HelperModel = .luna, effort: ReasoningEffort = .medium) {
            self.model = model
            self.effort = effort
        }
    }

    public var transcription: TranscriptionProvider = .appleSpeech
    public var translation: TranslationProvider = .appleTranslation
    /// For Claude and GPT-6 Luna. Medium by default: high made Luna slow for little gain.
    public var reasoningEffort: ReasoningEffort = .medium
    /// Off by default: the user allows sending audio and text to cloud providers.
    public var allowsCloud = false
    /// Off by default, and only with `allowsCloud`: a few frames of each scene go to GPT-6 Luna, which
    /// writes who is in view into the episode brief (`SceneDescriber`). Frames give a title away far more than text does.
    public var sendsVideoFrames = false
    /// Whether the episode brief is built by itself after listening to the audio, and the script
    /// reviewed once it is confirmed: the plan's ticks, remembered.
    public var buildsBrief = true
    public var reviewsScript = true
    /// The helper steps' models and efforts. Scenes think longest: a small model reads pictures better with time.
    public var brief = Step()
    public var scenes = Step(effort: .high)
    public var scriptReview = Step()
    /// The spoken language for transcription, nil to use the audio track's language (else the Mac's).
    public var transcriptionLanguage: String?
    /// After translating, joins short lines and sentences split over two cues (`CueJoiner`).
    public var joinsLinesAfterTranslating = true
    /// House style for translations.
    public var translationStyle = TranslationStyle()
    /// Sound descriptions ("(door opens)", "(laughs)") in transcriptions and translations,
    /// for hearing-impaired subtitles. Off: they are left out of both.
    public var includesSoundDescriptions = false
    /// Leaves out walla, crowd chatter under the dialogue: transcription drops voices
    /// far quieter than the dialogue around them (`WallaFilter`), and Claude and
    /// GPT-6 Luna mark crowd lines, which then go. On by default: pro subtitles leave it out.
    public var leavesOutWalla = true
    /// Leaves out lines in a made-up language (High Valyrian, Dothraki), which the
    /// transcriber only guesses at: Claude and GPT-6 Luna mark them, and they go.
    public var leavesOutFictionalLanguages = true

    public init() {}

    static let transcriptionKey = "AITranscriptionProvider"
    static let translationKey = "AITranslationProvider"
    static let effortKey = "AIReasoningEffort"
    static let allowsCloudKey = "AIAllowsCloud"
    static let sendsVideoFramesKey = "AISendsVideoFrames"
    static let buildsBriefKey = "AIBuildsBrief"
    static let reviewsScriptKey = "AIReviewsScript"
    static let briefStepKey = "AIBriefStep"
    static let scenesStepKey = "AIScenesStep"
    static let scriptReviewStepKey = "AIScriptReviewStep"

    /// A step as "gpt-6-luna/medium" in the defaults.
    static func step(_ stored: String?, default fallback: Step) -> Step {
        let parts = stored?.split(separator: "/").map(String.init) ?? []
        guard parts.count == 2, let model = HelperModel(rawValue: parts[0]), let effort = ReasoningEffort(rawValue: parts[1]) else { return fallback }
        return Step(model: model, effort: effort)
    }

    static func stored(_ step: Step) -> String { "\(step.model.rawValue)/\(step.effort.rawValue)" }
    static let languageKey = "AITranscriptionLanguage"
    static let joinsLinesKey = "AIJoinsLinesAfterTranslating"
    static let registerKey = "AITranslationRegister"
    static let soundDescriptionsKey = "AIIncludesSoundDescriptions"
    static let dropsFinalPunctuationKey = "AIDropsFinalPunctuation"
    static let namesInParenthesesKey = "AINamesInParentheses"
    static let wallaKey = "AILeavesOutWalla"
    static let fictionalLanguagesKey = "AILeavesOutFictionalLanguages"

    public static func load(from defaults: UserDefaults?) -> AISettings {
        var settings = AISettings()
        guard let defaults else { return settings }
        settings.transcription = defaults.string(forKey: transcriptionKey).flatMap(TranscriptionProvider.init) ?? .appleSpeech
        settings.translation = defaults.string(forKey: translationKey).flatMap(TranslationProvider.init) ?? .appleTranslation
        settings.reasoningEffort = defaults.string(forKey: effortKey).flatMap(ReasoningEffort.init) ?? .medium
        settings.allowsCloud = defaults.bool(forKey: allowsCloudKey)
        settings.sendsVideoFrames = defaults.bool(forKey: sendsVideoFramesKey)
        settings.buildsBrief = defaults.object(forKey: buildsBriefKey) as? Bool ?? true
        settings.reviewsScript = defaults.object(forKey: reviewsScriptKey) as? Bool ?? true
        settings.brief = step(defaults.string(forKey: briefStepKey), default: settings.brief)
        settings.scenes = step(defaults.string(forKey: scenesStepKey), default: settings.scenes)
        settings.scriptReview = step(defaults.string(forKey: scriptReviewStepKey), default: settings.scriptReview)
        settings.transcriptionLanguage = defaults.string(forKey: languageKey)
        settings.joinsLinesAfterTranslating = defaults.object(forKey: joinsLinesKey) as? Bool ?? true
        settings.translationStyle.register = defaults.string(forKey: registerKey).flatMap(TranslationStyle.Register.init) ?? .faithful
        settings.translationStyle.dropsFinalPunctuation = defaults.object(forKey: dropsFinalPunctuationKey) as? Bool ?? true
        settings.translationStyle.namesInParentheses = defaults.bool(forKey: namesInParenthesesKey)
        settings.includesSoundDescriptions = defaults.bool(forKey: soundDescriptionsKey)
        settings.leavesOutWalla = defaults.object(forKey: wallaKey) as? Bool ?? true
        settings.leavesOutFictionalLanguages = defaults.object(forKey: fictionalLanguagesKey) as? Bool ?? true
        return settings
    }

    public func save(to defaults: UserDefaults?) {
        guard let defaults else { return }
        defaults.set(transcription.rawValue, forKey: Self.transcriptionKey)
        defaults.set(translation.rawValue, forKey: Self.translationKey)
        defaults.set(reasoningEffort.rawValue, forKey: Self.effortKey)
        defaults.set(allowsCloud, forKey: Self.allowsCloudKey)
        defaults.set(sendsVideoFrames, forKey: Self.sendsVideoFramesKey)
        defaults.set(buildsBrief, forKey: Self.buildsBriefKey)
        defaults.set(reviewsScript, forKey: Self.reviewsScriptKey)
        defaults.set(Self.stored(brief), forKey: Self.briefStepKey)
        defaults.set(Self.stored(scenes), forKey: Self.scenesStepKey)
        defaults.set(Self.stored(scriptReview), forKey: Self.scriptReviewStepKey)
        defaults.set(transcriptionLanguage, forKey: Self.languageKey)
        defaults.set(joinsLinesAfterTranslating, forKey: Self.joinsLinesKey)
        defaults.set(translationStyle.register.rawValue, forKey: Self.registerKey)
        defaults.set(translationStyle.dropsFinalPunctuation, forKey: Self.dropsFinalPunctuationKey)
        defaults.set(translationStyle.namesInParentheses, forKey: Self.namesInParenthesesKey)
        defaults.set(includesSoundDescriptions, forKey: Self.soundDescriptionsKey)
        defaults.set(leavesOutWalla, forKey: Self.wallaKey)
        defaults.set(leavesOutFictionalLanguages, forKey: Self.fictionalLanguagesKey)
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

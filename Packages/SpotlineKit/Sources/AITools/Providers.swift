import Foundation
import MediaAnalysis
import SubtitleCore

/// Turns prepared dialogue audio into timed words.
public protocol Transcriber: Sendable {
    /// "Apple Speech (on this Mac)".
    var name: String { get }
    /// Seconds by which the model's word start times come before the voice,
    /// corrected by `TranscriptionPipeline`. Measured with `spotline-bench`.
    var wordStartLead: Double { get }
    /// `language` is a BCP 47 code, nil to let the provider detect it. `progress` gets 0 to 1.
    /// `found` gets words as they are heard, in time order, so cues can be shown before the end.
    func transcribe(
        _ audio: PreparedAudio, language: String?, progress: @escaping @Sendable (Double) -> Void,
        found: @escaping @Sendable ([TranscribedWord]) -> Void
    ) async throws -> [TranscribedWord]
}

extension Transcriber {
    public var wordStartLead: Double { 0 }
}

/// Translates cues with their context: neighbouring lines, glossary, memory and the cast.
public protocol CueTranslator: Sendable {
    var name: String { get }
    /// `found` gets each batch of translations as it is done.
    func translate(
        _ request: TranslationRequest, progress: @escaping @Sendable (Double) -> Void,
        found: @escaping @Sendable (TranslationBatch) -> Void
    ) async throws -> TranslationBatch
}

/// What a translator gets: the lines in order, and everything known about them.
public struct TranslationRequest: Sendable, Equatable {
    public struct Line: Sendable, Equatable {
        /// The target cue the translation is for.
        public var cueID: Cue.ID
        public var source: String
        public var start: MediaTime
        public var end: MediaTime
        /// The transcriber's labels for who says it ("speaker_0"), when it told voices apart.
        public var voices: [String]?
        /// The speaker's name when the subtitle file gives one (the ASS Name field).
        public var speakerName: String?
        /// A similar line translated before (translation memory), as an example.
        public var memoryExample: (source: String, target: String)?

        public init(
            cueID: Cue.ID, source: String, start: MediaTime, end: MediaTime, voices: [String]? = nil, speakerName: String? = nil,
            memoryExample: (source: String, target: String)? = nil
        ) {
            self.cueID = cueID
            self.source = source
            self.start = start
            self.end = end
            self.voices = voices
            self.speakerName = speakerName
            self.memoryExample = memoryExample
        }

        public static func == (lhs: Line, rhs: Line) -> Bool {
            lhs.cueID == rhs.cueID && lhs.source == rhs.source && lhs.start == rhs.start && lhs.end == rhs.end
                && lhs.voices == rhs.voices && lhs.speakerName == rhs.speakerName
                && lhs.memoryExample?.source == rhs.memoryExample?.source && lhs.memoryExample?.target == rhs.memoryExample?.target
        }
    }

    public var lines: [Line]
    /// Already translated lines just before the first one, for context.
    public var precedingContext: [(source: String, target: String)]
    public var sourceLanguage: String
    public var targetLanguage: String
    /// Agreed translations (source term, target term, note).
    public var glossary: [(source: String, target: String, note: String)]
    public var maxCharactersPerLine: Int?
    public var maxLines: Int?
    /// The people known so far; confirmed ones are facts the user settled.
    public var cast: [CastMember]

    public init(
        lines: [Line], precedingContext: [(source: String, target: String)] = [], sourceLanguage: String, targetLanguage: String,
        glossary: [(source: String, target: String, note: String)] = [], maxCharactersPerLine: Int? = nil, maxLines: Int? = nil,
        cast: [CastMember] = []
    ) {
        self.lines = lines
        self.precedingContext = precedingContext
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.glossary = glossary
        self.maxCharactersPerLine = maxCharactersPerLine
        self.maxLines = maxLines
        self.cast = cast
    }

    public static func == (lhs: TranslationRequest, rhs: TranslationRequest) -> Bool {
        lhs.lines == rhs.lines && lhs.sourceLanguage == rhs.sourceLanguage && lhs.targetLanguage == rhs.targetLanguage
            && lhs.glossary.map { [$0.source, $0.target, $0.note] } == rhs.glossary.map { [$0.source, $0.target, $0.note] }
            && lhs.precedingContext.map { [$0.source, $0.target] } == rhs.precedingContext.map { [$0.source, $0.target] }
            && lhs.maxCharactersPerLine == rhs.maxCharactersPerLine && lhs.maxLines == rhs.maxLines && lhs.cast == rhs.cast
    }

    /// True when the target language changes "you", verbs or adjectives for someone's gender or number.
    public var targetIsGendered: Bool { Languages.addressesByGender(targetLanguage) }
}

/// One translated line.
public struct CueTranslation: Sendable, Equatable {
    public var cueID: Cue.ID
    public var text: String
    /// Set when the line could be translated more than one way: `text` is the recommended variant.
    public var flag: TranslationFlag?

    public init(cueID: Cue.ID, text: String, flag: TranslationFlag? = nil) {
        self.cueID = cueID
        self.text = text
        self.flag = flag
    }
}

/// Translations, with the people the translator identified on the way.
public struct TranslationBatch: Sendable, Equatable {
    public var translations: [CueTranslation]
    /// Names from the dialogue with genders and voices; merged into the track's cast.
    public var cast: [CastMember]

    public init(translations: [CueTranslation] = [], cast: [CastMember] = []) {
        self.translations = translations
        self.cast = cast
    }

    /// This batch followed by `next`.
    public func adding(_ next: TranslationBatch) -> TranslationBatch {
        var cast = cast
        cast.merge(next.cast)
        return TranslationBatch(translations: translations + next.translations, cast: cast)
    }
}

public enum AIError: Error, LocalizedError, Equatable {
    case cloudNotAllowed
    case missingAPIKey(provider: String)
    case languageNotSupported(String)
    case languageNotInstalled(source: String, target: String)
    case modelDownloadDeclined
    case provider(String)
    case nothingToDo(String)
    /// The model's safety filter declined the request.
    case declined
    /// The answer ran out of room before every line was in.
    case cutOff

    public var errorDescription: String? {
        switch self {
        case .cloudNotAllowed:
            "Cloud AI is off. Turn on “Allow cloud providers” in Settings › AI, or choose an on-device provider."
        case .missingAPIKey(let provider):
            "Add your \(provider) API key in Settings › AI. It is kept in your Keychain."
        case .languageNotSupported(let language):
            "The on-device model does not support \(Languages.name(language))."
        case .languageNotInstalled(let source, let target):
            "Download \(Languages.name(source)) and \(Languages.name(target)) in System Settings › General › Language & Region › Translation Languages, then try again."
        case .modelDownloadDeclined:
            "The speech model was not downloaded."
        case .provider(let message):
            message
        case .nothingToDo(let message):
            message
        case .declined:
            "Claude declined to translate these lines."
        case .cutOff:
            "Claude's answer was cut off. Try fewer lines at once."
        }
    }
}

/// Language facts the AI tools need.
public enum Languages {
    /// Languages whose "you" (and imperatives, verbs, adjectives) change with the listener's or speaker's gender or number.
    public static func addressesByGender(_ code: String) -> Bool {
        ["ar", "he", "fr", "es", "it", "pt", "ru", "uk", "pl", "cs", "hi", "ur", "de", "nl", "el", "ro", "ca"]
            .contains(base(code))
    }

    /// "ar-EG" → "ar", "eng" → "en".
    public static func base(_ code: String) -> String {
        let first = String(code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "").lowercased()
        let threeLetter = ["eng": "en", "ara": "ar", "fre": "fr", "fra": "fr", "ger": "de", "deu": "de", "spa": "es",
                           "ita": "it", "por": "pt", "rus": "ru", "heb": "he", "jpn": "ja", "chi": "zh", "zho": "zh",
                           "kor": "ko", "tur": "tr", "per": "fa", "fas": "fa", "urd": "ur", "hin": "hi", "dut": "nl", "nld": "nl"]
        return threeLetter[first] ?? first
    }

    public static func name(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: base(code)) ?? code
    }
}

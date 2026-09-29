import Foundation
import MediaAnalysis
import SubtitleCore

/// Turns prepared dialogue audio into timed words.
public protocol Transcriber: Sendable {
    /// "Apple Speech (on this Mac)".
    var name: String { get }
    /// `language` is a BCP 47 code, nil to let the provider detect it. `progress` gets 0 to 1.
    /// `found` gets words as they are heard, in time order, so cues can be shown before the end.
    func transcribe(
        _ audio: PreparedAudio, language: String?, progress: @escaping @Sendable (Double) -> Void,
        found: @escaping @Sendable ([TranscribedWord]) -> Void
    ) async throws -> [TranscribedWord]
}

/// Translates cues with their context: neighbouring lines, glossary, memory and who speaks to whom.
public protocol CueTranslator: Sendable {
    var name: String { get }
    /// `found` gets each batch of translations as it is done.
    func translate(
        _ request: TranslationRequest, progress: @escaping @Sendable (Double) -> Void,
        found: @escaping @Sendable ([CueTranslation]) -> Void
    ) async throws -> [CueTranslation]
}

/// What a translator gets: the lines in order, and everything known about them.
public struct TranslationRequest: Sendable, Equatable {
    public struct Line: Sendable, Equatable {
        /// The target cue the translation is for.
        public var cueID: Cue.ID
        public var source: String
        public var start: MediaTime
        public var end: MediaTime
        /// "A", "B"… with gender, when known.
        public var speaker: SpeakerHint?
        /// The addressee as inferred so far, if any.
        public var addressee: AddresseeTag?
        /// A similar line translated before (translation memory), as an example.
        public var memoryExample: (source: String, target: String)?

        public init(
            cueID: Cue.ID, source: String, start: MediaTime, end: MediaTime, speaker: SpeakerHint? = nil,
            addressee: AddresseeTag? = nil, memoryExample: (source: String, target: String)? = nil
        ) {
            self.cueID = cueID
            self.source = source
            self.start = start
            self.end = end
            self.speaker = speaker
            self.addressee = addressee
            self.memoryExample = memoryExample
        }

        public static func == (lhs: Line, rhs: Line) -> Bool {
            lhs.cueID == rhs.cueID && lhs.source == rhs.source && lhs.start == rhs.start && lhs.end == rhs.end
                && lhs.speaker == rhs.speaker && lhs.addressee == rhs.addressee
                && lhs.memoryExample?.source == rhs.memoryExample?.source && lhs.memoryExample?.target == rhs.memoryExample?.target
        }
    }

    public struct SpeakerHint: Sendable, Equatable {
        public var label: String
        public var gender: Gender
        public var confidence: Double

        public init(label: String, gender: Gender, confidence: Double) {
            self.label = label
            self.gender = gender
            self.confidence = confidence
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

    public init(
        lines: [Line], precedingContext: [(source: String, target: String)] = [], sourceLanguage: String, targetLanguage: String,
        glossary: [(source: String, target: String, note: String)] = [], maxCharactersPerLine: Int? = nil, maxLines: Int? = nil
    ) {
        self.lines = lines
        self.precedingContext = precedingContext
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.glossary = glossary
        self.maxCharactersPerLine = maxCharactersPerLine
        self.maxLines = maxLines
    }

    public static func == (lhs: TranslationRequest, rhs: TranslationRequest) -> Bool {
        lhs.lines == rhs.lines && lhs.sourceLanguage == rhs.sourceLanguage && lhs.targetLanguage == rhs.targetLanguage
            && lhs.glossary.map { [$0.source, $0.target, $0.note] } == rhs.glossary.map { [$0.source, $0.target, $0.note] }
            && lhs.precedingContext.map { [$0.source, $0.target] } == rhs.precedingContext.map { [$0.source, $0.target] }
            && lhs.maxCharactersPerLine == rhs.maxCharactersPerLine && lhs.maxLines == rhs.maxLines
    }

    /// True when the target language conjugates "you" (and imperatives) for the addressee's gender and number.
    public var targetIsGendered: Bool { Languages.addressesByGender(targetLanguage) }
}

/// One translated line.
public struct CueTranslation: Sendable, Equatable {
    public var cueID: Cue.ID
    public var text: String
    /// Who the translator took the line to be spoken to, when it matters for the target language.
    public var addressee: AddresseeTag?
    /// The line for other addressees, when the translator was unsure.
    public var variants: [TextVariant]?

    public init(cueID: Cue.ID, text: String, addressee: AddresseeTag? = nil, variants: [TextVariant]? = nil) {
        self.cueID = cueID
        self.text = text
        self.addressee = addressee
        self.variants = variants
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
        }
    }
}

/// Language facts the AI tools need.
public enum Languages {
    /// Languages whose "you" (and imperatives, verbs, adjectives) change with the addressee's gender or number.
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

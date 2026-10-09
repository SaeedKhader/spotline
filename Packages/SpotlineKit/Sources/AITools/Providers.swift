import Foundation
import MediaAnalysis
import SubtitleCore

/// How far a provider has got, in the terms of what it is doing now, so the
/// editor can say it: a fraction only where one is measured, else what it waits for.
public enum AIProgress: Sendable, Equatable {
    /// Working on this Mac: 0 to 1.
    case fraction(Double)
    /// Compressing the audio before it goes up: 0 to 1.
    case encoding(Double)
    /// Sending the audio: bytes sent of the total.
    case uploading(sent: Int64, total: Int64)
    /// The provider has everything and is working; nothing says how far it has got.
    case waiting
    /// Audio sent in parts: parts done of the total.
    case parts(done: Int, total: Int)
    /// Lines translated of the total, and the cues of the lines being translated now.
    case lines(done: Int, total: Int, inFlight: [Cue.ID])
    /// Asking again for lines a model left out or declined.
    case retrying(inFlight: [Cue.ID])
}

/// Turns prepared dialogue audio into timed words.
public protocol Transcriber: Sendable {
    /// "Apple Speech (on this Mac)".
    var name: String { get }
    /// Seconds by which the model's word start times come before the voice,
    /// corrected by `TranscriptionPipeline`. Measured with `spotline-bench`.
    var wordStartLead: Double { get }
    /// True when the audio goes up in one piece, so compressing and sending it are steps of their own.
    var uploadsInOnePiece: Bool { get }
    /// `language` is a BCP 47 code, nil to let the provider detect it.
    /// `found` gets words as they are heard, in time order, so cues can be shown before the end.
    func transcribe(
        _ audio: PreparedAudio, language: String?, progress: @escaping @Sendable (AIProgress) -> Void,
        found: @escaping @Sendable ([TranscribedWord]) -> Void
    ) async throws -> [TranscribedWord]
}

extension Transcriber {
    public var wordStartLead: Double { 0 }
    public var uploadsInOnePiece: Bool { false }
}

/// Translates cues with their context: neighbouring lines, glossary, memory and the cast.
public protocol CueTranslator: Sendable {
    var name: String { get }
    /// `found` gets each batch of translations as it is done.
    func translate(
        _ request: TranslationRequest, progress: @escaping @Sendable (AIProgress) -> Void,
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
        /// Words the transcriber was unsure of in the source.
        public var unsureWords: [String]?
        /// How far (dB) the line's voice is under the dialogue around it, when the audio
        /// says: a sign of crowd chatter (`WallaFilter.quieterBy`).
        public var quieterBy: Float?

        public init(
            cueID: Cue.ID, source: String, start: MediaTime, end: MediaTime, voices: [String]? = nil, speakerName: String? = nil,
            memoryExample: (source: String, target: String)? = nil, unsureWords: [String]? = nil
        ) {
            self.cueID = cueID
            self.source = source
            self.start = start
            self.end = end
            self.voices = voices
            self.speakerName = speakerName
            self.memoryExample = memoryExample
            self.unsureWords = unsureWords
        }

        public static func == (lhs: Line, rhs: Line) -> Bool {
            lhs.cueID == rhs.cueID && lhs.source == rhs.source && lhs.start == rhs.start && lhs.end == rhs.end
                && lhs.voices == rhs.voices && lhs.speakerName == rhs.speakerName && lhs.unsureWords == rhs.unsureWords
                && lhs.memoryExample?.source == rhs.memoryExample?.source && lhs.memoryExample?.target == rhs.memoryExample?.target
                && lhs.quieterBy == rhs.quieterBy
        }
    }

    /// A line of the whole episode's source, for context.
    public struct ScriptLine: Sendable, Equatable {
        public var start: MediaTime
        public var voice: String?
        public var text: String

        public init(start: MediaTime, voice: String? = nil, text: String) {
            self.start = start
            self.voice = voice
            self.text = text
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
    /// What is being translated, e.g. "A Knight of the Seven Kingdoms S01E01 The Hedge Knight".
    public var work: String?
    /// The user's notes for the translator: the show, the setting, who is who.
    public var notes: String?
    /// The episode brief the user confirmed: the plot, the scenes and what the video shows.
    public var brief: String?
    /// The brief's scenes by time, so each batch also gets the scenes its lines are in.
    public var scenes: [EpisodeBrief.TimedScene] = []
    /// True when the source is a subtitle file, whose words are right; false for a transcript, which may be misheard.
    public var sourceIsSubtitles = false
    /// The whole episode's source lines, for context: names, callbacks, what a reply answers.
    public var script: [ScriptLine]
    public var style: TranslationStyle
    /// Asks the translator to mark crowd chatter (walla) instead of translating it.
    public var leavesOutWalla: Bool
    /// Asks the translator to mark lines in a made-up language (High Valyrian, Dothraki,
    /// Klingon) instead of translating the transcriber's guess at them.
    public var leavesOutFictionalLanguages: Bool

    public init(
        lines: [Line], precedingContext: [(source: String, target: String)] = [], sourceLanguage: String, targetLanguage: String,
        glossary: [(source: String, target: String, note: String)] = [], maxCharactersPerLine: Int? = nil, maxLines: Int? = nil,
        cast: [CastMember] = [], work: String? = nil, notes: String? = nil, script: [ScriptLine] = [], style: TranslationStyle = TranslationStyle(),
        leavesOutWalla: Bool = false, leavesOutFictionalLanguages: Bool = false
    ) {
        self.lines = lines
        self.precedingContext = precedingContext
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.glossary = glossary
        self.maxCharactersPerLine = maxCharactersPerLine
        self.maxLines = maxLines
        self.cast = cast
        self.work = work
        self.notes = notes
        self.script = script
        self.style = style
        self.leavesOutWalla = leavesOutWalla
        self.leavesOutFictionalLanguages = leavesOutFictionalLanguages
    }

    public static func == (lhs: TranslationRequest, rhs: TranslationRequest) -> Bool {
        lhs.lines == rhs.lines && lhs.sourceLanguage == rhs.sourceLanguage && lhs.targetLanguage == rhs.targetLanguage
            && lhs.glossary.map { [$0.source, $0.target, $0.note] } == rhs.glossary.map { [$0.source, $0.target, $0.note] }
            && lhs.precedingContext.map { [$0.source, $0.target] } == rhs.precedingContext.map { [$0.source, $0.target] }
            && lhs.maxCharactersPerLine == rhs.maxCharactersPerLine && lhs.maxLines == rhs.maxLines && lhs.cast == rhs.cast
            && lhs.work == rhs.work && lhs.notes == rhs.notes && lhs.script == rhs.script && lhs.style == rhs.style
            && lhs.leavesOutWalla == rhs.leavesOutWalla && lhs.leavesOutFictionalLanguages == rhs.leavesOutFictionalLanguages
    }

    /// True when the target language changes "you", verbs or adjectives for someone's gender or number.
    public var targetIsGendered: Bool { Languages.addressesByGender(targetLanguage) }
}

/// House style for a translation, from Settings › AI.
public struct TranslationStyle: Sendable, Equatable {
    public enum Register: String, Sendable, CaseIterable, Identifiable {
        /// Say what is said: profanity stays profanity, violence stays violence.
        case faithful
        /// Milder, conventional wording for profanity and sex, as broadcasters
        /// in the Arab world use; the meaning never changes.
        case broadcast

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .faithful: "Faithful (say what is said)"
            case .broadcast: "Broadcast (milder wording, same meaning)"
            }
        }
    }

    public var register: Register = .faithful
    /// No full stop or comma at the end of a line, as Arabic subtitles are written.
    public var dropsFinalPunctuation = true
    /// Names in parentheses, "(دانك)", as some Arabic subtitlers write them.
    public var namesInParentheses = false

    public init(register: Register = .faithful, dropsFinalPunctuation: Bool = true, namesInParentheses: Bool = false) {
        self.register = register
        self.dropsFinalPunctuation = dropsFinalPunctuation
        self.namesInParentheses = namesInParentheses
    }

    /// Languages whose subtitles end lines without a full stop.
    public static func endsLinesBare(_ language: String) -> Bool {
        ["ar", "fa", "ur"].contains(Languages.base(language))
    }
}

/// One translated line.
public struct CueTranslation: Sendable, Equatable {
    public var cueID: Cue.ID
    public var text: String
    /// Set when the line could be translated more than one way: `text` is the recommended variant.
    public var flag: TranslationFlag?
    /// Why the line is left out of the subtitles, when it is: `text` is empty and the cue goes.
    public var leftOut: LeftOut?

    /// Lines subtitles leave out.
    public enum LeftOut: Sendable, Equatable {
        /// Crowd chatter under the dialogue.
        case walla
        /// Speech in a made-up language (High Valyrian, Dothraki), which the transcriber only guessed at.
        case fictionalLanguage
    }

    public init(cueID: Cue.ID, text: String, flag: TranslationFlag? = nil, leftOut: LeftOut? = nil) {
        self.cueID = cueID
        self.text = text
        self.flag = flag
        self.leftOut = leftOut
    }

    /// Crowd chatter for a cue: nothing to show.
    public static func walla(_ cueID: Cue.ID) -> CueTranslation {
        CueTranslation(cueID: cueID, text: "", leftOut: .walla)
    }

    /// A line in a made-up language for a cue: nothing to show.
    public static func fictionalLanguage(_ cueID: Cue.ID) -> CueTranslation {
        CueTranslation(cueID: cueID, text: "", leftOut: .fictionalLanguage)
    }

    public var isWalla: Bool { leftOut == .walla }
    public var isLeftOut: Bool { leftOut != nil }

    /// True when the line came back: translated, or marked to be left out.
    public var isAnswered: Bool { isLeftOut || !text.isEmpty }
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
    /// Describing scenes needs frames of the video sent, which is its own switch.
    case videoFramesNotAllowed
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
        case .videoFramesNotAllowed:
            "Sending video frames is off. Turn on “Send video frames” in Settings › AI to have the scenes described."
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

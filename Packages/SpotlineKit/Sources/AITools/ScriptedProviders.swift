import Foundation
import MediaAnalysis
import SubtitleCore

/// Providers with fixed answers, for UI tests (`-UITestMode`) and unit tests:
/// no models, no network, the same result every run.
public struct ScriptedTranscriber: Transcriber {
    public var name: String { "Scripted transcriber" }
    public var words: [TranscribedWord]

    public init(words: [TranscribedWord]) {
        self.words = words
    }

    /// "Hello there. How are you?" and "Fine, thanks." in the first seconds of the test clip.
    public static let fixture = ScriptedTranscriber(words: [
        ("Hello", 0.2, 0.5), ("there.", 0.55, 0.9), ("How", 1.0, 1.2), ("are", 1.25, 1.4), ("you?", 1.45, 1.8),
        ("Fine,", 3.0, 3.4), ("thanks.", 3.45, 3.9),
    ].map { TranscribedWord(text: $0.0, start: MediaTime(seconds: $0.1, timescale: 1000), end: MediaTime(seconds: $0.2, timescale: 1000)) })

    public func transcribe(
        _ audio: PreparedAudio, language: String?, progress: @escaping @Sendable (Double) -> Void,
        found: @escaping @Sendable ([TranscribedWord]) -> Void
    ) async throws -> [TranscribedWord] {
        // In two parts, as a real transcriber finishes chunk by chunk.
        let half = words.count / 2
        found(Array(words[..<half]))
        progress(0.5)
        found(Array(words[half...]))
        progress(1)
        return words
    }
}

/// Translates by tagging each line with the target language ("[fr] Hello"). Into a
/// gendered language, lines with "you" in them are flagged at 60%: spoken to
/// Beth (♀, recommended), to Jerry (♂) or to both, so the review can be exercised.
public struct ScriptedTranslator: CueTranslator {
    public var name: String { "Scripted translator" }

    public init() {}

    public func translate(
        _ request: TranslationRequest, progress: @escaping @Sendable (Double) -> Void,
        found: @escaping @Sendable (TranslationBatch) -> Void
    ) async throws -> TranslationBatch {
        let prefix = "[\(Languages.base(request.targetLanguage))] "
        let translations = request.lines.map { line in
            let text = prefix + line.source
            guard request.targetIsGendered, line.source.lowercased().contains("you") else {
                return CueTranslation(cueID: line.cueID, text: text)
            }
            var flag = TranslationFlag(
                reasons: [.listener],
                variants: [
                    TranslationVariant(text: text + " ♀", listeners: ["Beth"], listenerGender: .female, listenerCount: .one),
                    TranslationVariant(text: text + " ♂", listeners: ["Jerry"], listenerGender: .male, listenerCount: .one),
                    TranslationVariant(text: text + " 👥", listeners: ["Beth", "Jerry"], listenerGender: .mixed, listenerCount: .two),
                ],
                confidence: 0.6, note: "Beth answered last"
            )
            flag.rerank(with: request.cast)
            return CueTranslation(cueID: line.cueID, text: flag.chosenVariant?.text ?? text, flag: flag)
        }
        let batch = TranslationBatch(
            translations: translations,
            cast: request.targetIsGendered ? [CastMember(name: "Beth", gender: .female), CastMember(name: "Jerry", gender: .male)] : []
        )
        found(batch)
        progress(1)
        return batch
    }
}

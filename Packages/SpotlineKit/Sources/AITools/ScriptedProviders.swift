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

/// Translates by tagging each line with the target language ("[fr] Hello"). Lines
/// with "you" in them get a female addressee at 60% with male and group variants,
/// so the review and variant chips can be exercised.
public struct ScriptedTranslator: CueTranslator {
    public var name: String { "Scripted translator" }

    public init() {}

    public func translate(
        _ request: TranslationRequest, progress: @escaping @Sendable (Double) -> Void,
        found: @escaping @Sendable ([CueTranslation]) -> Void
    ) async throws -> [CueTranslation] {
        let prefix = "[\(Languages.base(request.targetLanguage))] "
        let all = request.lines.map { line in
            let text = prefix + line.source
            guard request.targetIsGendered, line.source.lowercased().contains("you") else {
                return CueTranslation(cueID: line.cueID, text: text)
            }
            return CueTranslation(
                cueID: line.cueID, text: text + " ♀", addressee: AddresseeTag(.female, confidence: 0.6),
                variants: [
                    TextVariant(addressee: .female, text: text + " ♀"), TextVariant(addressee: .male, text: text + " ♂"),
                    TextVariant(addressee: .groupMixed, text: text + " 👥"),
                ]
            )
        }
        found(all)
        progress(1)
        return all
    }
}

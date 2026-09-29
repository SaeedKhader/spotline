import Foundation
import MediaAnalysis
import QualityControl
import SubtitleCore

/// What Spotline does with a transcriber's words: corrects the model's timing,
/// then makes cues by the QC preset's rules (`CueSegmenter`). The editor and
/// the benchmark (`spotline-bench`) both run it.
public struct TranscriptionPipeline: Sendable {
    public var segmenter: CueSegmenter
    /// Seconds by which the transcriber's word starts come before the voice (`Transcriber.wordStartLead`).
    public var wordStartLead: Double

    public init(preset: QCPreset, frameRate: FrameRate, shotChanges: [Int64] = [], wordStartLead: Double = 0) {
        segmenter = CueSegmenter(preset: preset, frameRate: frameRate, shotChanges: shotChanges)
        self.wordStartLead = wordStartLead
    }

    /// Cues for the words, in order. Words must be in time order.
    public func cues(from words: [TranscribedWord]) -> [Cue] {
        segmenter.cues(from: corrected(words))
    }

    func corrected(_ words: [TranscribedWord]) -> [TranscribedWord] {
        guard wordStartLead != 0 else { return words }
        let lead = MediaTime(value: Int64((wordStartLead * 1000).rounded()), timescale: 1000)
        return words.map { word in
            var word = word
            word.start = min(word.start + lead, word.end)
            return word
        }
    }
}

/// What Spotline does with a translator's lines before they go into the track.
public struct TranslationPipeline: Sendable {
    public var preset: QCPreset

    public init(preset: QCPreset) {
        self.preset = preset
    }

    public func fix(_ translations: [CueTranslation], request: TranslationRequest) -> [CueTranslation] {
        translations
    }
}

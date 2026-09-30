import Foundation
import MediaAnalysis
import QualityControl
import SubtitleCore
import SubtitleTranslation

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

    /// Cues for the words, in order. Words must be in time order. Hesitations,
    /// stutters and cues of nothing but an interjection are left out (`TranscriptCleanup`).
    public func cues(from words: [TranscribedWord]) -> [Cue] {
        segmenter.cues(from: TranscriptCleanup.words(corrected(words))).filter { !TranscriptCleanup.isOnlyInterjections($0.text) }
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

/// What Spotline does with a translator's lines before they go into the track:
/// the subtitle layout, which translators get wrong (Apple's model turns a line
/// break into a blank line and translates each half as its own sentence).
public struct TranslationPipeline: Sendable {
    public var preset: QCPreset

    public init(preset: QCPreset) {
        self.preset = preset
    }

    public func fix(_ translations: [CueTranslation], request: TranslationRequest) -> [CueTranslation] {
        translations.map { translation in
            var fixed = translation
            fixed.text = layout(translation.text)
            if var flag = translation.flag {
                for index in flag.variants.indices { flag.variants[index].text = layout(flag.variants[index].text) }
                fixed.flag = flag
            }
            return fixed
        }
    }

    public func fix(_ batch: TranslationBatch, request: TranslationRequest) -> TranslationBatch {
        TranslationBatch(translations: fix(batch.translations, request: request), cast: batch.cast)
    }

    /// One line when it fits the preset's line length, else two balanced lines,
    /// with no blank lines or stray spaces. Dialogue (a line per speaker) and
    /// text with markup keep their lines.
    func layout(_ text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !Self.isDialogue(lines), !text.contains("<"), !text.contains("{") else { return lines.joined(separator: "\n") }
        let words = lines.joined(separator: " ").split(separator: " ").map(String.init)
        return CueSegmenter.layout(words, maxLineLength: preset.maxCharactersPerLine ?? 42)
    }

    /// Lines that each start with a dash: one speaker per line.
    static func isDialogue(_ lines: [String]) -> Bool {
        lines.count > 1 && lines.allSatisfy { $0.trimmingCharacters(in: .whitespaces.union(["\u{200F}", "\u{202B}", "\u{200E}"])).hasPrefix("-") }
    }
}

/// Sentences that run over several cues ("I built it out of stuff" / "I found
/// in the garage."). Translators without context translate each cue as a
/// sentence of its own, which garbles the halves; these are joined for the
/// translator and its translation is shared out again by length.
public enum SentenceSpans {
    /// Longest pause inside one sentence, and most cues in one.
    static let maxPauseSeconds = 1.0
    static let maxCues = 3

    /// Indexes of the lines (text, start, end, in time order), grouped by sentence.
    public static func groups(_ lines: [(text: String, start: MediaTime, end: MediaTime)]) -> [[Int]] {
        var groups: [[Int]] = []
        for (index, line) in lines.enumerated() {
            if let last = groups.last?.last, groups[groups.count - 1].count < maxCues,
               continues(lines[last].text, into: line.text), (line.start - lines[last].end).seconds <= maxPauseSeconds {
                groups[groups.count - 1].append(index)
            } else {
                groups.append([index])
            }
        }
        return groups
    }

    /// True when `text` stops mid-sentence and `next` goes on with it: no
    /// closing punctuation (an ellipsis closes: it marks a pause or a break-off),
    /// and neither is dialogue.
    static func continues(_ text: String, into next: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespaces), next = next.trimmingCharacters(in: .whitespaces)
        guard let last = text.last, !next.isEmpty, !text.contains("\n"), !next.contains("\n"),
              !text.hasPrefix("-"), !next.hasPrefix("-")
        else { return false }
        return !".?!…:;\"”»♪)]؟".contains(last)
    }

    /// `text` in as many parts as `sources`, each about as long (relative to
    /// the whole) as its source, cut between words and after punctuation where it can be.
    public static func split(_ text: String, like sources: [String]) -> [String] {
        guard sources.count > 1 else { return [text] }
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= sources.count else { return [text] + Array(repeating: "", count: sources.count - 1) }
        let total = Double(max(sources.reduce(0) { $0 + $1.count }, 1))
        let length = Double(words.reduce(0) { $0 + $1.count + 1 })
        var cuts: [Int] = []
        var share = 0.0
        for source in sources.dropLast() {
            share += Double(source.count) / total
            // Word boundaries after each word; the one nearest the share, a little nearer after punctuation.
            let first = (cuts.last ?? 0) + 1, last = words.count - (sources.count - cuts.count - 1)
            var position = 0.0
            var best: (cut: Int, score: Double)?
            for cut in 1..<words.count {
                position += Double(words[cut - 1].count + 1)
                guard cut >= first, cut < last else { continue }
                var score = abs(position / length - share)
                if let mark = words[cut - 1].last, ",.;:!?،؛؟…".contains(mark) { score -= 0.08 }
                if score < (best?.score ?? .infinity) { best = (cut, score) }
            }
            cuts.append(best?.cut ?? first)
        }
        var parts: [String] = []
        var start = 0
        for cut in cuts + [words.count] {
            parts.append(words[start..<cut].joined(separator: " "))
            start = cut
        }
        return parts
    }
}

/// Puts the agreed translation of glossary terms into a translator's output,
/// for translators that cannot be told the glossary (Apple's): where the
/// source uses a term and the output has the model's own rendering of it, the
/// rendering is replaced.
struct GlossaryEnforcer: Sendable {
    /// Source term, agreed translation, the model's rendering.
    var terms: [(source: String, target: String, rendered: String)]

    func apply(to text: String, source: String) -> String {
        var text = text
        let normalizedSource = MatchText.normalize(source)
        for term in terms where MatchText.contains(normalizedSource, term: MatchText.normalize(term.source)) {
            let rendered = term.rendered.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard !rendered.isEmpty, !MatchText.contains(MatchText.normalize(text), term: MatchText.normalize(term.target)),
                  let range = text.range(of: rendered)
            else { continue }
            text.replaceSubrange(range, with: term.target)
        }
        return text
    }
}

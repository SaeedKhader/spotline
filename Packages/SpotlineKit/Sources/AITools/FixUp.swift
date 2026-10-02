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
    /// Keeps the transcriber's sound descriptions ("(door opens)"), for hearing-impaired subtitles.
    public var keepsSoundDescriptions: Bool
    /// Leaves out crowd chatter under the dialogue, when set (Settings › AI).
    public var walla: WallaFilter?

    public init(
        preset: QCPreset, frameRate: FrameRate, shotChanges: [Int64] = [], wordStartLead: Double = 0, keepsSoundDescriptions: Bool = false,
        walla: WallaFilter? = nil
    ) {
        segmenter = CueSegmenter(preset: preset, frameRate: frameRate, shotChanges: shotChanges)
        self.wordStartLead = wordStartLead
        self.keepsSoundDescriptions = keepsSoundDescriptions
        self.walla = walla
    }

    /// Cues for the words, in order. Words must be in time order. Hesitations,
    /// stutters and cues of nothing but an interjection are left out (`TranscriptCleanup`),
    /// and sound descriptions unless they are kept, and walla when it is filtered.
    public func cues(from words: [TranscribedWord]) -> [Cue] {
        let heard = walla?.words(words) ?? words
        let spoken = keepsSoundDescriptions ? heard : heard.filter { !Self.isSoundDescription($0.text) }
        return segmenter.cues(from: TranscriptCleanup.words(corrected(spoken))).filter { !TranscriptCleanup.isOnlyInterjections($0.text) }
    }

    /// "(laughs)", "[door opens]".
    static func isSoundDescription(_ word: String) -> Bool {
        let text = word.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters.subtracting(["(", ")", "[", "]"])))
        return (text.hasPrefix("(") && text.hasSuffix(")")) || (text.hasPrefix("[") && text.hasSuffix("]"))
    }

    /// The words with their starts where the voice starts.
    public func corrected(_ words: [TranscribedWord]) -> [TranscribedWord] {
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

    public func fix(_ translations: [CueTranslation], request: TranslationRequest, cast: [CastMember]? = nil) -> [CueTranslation] {
        let names = NameEnforcer(cast: cast ?? request.cast)
        let sources = Dictionary(request.lines.map { ($0.cueID, $0.source) }, uniquingKeysWith: { first, _ in first })
        let bare = TranslationStyle.endsLinesBare(request.targetLanguage) && request.style.dropsFinalPunctuation
        func fix(_ text: String, cueID: Cue.ID) -> String {
            var text = layout(text)
            if !names.isEmpty, let source = sources[cueID] { text = names.apply(to: text, source: source) }
            if bare { text = Self.withoutFinalPunctuation(text) }
            return text
        }
        return translations.map { translation in
            guard !translation.isLeftOut else { return translation }
            var fixed = translation
            fixed.text = fix(translation.text, cueID: translation.cueID)
            if var flag = translation.flag {
                for index in flag.variants.indices { flag.variants[index].text = fix(flag.variants[index].text, cueID: translation.cueID) }
                fixed.flag = flag
            }
            return fixed
        }
    }

    public func fix(_ batch: TranslationBatch, request: TranslationRequest) -> TranslationBatch {
        var cast = request.cast
        cast.merge(batch.cast)
        return TranslationBatch(translations: fix(batch.translations, request: request, cast: cast), cast: batch.cast)
    }

    /// Translations of sentences sent as one line (`SentenceSpans.grouping`)
    /// shared out over their cues, each part laid out in the house style.
    public func spread(_ translations: [CueTranslation], groups: [SentenceSpans.Group], request: TranslationRequest) -> [CueTranslation] {
        guard !groups.isEmpty else { return translations }
        let bare = TranslationStyle.endsLinesBare(request.targetLanguage) && request.style.dropsFinalPunctuation
        return SentenceSpans.spread(translations, groups: groups) { part in
            bare ? Self.withoutFinalPunctuation(layout(part)) : layout(part)
        }
    }

    public func spread(_ batch: TranslationBatch, groups: [SentenceSpans.Group], request: TranslationRequest) -> TranslationBatch {
        TranslationBatch(translations: spread(batch.translations, groups: groups, request: request), cast: batch.cast)
    }

    /// Each line without a closing full stop or comma (an ellipsis, question or
    /// exclamation mark stays), as Arabic subtitles are written.
    public static func withoutFinalPunctuation(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            var line = String(line)
            while let last = line.last, ".,،".contains(last), !line.hasSuffix(".."), !line.hasSuffix("…") {
                line.removeLast()
                line = line.trimmingCharacters(in: .whitespaces)
            }
            return line
        }.joined(separator: "\n")
    }

    /// One line when it fits the preset's line length, else two balanced lines,
    /// with no blank lines or stray spaces. Dialogue (a line per speaker) and
    /// text with markup keep their lines.
    func layout(_ text: String) -> String {
        // A " / " the model copied for a line break is one.
        let text = text.replacing(" / ", with: "\n")
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
                // Cut after punctuation or before "و" (and), never after a word that belongs with the next.
                if let mark = words[cut - 1].last, ",.;:!?،؛؟…".contains(mark) { score -= 0.15 }
                if words[cut].hasPrefix("و"), words[cut].count > 2 { score -= 0.06 }
                if CueSegmenter.danglingWords.contains(words[cut - 1].lowercased()) { score += 0.2 }
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

extension SentenceSpans {
    /// A sentence over several cues, sent to the translator as one line.
    public struct Group: Sendable {
        /// The cues, in order; the first one's ID stands for the whole sentence in the request.
        public var cueIDs: [Cue.ID]
        /// Each cue's source text, for sharing the translation out by length.
        public var sources: [String]

        public init(cueIDs: [Cue.ID], sources: [String]) {
            self.cueIDs = cueIDs
            self.sources = sources
        }
    }

    /// The request with every sentence that runs over several lines made one line
    /// (the first line's ID, their text, span, voices and unsure words), and the groups.
    /// Translated cue by cue, the halves of a sentence come back cut where the source
    /// cut them, which in Arabic falls mid-phrase ("…ولرؤية" / "الطرف المذنب يُعاقَب").
    public static func grouping(_ request: TranslationRequest) -> (request: TranslationRequest, groups: [Group]) {
        let texts = request.lines.map { AppleTranslator.sourceText($0.source) }
        let spans = groups(zip(texts, request.lines).map { ($0, $1.start, $1.end) })
        var lines: [TranslationRequest.Line] = []
        var result: [Group] = []
        for span in spans {
            var line = request.lines[span[0]]
            guard span.count > 1 else {
                lines.append(line)
                continue
            }
            let members = span.map { request.lines[$0] }
            line.source = span.map { texts[$0] }.joined(separator: " ")
            line.end = members.last!.end
            var voices: [String] = []
            for voice in members.flatMap({ $0.voices ?? [] }) where !voices.contains(voice) { voices.append(voice) }
            line.voices = voices.isEmpty ? nil : voices
            let unsure = members.flatMap { $0.unsureWords ?? [] }
            line.unsureWords = unsure.isEmpty ? nil : unsure
            line.memoryExample = nil
            lines.append(line)
            result.append(Group(cueIDs: members.map(\.cueID), sources: span.map { texts[$0] }))
        }
        var grouped = request
        grouped.lines = lines
        return (grouped, result)
    }

    /// The translations of grouped sentences shared out over their cues, cut at
    /// phrase boundaries (`split`) and laid out again. A flag stays with the first
    /// cue whose part differs between the variants; the other cues take the
    /// recommended variant's part.
    public static func spread(_ translations: [CueTranslation], groups: [Group], layout: (String) -> String) -> [CueTranslation] {
        let byFirst = Dictionary(groups.map { ($0.cueIDs[0], $0) }, uniquingKeysWith: { first, _ in first })
        var result: [CueTranslation] = []
        for translation in translations {
            guard let group = byFirst[translation.cueID] else {
                result.append(translation)
                continue
            }
            // A sentence left out (crowd chatter, a made-up language) is left out in every cue.
            if let leftOut = translation.leftOut {
                result += group.cueIDs.map { CueTranslation(cueID: $0, text: "", leftOut: leftOut) }
                continue
            }
            func parts(_ text: String) -> [String] {
                split(SubtitleText.visibleLines(of: text).joined(separator: " "), like: group.sources).map(layout)
            }
            let texts = parts(translation.text)
            var flagged: Int?
            var variantParts: [[String]] = []
            if let flag = translation.flag {
                variantParts = flag.variants.map { parts($0.text) }
                flagged = texts.indices.first { index in Set(variantParts.map { $0[index] }).count > 1 }
            }
            for (index, cueID) in group.cueIDs.enumerated() {
                var part = CueTranslation(cueID: cueID, text: texts[index])
                if index == flagged, var flag = translation.flag {
                    for variant in flag.variants.indices { flag.variants[variant].text = variantParts[variant][index] }
                    part.flag = flag
                }
                result.append(part)
            }
        }
        return result
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

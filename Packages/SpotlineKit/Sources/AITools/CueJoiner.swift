import Foundation
import QualityControl
import SubtitleCore

/// Joins neighbouring cues the way a subtitler would after translating: a
/// sentence split over two cues becomes one cue, a short line joins its
/// neighbour, and a quick exchange between two people becomes a dialogue cue
/// ("- Can you?\n- If I want."). Translating cue by cue keeps the source's
/// breaks, which fall mid-phrase in a language with another word order, and
/// leaves many short cues; the professional Arabic of the akotsk review had a
/// third fewer cues and four times as many two-line ones.
///
/// Only joins that fit the QC preset: two lines, the line length, the longest
/// duration, and never across a long pause.
public struct CueJoiner: Sendable {
    public var preset: QCPreset
    /// The longest pause a joined cue may span, and a longer one inside a sentence
    /// (as long as `SentenceSpans` allows when it sends a sentence as one line).
    public var maxGapSeconds = 0.75
    public var maxSentenceGapSeconds = 1.0
    /// A cue up to this long, or this short in characters, reads as a flash on
    /// its own and joins a neighbour even when both are whole sentences.
    public var shortSeconds = 1.6
    public var shortCharacters = 16
    /// Most cues joined into one.
    public var maxCues = 3
    /// Puts each sentence on a line of its own when they fit, as subtitles without
    /// closing full stops are written (Arabic): "مرحبًا\nهل أنت فتى الإسطبل؟".
    public var sentencePerLine = false

    public init(preset: QCPreset) {
        self.preset = preset
    }

    var maxLineLength: Int { preset.maxCharactersPerLine ?? 42 }
    var maxLines: Int { preset.maxLines ?? 2 }
    var maxDuration: Double { preset.maximumDuration?.seconds ?? 7 }

    /// One cue of a group being joined, with what the joiner needs about it.
    public struct Line: Sendable {
        public var cue: Cue
        /// Who says it (a transcriber's voice label or a name), nil when unknown.
        public var speaker: String?
        /// Its source text in a translation, for telling whether a sentence goes on.
        public var source: String?

        public init(cue: Cue, speaker: String? = nil, source: String? = nil) {
            self.cue = cue
            self.speaker = speaker
            self.source = source
        }
    }

    /// The cues after joining, in order. A joined cue keeps the first cue's ID
    /// and takes the others' source cues (`Cue.joinSources`).
    public func join(_ lines: [Line]) -> [Cue] {
        var result: [Cue] = []
        var group: [Line] = []
        func flush() {
            if let joined = joined(group) { result.append(joined) } else { result += group.map(\.cue) }
            group = []
        }
        for line in lines.sorted(by: { $0.cue.start < $1.cue.start }) {
            if !group.isEmpty, !canJoin(group, line) { flush() }
            group.append(line)
        }
        flush()
        return result
    }

    /// True when `next` may join the cues in `group`.
    func canJoin(_ group: [Line], _ next: Line) -> Bool {
        guard let first = group.first, let last = group.last, group.count < maxCues,
              first.cue.position == next.cue.position,
              !isBlank(next.cue.text), !group.contains(where: { isBlank($0.cue.text) }),
              (next.cue.start - last.cue.end).seconds <= (goesOn(last) ? maxSentenceGapSeconds : maxGapSeconds),
              (next.cue.end - first.cue.start).seconds <= maxDuration,
              // A line with variants to choose from joins only lines without.
              (group + [next]).filter({ hasOpenChoice($0.cue) }).count <= 1,
              !(group + [next]).contains(where: { isDialogue($0.cue.text) || $0.cue.text.contains("<") || $0.cue.text.contains("{") })
        else { return false }
        let candidate = group + [next]
        guard let text = text(of: candidate) else { return false }
        // Joining must not make it harder to read than the preset allows.
        if let speed = preset.maxCharactersPerSecond, speed > 0 {
            let characters = text.filter { !$0.isNewline }.count
            if Double(characters) / (next.cue.end - first.cue.start).seconds > speed { return false }
        }
        if speakersDiffer(candidate) {
            // A dialogue cue: two people, a line each, when one of them only says a little.
            return candidate.count == 2 && (isShort(last) || isShort(next))
        }
        return goesOn(last) || isShort(last) || isShort(next)
    }

    /// The group as one cue, nil for a group of one.
    func joined(_ group: [Line]) -> Cue? {
        guard group.count > 1, let text = text(of: group) else { return nil }
        var cue = group[0].cue
        cue.end = group.map(\.cue.end).max() ?? cue.end
        cue.text = text
        for line in group.dropFirst() {
            cue.joinSources(of: line.cue)
            let voices = (cue.voices ?? []) + (line.cue.voices ?? []).filter { !(cue.voices ?? []).contains($0) }
            cue.voices = voices.isEmpty ? nil : voices
            let unsure = (cue.unsureWords ?? []) + (line.cue.unsureWords ?? [])
            cue.unsureWords = unsure.isEmpty ? nil : unsure
            if line.cue.isAIGenerated == true { cue.isAIGenerated = true }
        }
        // A line's variants become variants of the whole joined text.
        if let index = group.firstIndex(where: { $0.cue.flag != nil }), var flag = group[index].cue.flag {
            for variant in flag.variants.indices {
                var texts = group.map(\.cue.text)
                texts[index] = flag.variants[variant].text
                flag.variants[variant].text = self.text(of: texts, speakers: group.map(\.speaker), goesOn: group.map(goesOn)) ?? flag.variants[variant].text
            }
            cue.flag = flag
        } else {
            cue.flag = nil
        }
        return cue
    }

    func text(of group: [Line]) -> String? {
        text(of: group.map(\.cue.text), speakers: group.map(\.speaker), goesOn: group.map(goesOn))
    }

    /// The texts as one cue's text, nil when they do not fit: a dash line each
    /// for two speakers; for one, a line when it fits, else two lines broken
    /// where a sentence ends (a sentence split over the cues is laid out as one).
    /// `goesOn` says, for each text, whether its sentence runs into the next.
    func text(of texts: [String], speakers: [String?], goesOn: [Bool]) -> String? {
        let parts = texts.map { SubtitleText.visibleLines(of: $0).joined(separator: " ").trimmingCharacters(in: .whitespaces) }
        func fits(_ line: String) -> Bool { line.count <= maxLineLength }
        if speakersDiffer(speakers), parts.count == 2 {
            let lines = parts.map { "- " + $0 }
            return lines.allSatisfy(fits) ? lines.joined(separator: "\n") : nil
        }
        let whole = CueSegmenter.join(parts)
        // Breaks between texts where a sentence ends, the most balanced first.
        let sentenceBreaks = (1..<parts.count).filter { !goesOn[$0 - 1] }
        let candidates = maxLines < 2 ? [] : sentenceBreaks.map { (CueSegmenter.join(Array(parts[..<$0])), CueSegmenter.join(Array(parts[$0...]))) }
            .filter { fits($0.0) && fits($0.1) }
            .sorted { abs($0.0.count - $0.1.count) < abs($1.0.count - $1.1.count) }
        if sentencePerLine, let best = candidates.first { return best.0 + "\n" + best.1 }
        if fits(whole) { return whole }
        guard maxLines >= 2 else { return nil }
        if let best = candidates.first { return best.0 + "\n" + best.1 }
        // One sentence over all of them: laid out as one.
        guard sentenceBreaks.isEmpty else { return nil }
        let text = CueSegmenter.layout(whole.split(separator: " ").map(String.init), maxLineLength: maxLineLength)
        let lines = text.split(separator: "\n")
        return lines.count <= maxLines && lines.allSatisfy({ fits(String($0)) }) ? text : nil
    }

    func speakersDiffer(_ group: [Line]) -> Bool { speakersDiffer(group.map(\.speaker)) }

    /// Two known, different speakers.
    func speakersDiffer(_ speakers: [String?]) -> Bool {
        Set(speakers.compactMap { $0 }).count > 1
    }

    func isShort(_ line: Line) -> Bool {
        line.cue.duration.seconds <= shortSeconds
            || SubtitleText.visibleLines(of: line.cue.text).joined().count <= shortCharacters
    }

    /// True when the line stops mid-sentence: its source (in a translation) or
    /// its own text has no closing punctuation.
    func goesOn(_ line: Line) -> Bool {
        let text = (line.source ?? line.cue.text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = text.last else { return false }
        return !".?!…:;\"”»♪)]؟".contains(last)
    }

    func isBlank(_ text: String) -> Bool {
        SubtitleText.visibleLines(of: text).joined().allSatisfy(\.isWhitespace)
    }

    func isDialogue(_ text: String) -> Bool {
        TranslationPipeline.isDialogue(text.split(whereSeparator: \.isNewline).map(String.init))
    }

    func hasOpenChoice(_ cue: Cue) -> Bool {
        cue.flag.map { !$0.isResolved && $0.variants.count > 1 } ?? false
    }
}

extension Proposals {
    /// The changes that turn `cues` into `joined`: the first cue of each join
    /// updated, the rest removed.
    public static func join(_ cues: [Cue], into joined: [Cue], title: String = "Join Lines") -> ProposedChangeSet {
        let before = Dictionary(cues.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let kept = Set(joined.map(\.id))
        var changes: [ProposedChange] = joined.compactMap { cue in
            before[cue.id].flatMap { ProposedChange.update(from: $0, to: cue, note: "Joined with the next line") }
        }
        changes += cues.filter { !kept.contains($0.id) }.map { ProposedChange(kind: .delete, cue: $0, note: "Joined into the line before") }
        return ProposedChangeSet(title: title, changes: changes)
    }
}

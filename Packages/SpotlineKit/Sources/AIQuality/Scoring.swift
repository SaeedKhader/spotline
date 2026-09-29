import QualityControl
import SubtitleCore
import SubtitleTranslation

/// Scores AI output against reference subtitles.
public enum Scoring {
    /// A cue's words, each with the line it is on.
    struct CueWords {
        var cue: Int
        var words: [String]
        var lines: [Int]
    }

    static func words(of cues: [Cue]) -> [CueWords] {
        cues.enumerated().map { index, cue in
            var words: [String] = []
            var lines: [Int] = []
            for (line, text) in SubtitleText.visibleLines(of: cue.text).enumerated() {
                let found = ScoringText.words(text)
                words += found
                lines += Array(repeating: line, count: found.count)
            }
            return CueWords(cue: index, words: words, lines: lines)
        }
    }

    /// Word error rate over all the text, then timing and segmentation where
    /// both sides agree on the words: a cue boundary is shared when both put
    /// one before the same (correctly heard) word, and only shared boundaries
    /// have their times compared, so timing is not blamed for segmentation.
    public static func transcription(
        hypothesis: [Cue], reference: [Cue], preset: QCPreset, context: QualityControl.Context
    ) -> TranscriptionScore {
        let hyp = hypothesis.sorted { $0.start < $1.start }
        let ref = reference.sorted { $0.start < $1.start }
        let hypCues = words(of: hyp).filter { !$0.words.isEmpty }
        let refCues = words(of: ref).filter { !$0.words.isEmpty }
        // Flat word lists, with (cue, position in cue) for each word.
        let hypWords = hypCues.flatMap(\.words), refWords = refCues.flatMap(\.words)
        let hypPlace = hypCues.enumerated().flatMap { c, cue in cue.words.indices.map { (c, $0) } }
        let refPlace = refCues.enumerated().flatMap { c, cue in cue.words.indices.map { (c, $0) } }
        let alignment = WordAlignment(reference: refWords, hypothesis: hypWords)

        var score = TranscriptionScore()
        score.referenceWords = refWords.count
        score.substitutions = alignment.substitutions
        score.deletions = alignment.deletions
        score.insertions = alignment.insertions
        score.rules = RuleCounts(hyp, preset: preset, context: context)
        score.referenceRules = RuleCounts(ref, preset: preset, context: context)

        var hypForRef: [Int: Int] = [:]
        for pair in alignment.matchedPairs { hypForRef[pair.reference] = pair.hypothesis }
        let matchedHyp = Set(hypForRef.values)
        func isFirst(_ place: (Int, Int)) -> Bool { place.1 == 0 }
        func isLast(_ place: (Int, Int), in cues: [CueWords]) -> Bool { place.1 == cues[place.0].words.count - 1 }

        score.referenceBoundaries = hypForRef.keys.count { isFirst(refPlace[$0]) }
        score.hypothesisBoundaries = matchedHyp.count { isFirst(hypPlace[$0]) }
        // Reference cue → hypothesis cue that starts (ends) on the same word.
        var startsShared: [Int: Int] = [:], endsShared: [Int: Int] = [:]
        for (r, h) in hypForRef.sorted(by: { $0.key < $1.key }) {
            let rp = refPlace[r], hp = hypPlace[h]
            if isFirst(rp), isFirst(hp) {
                score.sharedBoundaries += 1
                startsShared[rp.0] = hp.0
                score.startOffsets.values.append((hyp[hypCues[hp.0].cue].start - ref[refCues[rp.0].cue].start).seconds)
            }
            if isLast(rp, in: refCues), isLast(hp, in: hypCues) {
                endsShared[rp.0] = hp.0
                score.endOffsets.values.append((hyp[hypCues[hp.0].cue].end - ref[refCues[rp.0].cue].end).seconds)
            }
        }
        // The same cue: same words, starting and ending on the same words in both.
        for (r, h) in startsShared where endsShared[r] == h && refCues[r].words == hypCues[h].words {
            score.sameCues += 1
            if breaks(refCues[r]) == breaks(hypCues[h]) { score.sameLineBreaks += 1 }
        }
        return score
    }

    /// Word positions where a new line starts.
    static func breaks(_ cue: CueWords) -> [Int] {
        cue.lines.indices.dropFirst().filter { cue.lines[$0] != cue.lines[$0 - 1] }
    }

    /// Source cues and the reference translation cues that say the same thing,
    /// found by time: each cue is joined to the cue on the other side it
    /// overlaps most, and joined cues form a group. Translations often merge or
    /// split cues, so lines are compared group by group. Indexes are in time order.
    public static func groups(source: [Cue], reference: [Cue]) -> [(source: [Int], reference: [Int])] {
        // Union-find over source cues (0..<s) and reference cues (s..<s+r).
        var parent = Array(0..<(source.count + reference.count))
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        func mostOverlapped(by cue: Cue, in others: [Cue]) -> Int? {
            var best: (index: Int, overlap: MediaTime)?
            for (index, other) in others.enumerated() where other.start < cue.end && cue.start < other.end {
                let overlap = min(cue.end, other.end) - max(cue.start, other.start)
                if overlap > (best?.overlap ?? .zero) { best = (index, overlap) }
            }
            return best?.index
        }
        for (index, cue) in source.enumerated() {
            if let other = mostOverlapped(by: cue, in: reference) { parent[root(index)] = root(source.count + other) }
        }
        for (index, cue) in reference.enumerated() {
            if let other = mostOverlapped(by: cue, in: source) { parent[root(source.count + index)] = root(other) }
        }
        var groups: [Int: (source: [Int], reference: [Int])] = [:]
        for index in source.indices { groups[root(index), default: ([], [])].source.append(index) }
        for index in reference.indices { groups[root(source.count + index), default: ([], [])].reference.append(index) }
        return groups.values.filter { !$0.source.isEmpty && !$0.reference.isEmpty }.sorted { $0.source[0] < $1.source[0] }
    }

    /// One group of translated lines against its reference. `glossary` is checked when given.
    public static func translation(
        hypothesis: String, reference: String, source: String, targetLanguage: String, glossary: Glossary? = nil
    ) -> TranslationScore {
        var score = TranslationScore()
        score.segments = 1
        score.chrF = ChrF.statistics(hypothesis: MatchText.normalize(hypothesis), reference: MatchText.normalize(reference))
        if Languages.base(targetLanguage) == "ar" {
            let hyp = ArabicAddressee.form(of: hypothesis), ref = ArabicAddressee.form(of: reference)
            if hyp != nil || ref != nil {
                score.addresseeLines = 1
                score.addresseeAgreements = hyp == ref ? 1 : 0
            }
        }
        if let glossary {
            let matches = glossary.matches(source: source, target: hypothesis)
            score.glossaryTerms = matches.count
            score.glossaryTermsUsed = matches.count { $0.isUsed }
        }
        return score
    }
}

/// Language codes, as `AITools.Languages` reads them (AIQuality does not depend on AITools).
enum Languages {
    static func base(_ code: String) -> String {
        String(code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "").lowercased()
    }
}

/// Which "you" an Arabic line uses, read from its forms (a heuristic).
///
/// Undiacritized Arabic writes masculine and feminine "you" (أنت) alike, so
/// only the marked forms are read: feminine (أنتِ, the -ين of تفعلين) and
/// plural (أنتم, أنتن, -كم, the -ون of تفعلون). A line with neither is unmarked.
/// Only lines where the reference or the translation is marked are scored.
public enum ArabicAddressee {
    public enum Form: String, Codable, Sendable {
        case feminine
        case plural
    }

    public static func form(of text: String) -> Form? {
        let visible = SubtitleText.visibleLines(of: text).joined(separator: " ")
        let words = MatchText.normalize(visible).split(whereSeparator: { !$0.isLetter }).map(String.init)
        if words.contains(where: isPlural) { return .plural }
        if visible.contains("أنتِ") || visible.contains("انتِ") || visible.contains("كِ") || words.contains(where: isFeminine) {
            return .feminine
        }
        return nil
    }

    /// Words that end like second-person forms but are not.
    static let notSecondPerson: Set<String> = [
        "حكم", "الحكم", "بحكم", "حاكم", "محكمه", "يحكم", "تحكم", "تراكم", "كم", "بكم", "مكم",
        "تمرين", "تسعين", "تعيين", "تحسين", "تكوين", "تامين", "تدوين", "تزيين", "تلقين", "تخمين", "تموين", "تنين", "تين",
        "تلفزيون", "تكون", "تهون", "تعاون",
    ]

    static func isPlural(_ word: String) -> Bool {
        guard !notSecondPerson.contains(word) else { return false }
        if word == "انتم" || word == "انتن" { return true }
        if word.count >= 3, word.hasSuffix("كم") { return true }
        return word.count >= 5 && word.hasPrefix("ت") && word.hasSuffix("ون")
    }

    static func isFeminine(_ word: String) -> Bool {
        !notSecondPerson.contains(word) && word.count >= 5 && word.hasPrefix("ت") && word.hasSuffix("ين")
    }
}

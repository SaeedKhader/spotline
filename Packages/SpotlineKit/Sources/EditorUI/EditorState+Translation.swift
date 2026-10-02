import AITools
import EditorCommands
import Foundation
import NaturalLanguage
import QualityControl
import SubtitleCore
import SubtitleFormats
import SubtitleTranslation

/// Translation mode: a read-only source track beside the editable target
/// (`track`), with a glossary and a translation memory for the language pair.
/// QC checks the target, plus untranslated cues and glossary terms.
extension EditorState {
    public var isTranslating: Bool { sourceTrack != nil }

    /// Which way the target text runs: from its language, else from its letters.
    public var targetDirection: TextDirection {
        TextDirection.of(languageCode: track.languageCode, sample: track.cues.prefix(50).map(\.text).joined(separator: " "))
    }

    public var sourceDirection: TextDirection {
        guard let source = sourceTrack else { return .leftToRight }
        return TextDirection.of(languageCode: source.languageCode, sample: source.cues.prefix(50).map(\.text).joined(separator: " "))
    }

    // MARK: Source subtitles

    /// Reads a file as the source to translate from. An empty target becomes a
    /// copy of the source's timing with no text (one undoable edit); cues already
    /// there are paired with the source cues they overlap.
    public func openSourceSubtitles(from url: URL) {
        do {
            var (format, source) = try SubtitleFile.read(from: url)
            if source.languageCode == "und" { source.languageCode = Self.detectLanguage(of: source.cues) ?? "und" }
            let targetLanguage = track.languageCode != "und" ? track.languageCode
                : Self.detectLanguage(of: track.cues) ?? defaultTargetLanguage(avoiding: source.languageCode)
            edit("Open Source Subtitles") { track in
                if track.cues.isEmpty {
                    track.cues = Alignment.template(from: source.cues)
                } else {
                    track.cues = Alignment.link(track.cues, to: source.cues)
                }
                track.languageCode = targetLanguage
            }
            sourceFile = SubtitleFileReference(url: url, format: format)
            sourceTrack = source
            translationPairDidChange()
        } catch {
            reportError("“\(url.lastPathComponent)” could not be opened as the source.", error)
        }
    }

    /// Where a new translation is suggested to go: beside the source, named for
    /// the target language ("Pilot.en.srt" becomes "Pilot.ar.srt").
    var suggestedTranslationFile: SubtitleFileReference? {
        guard let source = sourceFile else { return nil }
        var name = source.url.deletingPathExtension().lastPathComponent
        let parts = name.split(separator: ".")
        if parts.count > 1, let last = parts.last, last.count <= 3 || last.contains("-") { name = parts.dropLast().joined(separator: ".") }
        let url = source.url.deletingLastPathComponent().appending(path: "\(name).\(track.languageCode).\(source.format.fileExtension)")
        return SubtitleFileReference(url: url, format: source.format)
    }

    /// Leaves translation mode. Cues keep their links, so reopening the source pairs them again.
    public func closeSourceSubtitles() {
        if let selected = selectedCueID { recordTranslation(of: selected) }
        sourceTrack = nil
        sourceFile = nil
        translationPairDidChange()
    }

    /// Recomputes `sourceCues`; observers see a change only when the pairing differs.
    func updateSourceCues() {
        let pairs = sourceTrack.map { Alignment.sourceCues(for: track.cues, in: $0.cues) } ?? [:]
        guard pairs != sourceCues else { return }
        let joined = track.cues.contains { $0.joinedSourceCueIDs != nil }
        sourceCues = pairs
        // A joined cue reads its source cues as one, with glossary terms from all of them;
        // once it is no longer joined (split, or the join undone), its source cue has its own again.
        if joined || glossaryHitsCoverJoinedCues { updateGlossaryHits() }
    }

    // MARK: Languages

    /// Common subtitle languages for the Target Language menu, plus the current one.
    public var targetLanguageChoices: [String] {
        var codes = ["ar", "en", "fr", "de", "es", "it", "pt", "nl", "tr", "fa", "he", "ur", "hi", "ru", "el", "zh", "ja", "ko"]
        if !codes.contains(track.languageCode) { codes.insert(track.languageCode, at: 0) }
        return codes
    }

    /// "Arabic", or "Unknown" for "und".
    public static func languageName(_ code: String) -> String {
        guard code != "und" else { return "Unknown" }
        return Locale.current.localizedString(forIdentifier: code) ?? code
    }

    /// Sets the target's language (for direction, the glossary and memory pair, and exports). Undoable.
    public func setTargetLanguage(_ code: String) {
        guard code != track.languageCode else { return }
        edit("Set Target Language") { track in track.languageCode = code }
        settings?.set(code, forKey: Self.targetLanguageKey)
    }

    /// The last target language chosen, else Arabic, else English when the source is Arabic.
    func defaultTargetLanguage(avoiding source: String) -> String {
        let remembered = settings?.string(forKey: Self.targetLanguageKey) ?? "ar"
        if remembered != source { return remembered }
        return source == "en" ? "ar" : "en"
    }

    /// The dominant language of the cues' text, as a BCP 47 tag, when there is enough text to tell.
    static func detectLanguage(of cues: [Cue]) -> String? {
        let text = cues.prefix(200).map { SubtitleText.visibleLines(of: $0.text).joined(separator: " ") }.joined(separator: "\n")
        guard text.filter(\.isLetter).count >= 20 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return language.rawValue
    }

    /// Loads the glossary and memory of the current language pair.
    func translationPairDidChange() {
        let pair = TranslationStore.pairKey(source: sourceTrack?.languageCode ?? "und", target: track.languageCode)
        guard pair != translationPair else { return }
        translationPair = pair
        guard let store = translationStore else { return }
        isLoadingTranslationResources = true
        glossary = store.glossary(pair: pair)
        memory = store.memory(pair: pair)
        isLoadingTranslationResources = false
    }

    // MARK: Glossary

    /// Glossary terms in the cue's source text, and whether the cue uses their translations.
    public func glossaryMatches(for cueID: Cue.ID) -> [Glossary.Match] {
        cue(withID: cueID).map(glossaryMatches(for:)) ?? []
    }

    /// The same for a cue in hand: a row showing it then redraws for its own cue, the pairing
    /// and the glossary, not for every edit to the track.
    public func glossaryMatches(for cue: Cue) -> [Glossary.Match] {
        // Read so views showing matches redraw when the glossary changes.
        _ = glossary
        guard let source = sourceCues[cue.id], let entries = glossaryHits[source.id], !entries.isEmpty else { return [] }
        return glossaryMatches(for: cue, terms: entries)
    }

    private func glossaryMatches(for cue: Cue, terms: [Glossary.Entry]) -> [Glossary.Match] {
        let target = MatchText.normalize(cue.text)
        return terms.map { Glossary.Match(entry: $0, isUsed: glossaryIndex.isUsed($0, inNormalizedTarget: target)) }
    }

    func updateGlossaryHits() {
        guard let source = sourceTrack, !glossaryIndex.isEmpty else {
            glossaryHits = [:]
            glossaryHitsCoverJoinedCues = false
            return
        }
        var hits: [Cue.ID: [Glossary.Entry]] = [:]
        // Joined target cues read their source cues as one (with the first's ID), so those come last.
        let joined = sourceCues.values.filter { cue in !source.cues.contains { $0.id == cue.id && $0.text == cue.text } }
        glossaryHitsCoverJoinedCues = !joined.isEmpty
        for cue in source.cues + joined {
            let entries = glossaryIndex.entries(inSource: cue.text)
            if !entries.isEmpty { hits[cue.id] = entries }
        }
        glossaryHits = hits
    }

    /// Adds an empty term (or one with text) and returns its ID.
    @discardableResult
    public func addGlossaryEntry(source: String = "", target: String = "", note: String = "") -> UUID {
        let entry = Glossary.Entry(source: source, target: target, note: note)
        glossary.entries.append(entry)
        return entry.id
    }

    public func updateGlossaryEntry(_ entry: Glossary.Entry) {
        guard let index = glossary.entries.firstIndex(where: { $0.id == entry.id }), glossary.entries[index] != entry else { return }
        glossary.entries[index] = entry
    }

    public func removeGlossaryEntries(_ ids: Set<UUID>) {
        glossary.entries.removeAll { ids.contains($0.id) }
    }

    /// Adds the terms of a CSV or tab-separated file (source, target, note).
    public func importGlossary(from url: URL) {
        do {
            let entries = Glossary.entries(fromDelimited: try SubtitleFile.decode(Data(contentsOf: url)))
            guard !entries.isEmpty else {
                throw SubtitleParseError(line: 1, reason: "No terms found. Each line needs a source term and its translation, separated by a comma or tab.")
            }
            glossary.merge(entries)
        } catch {
            reportError("“\(url.lastPathComponent)” could not be imported as a glossary.", error)
        }
    }

    /// People whose translated name the glossary does not have yet.
    public var namesMissingFromGlossary: [CastMember] {
        track.cast.filter { person in
            person.translatedName?.isEmpty == false
                && !glossary.entries.contains { $0.source.caseInsensitiveCompare(person.name) == .orderedSame }
        }
    }

    // MARK: Notes for the translator

    /// Changes the notes the AI translator gets with every line (the show, the
    /// setting, who is who). Saved with the project; typing undoes as one step.
    public func setTranslatorNotes(_ notes: String) {
        let value = notes.isEmpty ? nil : notes
        guard value != track.translatorNotes else { return }
        edit("Translator Notes", coalescing: translatorNotesSession) { track in track.translatorNotes = value }
        translatorNotesSession = true
    }

    // MARK: Translation memory

    /// Up to three suggestions for the cue's source text, best first.
    public func memoryMatches(for cueID: Cue.ID) -> [TranslationMemory.Match] {
        // Read so views showing suggestions redraw when the memory changes.
        _ = memory
        guard let source = sourceCues[cueID] else { return [] }
        if let cached = memoryMatchCache[source.id] { return cached }
        let matches = memory.matches(for: source.text)
        memoryMatchCache[source.id] = matches
        return matches
    }

    /// Replaces a cue's text with a memory suggestion. Undoable.
    public func useMemoryMatch(_ match: TranslationMemory.Match, forCue id: Cue.ID) {
        replaceText(of: id, with: match.entry.target, actionName: EditorCommand.useMemoryMatch.title)
    }

    /// Replaces a cue's text in its own undo step (not joined to typing).
    func replaceText(of id: Cue.ID, with text: String, actionName: String) {
        guard let index = track.cues.firstIndex(where: { $0.id == id }) else { return }
        edit(actionName) { track in track.cues[index].text = text }
    }

    /// Fills every empty cue whose source has an exact memory match. Returns false when none has.
    func fillExactMatches() -> Bool {
        var fills: [Int: String] = [:]
        for (index, cue) in track.cues.enumerated() where SubtitleText.isBlank(cue.text) {
            if let source = sourceCues[cue.id], let match = memory.exactMatch(for: source.text) {
                fills[index] = match.target
            }
        }
        guard !fills.isEmpty else { return false }
        edit(EditorCommand.fillExactMatches.title) { track in
            for (index, text) in fills { track.cues[index].text = text }
        }
        return true
    }

    /// Stores a cue's translation with its source text, when both have text.
    func recordTranslation(of cueID: Cue.ID) {
        guard let cue = cue(withID: cueID), let source = sourceCues[cueID] else { return }
        // On a copy: a pair the memory already has leaves it, and the suggestions worked out from it, as they are.
        var updated = memory
        guard updated.record(source: source.text, target: cue.text) else { return }
        memory = updated
        saveMemory()
    }

    func addTranslationsToMemory() {
        var changed = false
        for cue in track.cues {
            if let source = sourceCues[cue.id], memory.record(source: source.text, target: cue.text) { changed = true }
        }
        if changed { saveMemory() }
    }

    private func saveMemory() {
        // A performance run changes nothing of the person's.
        guard launchOptions.performanceReportURL == nil else { return }
        try? translationStore?.save(memory, pair: translationPair)
    }

    // MARK: Quality control

    /// Untranslated cues and glossary terms not used. (Lines that read more than
    /// one way have their own review: AI › Review Translation Choices; words the
    /// transcriber was unsure of too: AI › Review Words to Check.)
    func addTranslationIssues(to issues: inout [QCIssue], of cue: Cue, source: Cue?, terms: [Glossary.Entry]) {
        guard let source else { return }
        let sourceHasText = !SubtitleText.isBlank(source.text)
        if sourceHasText, let index = issues.firstIndex(where: { $0.kind == .empty }) {
            issues[index] = QCIssue(kind: .notTranslated, message: "Not translated")
        } else if !terms.isEmpty {
            for match in glossaryMatches(for: cue, terms: terms) where !match.isUsed {
                issues.append(QCIssue(
                    kind: .glossaryTermNotUsed(source: match.entry.source, target: match.entry.target),
                    message: "Glossary: “\(match.entry.source)” is “\(match.entry.target)”"
                ))
            }
        }
    }
}

// MARK: - Glossary replacements

extension EditorState {
    /// For each glossary term the cue's translation does not use: the line with the word it
    /// used instead swapped for the agreed one, likeliest first. The word is found two ways:
    /// it is spelled much like the agreed translation ("دنك" for "دانك"), or it is in most of
    /// the lines that miss this term and in few others ("سيدي" wherever the source says "ser").
    /// No option when nothing points to a word; the line is then edited by hand.
    func glossaryReplacements(for cue: Cue, issues: [QCIssue]) -> [ReviewSuggestion] {
        var result: [ReviewSuggestion] = []
        for issue in issues {
            guard case .glossaryTermNotUsed(_, let target) = issue.kind else { continue }
            let agreed = MatchText.normalize(target)
            // The other lines that miss this term, and how often each word is in them and in the whole translation.
            let sets = wordSets()
            let everywhere = track.cues.compactMap { sets[$0.id] }
            let inMissing = track.cues.filter { other in self.issues[other.id]?.contains { $0.kind == issue.kind } == true }.compactMap { sets[$0.id] }
            var scored: [(range: Range<String.Index>, word: String, score: Double)] = []
            var seen = Set<String>()
            for range in Self.wordRanges(in: cue.text) {
                let word = String(cue.text[range])
                let key = MatchText.normalize(word)
                guard key.count > 1, key != agreed, seen.insert(key).inserted else { continue }
                var score = 0.0
                // A third of the letters at most: "سيدي" is not a spelling of "سير".
                if TranscriptAligner.soundsAlike(key, agreed, share: 1.0 / 3) {
                    score = 2
                } else {
                    let with = inMissing.count { $0.contains(key) }
                    let total = everywhere.count { $0.contains(key) }
                    if with >= 2, total > 0 { score = Double(with) / Double(total) }
                }
                if score >= 0.5 { scored.append((range, word, score)) }
            }
            // Every word spelled like the agreed one, and the one word that best goes with the term
            // (the longer on a tie: "سيدي" rather than the "يا" before it).
            let best = scored.filter { $0.score < 2 }.max { ($0.score, $0.word.count) < ($1.score, $1.word.count) }
            let offered = scored.filter { $0.score == 2 } + [best].compactMap(\.self)
            for candidate in offered.prefix(2) {
                let text = cue.text.replacingCharacters(in: candidate.range, with: target)
                result.append(ReviewSuggestion(
                    title: "Replace “\(candidate.word)” with “\(target)”", preview: text, action: .replaceTerm(text),
                    fixes: "glossary term", clears: ["glossary term"]
                ))
            }
        }
        return result
    }

    /// Each cue's words, normalized: worked out once for the cues as they are (`cueWordSets`).
    func wordSets() -> [Cue.ID: Set<String>] {
        if let cueWordSets { return cueWordSets }
        var byText: [Cue.ID: (text: String, words: Set<String>)] = [:]
        byText.reserveCapacity(track.cues.count)
        for cue in track.cues where byText[cue.id] == nil {
            if let last = wordSetsByText[cue.id], last.text == cue.text {
                byText[cue.id] = last
            } else {
                byText[cue.id] = (cue.text, Set(Self.wordRanges(in: cue.text).map { MatchText.normalize(String(cue.text[$0])) }))
            }
        }
        wordSetsByText = byText
        let sets = byText.mapValues(\.words)
        cueWordSets = sets
        return sets
    }

    /// The line with the word it used for a glossary term swapped for the agreed one: what the
    /// card's Replace button puts in. Nil when nothing points to a word.
    public func glossaryReplacement(forCue id: Cue.ID) -> (title: String, text: String)? {
        // Read even when the answer is at hand, so cards showing it redraw when the cues or issues change.
        _ = (track, issues)
        if let known = reviewDerived.glossaryReplacements[id] { return known }
        var replacement: (title: String, text: String)?
        if let cue = cue(withID: id) {
            for option in glossaryReplacements(for: cue, issues: issues[id] ?? []) {
                if case .replaceTerm(let text) = option.action {
                    replacement = (option.title, text)
                    break
                }
            }
        }
        reviewDerived.glossaryReplacements[id] = .some(replacement)
        return replacement
    }

    /// Where each word of a line is, without the punctuation around it.
    static func wordRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        var index = text.startIndex
        func isWord(_ character: Character) -> Bool { character.isLetter || character.isNumber || character.unicodeScalars.allSatisfy { $0.properties.generalCategory == .nonspacingMark } }
        while index < text.endIndex {
            if isWord(text[index]) {
                if start == nil { start = index }
            } else if let begun = start {
                ranges.append(begun..<index)
                start = nil
            }
            index = text.index(after: index)
        }
        if let begun = start { ranges.append(begun..<text.endIndex) }
        return ranges
    }
}

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
        if pairs != sourceCues { sourceCues = pairs }
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
        // Read so views showing matches redraw when the glossary changes.
        _ = glossary
        guard let source = sourceCues[cueID], let entries = glossaryHits[source.id], !entries.isEmpty,
              let cue = cue(withID: cueID)
        else { return [] }
        let target = MatchText.normalize(cue.text)
        return entries.map { Glossary.Match(entry: $0, isUsed: glossaryIndex.isUsed($0, inNormalizedTarget: target)) }
    }

    func updateGlossaryHits() {
        guard let source = sourceTrack, !glossaryIndex.isEmpty else {
            glossaryHits = [:]
            return
        }
        var hits: [Cue.ID: [Glossary.Entry]] = [:]
        for cue in source.cues {
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
        for (index, cue) in track.cues.enumerated() where SubtitleText.visibleLines(of: cue.text).joined().allSatisfy(\.isWhitespace) {
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
        if memory.record(source: source.text, target: cue.text) { saveMemory() }
    }

    func addTranslationsToMemory() {
        var changed = false
        for cue in track.cues {
            if let source = sourceCues[cue.id], memory.record(source: source.text, target: cue.text) { changed = true }
        }
        if changed { saveMemory() }
    }

    private func saveMemory() {
        try? translationStore?.save(memory, pair: translationPair)
    }

    // MARK: Quality control

    /// Untranslated cues and glossary terms not used. (Lines that read more than
    /// one way have their own review: AI › Review Translation Choices.)
    func addTranslationIssues(to issues: inout [Cue.ID: [QCIssue]]) {
        for cue in track.cues {
            var found: [QCIssue] = []
            if let source = sourceCues[cue.id] {
                let sourceHasText = !SubtitleText.visibleLines(of: source.text).joined().allSatisfy(\.isWhitespace)
                if sourceHasText, let index = issues[cue.id]?.firstIndex(where: { $0.kind == .empty }) {
                    issues[cue.id]?[index] = QCIssue(kind: .notTranslated, message: "Not translated")
                } else {
                    for match in glossaryMatches(for: cue.id) where !match.isUsed {
                        found.append(QCIssue(
                            kind: .glossaryTermNotUsed(source: match.entry.source, target: match.entry.target),
                            message: "Glossary: “\(match.entry.source)” is “\(match.entry.target)”"
                        ))
                    }
                }
            }
            if !found.isEmpty { issues[cue.id, default: []] += found }
        }
    }
}

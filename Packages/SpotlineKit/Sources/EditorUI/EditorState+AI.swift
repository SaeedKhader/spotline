import AITools
import AppKit
import EditorCommands
import Foundation
import MediaAnalysis
import SubtitleCore
import SubtitleTranslation

/// A running AI tool: what it is doing and how far it has got.
public struct AITaskStatus: Equatable, Sendable {
    /// "Transcribing", "Translating"…
    public var title: String
    /// 0 to 1.
    public var fraction: Double
}

/// Makes providers for the current settings. `live` uses the real ones (API keys
/// from the Keychain), `scripted` fixed answers for UI tests.
@MainActor
public struct AIProviderFactory {
    public var transcriber: @MainActor (AISettings) throws -> any Transcriber
    public var translator: @MainActor (AISettings) throws -> any CueTranslator

    public init(
        transcriber: @escaping @MainActor (AISettings) throws -> any Transcriber,
        translator: @escaping @MainActor (AISettings) throws -> any CueTranslator
    ) {
        self.transcriber = transcriber
        self.translator = translator
    }

    public static func live(keys: APIKeyStore = APIKeyStore()) -> AIProviderFactory {
        AIProviderFactory(
            transcriber: { settings in
                switch settings.transcription {
                case .appleSpeech:
                    return AppleSpeechTranscriber { language in await EditorPanels.confirmSpeechModelDownload(language: language) }
                case .openAIWhisper:
                    guard settings.allowsCloud else { throw AIError.cloudNotAllowed }
                    guard let key = keys.key(for: .openAI) else { throw AIError.missingAPIKey(provider: "OpenAI") }
                    return OpenAITranscriber(apiKey: key)
                case .elevenLabsScribe:
                    guard settings.allowsCloud else { throw AIError.cloudNotAllowed }
                    guard let key = keys.key(for: .elevenLabs) else { throw AIError.missingAPIKey(provider: "ElevenLabs") }
                    return ElevenLabsTranscriber(apiKey: key)
                }
            },
            translator: { settings in
                switch settings.translation {
                case .appleTranslation:
                    return AppleTranslator()
                case .claude, .claudeSonnet:
                    guard settings.allowsCloud else { throw AIError.cloudNotAllowed }
                    guard let key = keys.key(for: .anthropic) else { throw AIError.missingAPIKey(provider: "Anthropic") }
                    return ClaudeTranslator(apiKey: key, model: settings.translation.claudeModel ?? ClaudeTranslator.defaultModel)
                }
            }
        )
    }

    public static let scripted = AIProviderFactory(
        transcriber: { _ in ScriptedTranscriber.fixture },
        translator: { _ in ScriptedTranslator() }
    )
}

/// AI tools (docs/ARCHITECTURE.md, 7a and 7b). Each one runs in the background
/// and ends in a `ProposedChangeSet` that the cue list shows as a diff. Nothing
/// changes until the user accepts, per cue or all at once, each as one undoable edit.
extension EditorState {
    func canPerformAI(_ command: EditorCommand) -> Bool {
        let idle = aiTask == nil && pendingReview == nil
        switch command.id {
        case EditorCommand.transcribe.id:
            return idle && hasMedia
        case EditorCommand.translateWithAI.id:
            // Outside translation mode, the cues being edited become the source.
            return idle && (isTranslating ? !untranslatedCues.isEmpty : track.cues.contains { !$0.text.isEmpty })
        case EditorCommand.reviewChoices.id:
            return isReviewingChoices || track.cues.contains { $0.flag?.isResolved == false }
        case EditorCommand.acceptRemainingChoices.id:
            return track.cues.contains { $0.flag?.isResolved == false }
        case EditorCommand.maskProfanity.id, EditorCommand.removeHearingImpaired.id, EditorCommand.fixPunctuation.id:
            return idle && !track.cues.isEmpty
        case EditorCommand.cancelAITask.id:
            return aiTask != nil
        case EditorCommand.acceptChange.id, EditorCommand.rejectChange.id:
            return selectedCueID.flatMap { pendingReview?.change(forCue: $0) } != nil
        case EditorCommand.acceptAllChanges.id, EditorCommand.rejectAllChanges.id:
            return pendingReview != nil
        default:
            return false
        }
    }

    func performAI(_ command: EditorCommand) -> Bool {
        switch command.id {
        case EditorCommand.transcribe.id: transcribe()
        case EditorCommand.translateWithAI.id:
            if !isTranslating { useCuesAsSource() }
            translateUntranslatedCues()
        case EditorCommand.reviewChoices.id: toggleChoiceReview()
        case EditorCommand.acceptRemainingChoices.id: acceptRemainingChoices()
        case EditorCommand.maskProfanity.id: runCleanup(.maskProfanity)
        case EditorCommand.removeHearingImpaired.id: runCleanup(.removeHearingImpaired)
        case EditorCommand.fixPunctuation.id: runCleanup(.fixSpacingAndPunctuation)
        case EditorCommand.cancelAITask.id: cancelAITask()
        case EditorCommand.acceptChange.id:
            guard let id = selectedCueID else { return false }
            acceptChanges(to: [id])
        case EditorCommand.rejectChange.id:
            guard let id = selectedCueID else { return false }
            rejectChanges(to: [id])
        case EditorCommand.acceptAllChanges.id: acceptChanges(to: nil)
        case EditorCommand.rejectAllChanges.id: rejectChanges(to: nil)
        default: return false
        }
        return true
    }

    // MARK: Review

    /// Proposed new cues, in time order, for the cue list to show between the real ones.
    public var proposedInserts: [ProposedChange] {
        (pendingReview?.changes ?? []).filter { $0.kind == .insert }.sorted { $0.cue.start < $1.cue.start }
    }

    public func proposedChange(forCue id: Cue.ID) -> ProposedChange? {
        pendingReview?.change(forCue: id)
    }

    /// Applies the changes to `ids` (nil: all) as one undoable edit, then selects the next cue with a change.
    public func acceptChanges(to ids: Set<Cue.ID>?) {
        guard let review = pendingReview else { return }
        let next = nextChange(after: ids)
        let name = ids == nil ? "Accept \(review.title)" : "Accept \(review.title) Change"
        edit(name) { track in review.apply(to: &track, only: ids) }
        finishReview(of: ids, in: review, selecting: next)
    }

    /// Drops the changes to `ids` (nil: all); the cues stay as they are.
    public func rejectChanges(to ids: Set<Cue.ID>?) {
        guard let review = pendingReview else { return }
        finishReview(of: ids, in: review, selecting: nextChange(after: ids))
    }

    private func finishReview(of ids: Set<Cue.ID>?, in review: ProposedChangeSet, selecting next: Cue.ID?) {
        let rest = ids.map { review.removing($0) }
        pendingReview = rest.flatMap { $0.isEmpty ? nil : $0 }
        if let ids, let selected = selectedCueID, ids.contains(selected) {
            if let next, pendingReview?.change(forCue: next) != nil {
                select(next)
            } else if cue(withID: selected) == nil {
                selectedCueID = nil
            }
        }
    }

    /// The first change after the ones being decided, in time order.
    private func nextChange(after ids: Set<Cue.ID>?) -> Cue.ID? {
        guard let ids, let changes = pendingReview?.changes.sorted(by: { $0.cue.start < $1.cue.start }) else { return nil }
        let last = changes.lastIndex { ids.contains($0.cueID) } ?? -1
        return changes[(last + 1)...].first { !ids.contains($0.cueID) }?.cueID
            ?? changes.first { !ids.contains($0.cueID) }?.cueID
    }

    func presentReview(_ review: ProposedChangeSet) {
        pendingReview = review
        let first = review.changes.min { $0.cue.start < $1.cue.start }
        if let first { select(first.cueID) }
    }

    /// "transcription", "translation" or "an agent", for the tint's tooltip.
    func aiToolName(for cue: Cue) -> String {
        if agentWrittenCues.contains(cue.id) { return "an agent" }
        return sourceCues[cue.id] != nil ? "translation" : "transcription"
    }

    // MARK: Translation choices

    /// Cues with an open flag, least confident first: what the choice review shows.
    public var cuesToChoose: [Cue] {
        track.cues.filter { $0.flag?.isResolved == false }
            .sorted { ($0.flag?.confidence ?? 1, $0.start) < ($1.flag?.confidence ?? 1, $1.start) }
    }

    /// Uses one of a flagged cue's variants: one click, one undoable edit. What
    /// the variant assumes about people is confirmed, and the other open flags
    /// about them are re-ranked in the same edit.
    public func chooseVariant(_ index: Int, forCue id: Cue.ID) {
        guard let flag = cue(withID: id)?.flag, flag.variants.indices.contains(index) else { return }
        let next = isReviewingChoices ? nextChoice(after: id) : nil
        edit("Choose Translation") { track in track.choose(variant: index, forCue: id) }
        if let next, cue(withID: next)?.flag?.isResolved == false { select(next) }
    }

    /// Settles every open flag as it stands, as one undoable edit, and leaves the review.
    func acceptRemainingChoices() {
        edit(EditorCommand.acceptRemainingChoices.title) { track in track.resolveFlags() }
        isReviewingChoices = false
    }

    /// Shows only the cues with open flags, least confident first, or every cue again.
    func toggleChoiceReview() {
        isReviewingChoices.toggle()
        if isReviewingChoices, let first = cuesToChoose.first, selectedCue?.flag?.isResolved != false { select(first.id) }
    }

    /// The flagged cue after `id` in the review's order.
    private func nextChoice(after id: Cue.ID) -> Cue.ID? {
        let order = cuesToChoose.map(\.id)
        guard let index = order.firstIndex(of: id) else { return order.first }
        return order[(index + 1)...].first ?? order[..<index].first
    }

    // MARK: Running tools

    /// Writes what a running tool has found so far into the track, as one undoable
    /// step per batch. Transcription and translation only fill empty cues and gaps,
    /// so they skip review (cleanup, which rewrites text, is reviewed). A result that
    /// would overwrite something the user did meanwhile is left out: a new cue that
    /// now overlaps one, or a translation for a cue the user has typed in.
    func applyResults(_ proposal: ProposedChangeSet, serial: Int? = nil) {
        guard aiTask != nil else { return }
        if let serial {
            guard serial > partialSerial else { return }
            partialSerial = serial
        }
        var changes: [ProposedChange] = []
        for var change in proposal.changes {
            change.cue.isAIGenerated = true
            switch change.kind {
            case .insert:
                if cue(withID: change.cueID) != nil {
                    // Already written.
                    continue
                } else if !track.cues.contains(where: { $0.position == .bottom && $0.start < change.cue.end && change.cue.start < $0.end }) {
                    changes.append(change)
                }
            case .update(let before):
                guard let current = cue(withID: change.cueID) else { continue }
                if appliedAIChanges.contains(change.cueID) {
                    continue
                } else if before.text == change.cue.text || current.text == before.text {
                    if before.text == change.cue.text { change.cue.isAIGenerated = current.isAIGenerated }
                    change.cue.text = before.text == change.cue.text ? current.text : change.cue.text
                    changes.append(change)
                }
            case .delete:
                continue
            }
        }
        guard !changes.isEmpty else { return }
        appliedAIChanges.formUnion(changes.map(\.cueID))
        let applied = ProposedChangeSet(title: proposal.title, changes: changes, cast: proposal.cast)
        edit(proposal.title) { track in applied.apply(to: &track) }
        if selectedCueID == nil, let first = changes.min(by: { $0.cue.start < $1.cue.start }) { select(first.cueID) }
    }

    /// Runs `work` in the background with progress over the cue list. Results it
    /// passes to `propose` go into the track at once; its final result adds the rest.
    private func startAITask(
        _ title: String,
        _ work: @escaping @MainActor (
            _ progress: @escaping @Sendable (Double) -> Void, _ propose: @escaping @Sendable (ProposedChangeSet) -> Void
        ) async throws -> ProposedChangeSet
    ) {
        aiToolWillStart?()
        aiTask = AITaskStatus(title: title, fraction: 0)
        appliedAIChanges = []
        partialSerial = 0
        let serial = SerialCounter()
        let propose: @Sendable (ProposedChangeSet) -> Void = { [weak self] proposal in
            let number = serial.next()
            Task { @MainActor in self?.applyResults(proposal, serial: number) }
        }
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                guard let self, let task = self.aiTask, task.title == title, fraction > task.fraction else { return }
                self.aiTask?.fraction = min(fraction, 1)
            }
        }
        aiTaskHandle = Task { [weak self] in
            do {
                let final = try await work(report, propose)
                guard let self, !Task.isCancelled else { return }
                self.applyResults(final)
                self.aiTask = nil
                if self.appliedAIChanges.isEmpty {
                    self.reportError("\(title) found nothing to add.", AIError.nothingToDo("Every cue is already as the tool would make it."))
                }
            } catch {
                guard let self else { return }
                self.aiTask = nil
                // What was written before the failure stays (and undoes like any edit).
                if !(error is CancellationError), !Task.isCancelled { self.reportError("\(title) stopped.", error) }
            }
        }
    }

    func cancelAITask() {
        aiTaskHandle?.cancel()
        aiTaskHandle = nil
        aiTask = nil
    }

    /// Cue list cleanup, done by rule on the Mac in an instant.
    private func runCleanup(_ tool: CleanupTool) {
        let proposal = tool.propose(for: track.cues, languageCode: track.languageCode)
        if proposal.isEmpty {
            reportError("\(tool.title) found nothing to change.", AIError.nothingToDo("No cue needs it."))
        } else {
            presentReview(proposal)
        }
    }

    /// The spoken language: the setting, else the audio track's, else the subtitles'.
    var transcriptionLanguage: String? {
        if let setting = aiSettings.transcriptionLanguage { return setting }
        if let language = selectedAudioTrack?.language, !language.isEmpty, language != "und" { return Languages.base(language) }
        let base = isTranslating ? sourceTrack?.languageCode : track.languageCode
        return base.flatMap { $0 == "und" ? nil : $0 }
    }

    private func transcribe() {
        guard let url = status.mediaURL else { return }
        let transcriber: any Transcriber
        do { transcriber = try aiProviders.transcriber(aiSettings) } catch {
            reportError("Transcription could not start.", error)
            return
        }
        let stream = status.audioStreamIndex
        let language = transcriptionLanguage
        let pipeline = TranscriptionPipeline(
            preset: qcPreset, frameRate: frameRate, shotChanges: shotChangeFrames, wordStartLead: transcriber.wordStartLead
        )
        let existing = track.cues
        let prepare = prepareAudio
        let accumulator = TranscriptAccumulator(pipeline: pipeline)
        let provider = aiSettings.transcription
        // Words this project already got from the provider are used again, not paid for and uploaded again.
        let stored = storedTranscript(provider: provider, audioStream: stream, language: language)
        startAITask("Transcription") { [weak self] progress, propose in
            let audio = try await prepare(url, stream) { progress($0 * 0.15) }
            let words: [TranscribedWord]
            if let stored {
                words = stored
            } else {
                words = try await transcriber.transcribe(audio, language: language) { progress(0.15 + $0 * 0.75) } found: { words in
                    // Cues show as soon as they are complete.
                    propose(Proposals.transcription(accumulator.add(words), existing: existing))
                }
                self?.storeTranscript(words, provider: provider, audioStream: stream, language: language)
            }
            guard !words.isEmpty else { throw AIError.nothingToDo("No speech was heard.") }
            let cues = try await Self.runDetached { accumulator.finish(with: words) }
            progress(1)
            return Proposals.transcription(cues, existing: existing)
        }
    }

    /// Who says a cue, as the transcriber labelled the voices: the cue's own
    /// labels (the source cue's when translating), else those of the transcript
    /// words the project keeps that fall inside it (an imported subtitle file).
    func voices(for cue: Cue) -> [String]? {
        let spoken = sourceCues[cue.id] ?? cue
        if let voices = spoken.voices { return voices }
        guard let words = storedTranscripts.last(where: { $0.words.contains { $0.speaker != nil } })?.words else { return nil }
        var voices: [String] = []
        for word in words where word.start < spoken.end && spoken.start < word.end {
            if let speaker = word.speaker, voices.last != speaker, !voices.contains(speaker) { voices.append(speaker) }
        }
        return voices.isEmpty ? nil : voices
    }

    /// Target cues with no text whose source has some.
    var untranslatedCues: [Cue] {
        track.cues.filter { cue in
            SubtitleText.visibleLines(of: cue.text).joined().allSatisfy(\.isWhitespace)
                && sourceCues[cue.id].map { !SubtitleText.visibleLines(of: $0.text).joined().allSatisfy(\.isWhitespace) } == true
        }
    }

    private func translateUntranslatedCues() {
        let translator: any CueTranslator
        do { translator = try aiProviders.translator(aiSettings) } catch {
            reportError("Translation could not start.", error)
            return
        }
        let cues = untranslatedCues
        guard let source = sourceTrack, let first = cues.first else { return }
        let glossaryEntries = glossary.entries.filter { entry in cues.contains { glossaryHits[sourceCues[$0.id]?.id ?? UUID()]?.contains(entry) == true } }
        let context: [(source: String, target: String)] = track.cues.filter { $0.start < first.start && !$0.text.isEmpty }
            .suffix(6).compactMap { cue in sourceCues[cue.id].map { ($0.text, cue.text) } }
        let examples = Dictionary(cues.compactMap { cue in
            sourceCues[cue.id].flatMap { memory.matches(for: $0.text, limit: 1).first }.map { (cue.id, ($0.entry.source, $0.entry.target)) }
        }, uniquingKeysWith: { first, _ in first })
        let lines = cues.map { cue in
            TranslationRequest.Line(
                cueID: cue.id, source: sourceCues[cue.id]?.text ?? "", start: cue.start, end: cue.end, voices: voices(for: cue),
                speakerName: sourceCues[cue.id]?.speaker ?? cue.speaker, memoryExample: examples[cue.id]
            )
        }
        let request = TranslationRequest(
            lines: lines, precedingContext: context, sourceLanguage: source.languageCode, targetLanguage: track.languageCode,
            glossary: glossaryEntries.map { ($0.source, $0.target, $0.note) },
            maxCharactersPerLine: qcPreset.maxCharactersPerLine, maxLines: qcPreset.maxLines, cast: track.cast
        )
        let fixUp = TranslationPipeline(preset: qcPreset)
        startAITask("Translation") { [weak self] progress, propose in
            let found = TranslationCollector()
            let translations = try await translator.translate(request, progress: progress) { batch in
                propose(Proposals.translation(found.add(fixUp.fix(batch, request: request)), cues: cues))
            }
            // Lines the translator never sent back (a model declined them) stay empty: say so.
            let done = Set(translations.translations.filter { !$0.text.isEmpty }.map(\.cueID))
            if let first = cues.first(where: { !done.contains($0.id) }), let self {
                let count = cues.count - cues.filter { done.contains($0.id) }.count
                self.reportError(
                    count == 1 ? "1 line was not translated." : "\(count) lines were not translated.",
                    AIError.nothingToDo(
                        "\(translator.name) sent nothing back for them, the first at \(self.label(for: first.start)). "
                            + "They're marked Not translated: run Translate with AI again to retry them, or translate them yourself."
                    )
                )
            }
            return Proposals.translation(fixUp.fix(translations, request: request), cues: cues)
        }
    }

    /// Starts a translation of the cues being edited (a transcription, an
    /// imported file): they become the read-only source, and the target is
    /// their timing with no text. One undoable edit.
    func useCuesAsSource() {
        var source = track
        if source.languageCode == "und" { source.languageCode = Self.detectLanguage(of: source.cues) ?? transcriptionLanguage ?? "und" }
        let target = defaultTargetLanguage(avoiding: source.languageCode)
        edit("Translate Cues") { track in
            track.cues = source.cues.map { cue in
                Alignment.template(from: [cue])[0]
            }
            track.languageCode = target
        }
        sourceFile = subtitleFile
        sourceTrack = source
        translationPairDidChange()
    }

    // MARK: Audio

    nonisolated static func audioPreparer(
        cache: AnalysisCache?
    ) -> @Sendable (URL, Int?, @escaping @Sendable (Double) -> Void) async throws -> PreparedAudio {
        { url, stream, progress in
            if let cached = cache?.preparedAudio(for: url, audioStream: stream) {
                progress(1)
                return cached
            }
            var options = MediaAnalyzer.Options()
            options.audioStreamIndex = stream
            let result = try await runDetached { [options] in
                try MediaAnalyzer.prepareAudio(of: url, options: options) { report in
                    progress(report.fraction)
                    return !Task.isCancelled
                }
            }
            cache?.store(result, for: url, audioStream: stream)
            return result
        }
    }
}

/// Numbers partial results in the order they were made.
private final class SerialCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}

/// Collects translation batches as they arrive, from any thread.
private final class TranslationCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var all = TranslationBatch()

    func add(_ batch: TranslationBatch) -> TranslationBatch {
        lock.withLock {
            all = all.adding(batch)
            return all
        }
    }
}

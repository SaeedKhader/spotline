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
                }
            },
            translator: { settings in
                switch settings.translation {
                case .appleTranslation:
                    return AppleTranslator()
                case .claude:
                    guard settings.allowsCloud else { throw AIError.cloudNotAllowed }
                    guard let key = keys.key(for: .anthropic) else { throw AIError.missingAPIKey(provider: "Anthropic") }
                    return ClaudeTranslator(apiKey: key)
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
            return idle && isTranslating && !untranslatedCues.isEmpty
        case EditorCommand.detectSpeakers.id:
            return idle && hasMedia && track.cues.contains { !$0.text.isEmpty }
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
        case EditorCommand.translateWithAI.id: translateUntranslatedCues()
        case EditorCommand.detectSpeakers.id: detectSpeakers()
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

    // MARK: Addressee variants

    /// Uses the line as it reads for `addressee` (when the translator wrote it)
    /// and marks the addressee as confirmed. One click, one undoable edit.
    public func chooseAddressee(_ addressee: Addressee, forCue id: Cue.ID) {
        guard let index = track.cues.firstIndex(where: { $0.id == id }) else { return }
        edit("Choose Addressee") { track in
            if let variant = track.cues[index].variants?.first(where: { $0.addressee == addressee }) {
                track.cues[index].text = variant.text
            }
            track.cues[index].addressee = AddresseeTag(addressee, confidence: 1, source: .confirmed)
        }
    }

    /// "A", "B"… for the cast list's speakers, in order.
    public func speakerLabel(_ id: Speaker.ID) -> String? {
        guard let index = track.speakers.firstIndex(where: { $0.id == id }) else { return nil }
        return track.speakers[index].name ?? Self.speakerLetter(index)
    }

    static func speakerLetter(_ index: Int) -> String {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return index < letters.count ? String(letters[index]) : "\(index + 1)"
    }

    // MARK: Running tools

    /// Runs `work` in the background with progress in the actions bar, then shows its proposal for review.
    private func startAITask(
        _ title: String,
        _ work: @escaping @MainActor (@escaping @Sendable (Double) -> Void) async throws -> ProposedChangeSet
    ) {
        aiTask = AITaskStatus(title: title, fraction: 0)
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                guard let self, let task = self.aiTask, task.title == title, fraction > task.fraction else { return }
                self.aiTask?.fraction = min(fraction, 1)
            }
        }
        aiTaskHandle = Task { [weak self] in
            do {
                let proposal = try await work(report)
                guard let self, !Task.isCancelled else { return }
                self.aiTask = nil
                if proposal.isEmpty {
                    self.reportError("\(title) found nothing to change.", AIError.nothingToDo("Every cue is already as the tool would make it."))
                } else {
                    self.presentReview(proposal)
                }
            } catch {
                guard let self else { return }
                self.aiTask = nil
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
        let segmenter = CueSegmenter(preset: qcPreset, frameRate: frameRate, shotChanges: shotChangeFrames)
        let existing = track.cues
        let prepare = prepareAudio
        startAITask("Transcribing") { progress in
            let audio = try await prepare(url, stream) { progress($0 * 0.15) }
            let words = try await transcriber.transcribe(audio, language: language) { progress(0.15 + $0 * 0.75) }
            guard !words.isEmpty else { throw AIError.nothingToDo("No speech was heard.") }
            let (cues, speakers) = try await Self.runDetached {
                let cues = segmenter.cues(from: words)
                return (cues, VoiceSpeakerAnalyzer().analyze(cues, in: audio))
            }
            progress(1)
            return Proposals.transcription(cues, existing: existing, speakers: speakers)
        }
    }

    /// The text each cue says, in the language it was spoken (the source when translating).
    private func spokenLines(of cues: [Cue], speakers: VoiceSpeakerAnalyzer.Result?) -> [SceneAddresseeInferrer.Line] {
        cues.map { cue in
            let assignment = speakers?.assignments[cue.id]
            return SceneAddresseeInferrer.Line(
                cueID: cue.id, text: sourceCues[cue.id]?.text ?? cue.text, start: cue.start, end: cue.end,
                speakerID: assignment?.speakerID ?? cue.speakerID, speakerConfidence: assignment?.confidence ?? (cue.speakerID == nil ? 0 : 0.8)
            )
        }
    }

    private var spokenLanguage: String {
        (isTranslating ? sourceTrack?.languageCode : track.languageCode) ?? "und"
    }

    private func detectSpeakers() {
        guard let url = status.mediaURL else { return }
        let stream = status.audioStreamIndex
        let cues = track.cues.filter { !$0.text.isEmpty }
        let snapshot = track
        let language = spokenLanguage
        let prepare = prepareAudio
        startAITask("Detecting speakers") { [weak self] progress in
            let audio = try await prepare(url, stream) { progress($0 * 0.4) }
            let result = try await Self.runDetached {
                VoiceSpeakerAnalyzer().analyze(cues, in: audio).reusingSpeakers(of: cues, from: snapshot.speakers)
            }
            progress(0.9)
            guard let self else { throw CancellationError() }
            let lines = self.spokenLines(of: cues, speakers: result)
            let tags = SceneAddresseeInferrer().infer(lines, speakers: result.speakers, language: language)
            return Proposals.speakers(for: cues, track: snapshot, result: result, addressees: tags)
        }
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
        let targetLanguage = track.languageCode
        let gendered = Languages.addressesByGender(targetLanguage)
        // Speakers are found first when the target language needs them and nobody has run detection.
        let needsSpeakers = gendered && hasMedia && track.speakers.isEmpty
        let url = status.mediaURL, stream = status.audioStreamIndex
        let prepare = prepareAudio
        let snapshot = track
        let glossaryEntries = glossary.entries.filter { entry in cues.contains { glossaryHits[sourceCues[$0.id]?.id ?? UUID()]?.contains(entry) == true } }
        let context: [(source: String, target: String)] = track.cues.filter { $0.start < first.start && !$0.text.isEmpty }
            .suffix(6).compactMap { cue in sourceCues[cue.id].map { ($0.text, cue.text) } }
        let examples = Dictionary(cues.compactMap { cue in
            sourceCues[cue.id].flatMap { memory.matches(for: $0.text, limit: 1).first }.map { (cue.id, ($0.entry.source, $0.entry.target)) }
        }, uniquingKeysWith: { first, _ in first })
        startAITask("Translating") { [weak self] progress in
            var speakers: VoiceSpeakerAnalyzer.Result?
            if needsSpeakers, let url {
                let audio = try await prepare(url, stream) { progress($0 * 0.15) }
                speakers = try await Self.runDetached { VoiceSpeakerAnalyzer().analyze(cues, in: audio) }
            }
            guard let self else { throw CancellationError() }
            let cast = speakers?.speakers ?? snapshot.speakers
            let tags = gendered
                ? SceneAddresseeInferrer().infer(self.spokenLines(of: cues, speakers: speakers), speakers: cast, language: source.languageCode)
                : [:]
            let lines = cues.map { cue -> TranslationRequest.Line in
                let speakerID = speakers?.assignments[cue.id]?.speakerID ?? cue.speakerID
                let hint = speakerID.flatMap { id in cast.firstIndex { $0.id == id } }.map { index in
                    TranslationRequest.SpeakerHint(label: Self.speakerLetter(index), gender: cast[index].gender, confidence: cast[index].confidence)
                }
                return TranslationRequest.Line(
                    cueID: cue.id, source: self.sourceCues[cue.id]?.text ?? "", start: cue.start, end: cue.end, speaker: hint,
                    addressee: cue.addressee?.source == .confirmed ? cue.addressee : tags[cue.id] ?? cue.addressee,
                    memoryExample: examples[cue.id]
                )
            }
            let request = TranslationRequest(
                lines: lines, precedingContext: context, sourceLanguage: source.languageCode, targetLanguage: targetLanguage,
                glossary: glossaryEntries.map { ($0.source, $0.target, $0.note) },
                maxCharactersPerLine: self.qcPreset.maxCharactersPerLine, maxLines: self.qcPreset.maxLines
            )
            let start = needsSpeakers ? 0.15 : 0
            let translations = try await translator.translate(request) { progress(start + $0 * (1 - start)) }
            var proposal = Proposals.translation(translations, cues: cues)
            if let speakers {
                // The speakers found on the way go into the same review.
                for index in proposal.changes.indices {
                    proposal.changes[index].cue.speakerID = speakers.assignments[proposal.changes[index].cueID]?.speakerID
                }
                proposal.newSpeakers = speakers.speakers
            }
            return proposal
        }
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

extension VoiceSpeakerAnalyzer.Result {
    /// Keeps the IDs (and confirmed genders) of speakers the track already has:
    /// a new speaker whose cues mostly belonged to an existing one becomes that one.
    func reusingSpeakers(of cues: [Cue], from existing: [Speaker]) -> Self {
        guard !existing.isEmpty else { return self }
        var result = self
        var taken: Set<Speaker.ID> = []
        for (index, speaker) in speakers.enumerated() {
            let previous = cues.filter { assignments[$0.id]?.speakerID == speaker.id }.compactMap(\.speakerID)
            let counts = Dictionary(previous.map { ($0, 1) }, uniquingKeysWith: +)
            guard let (oldID, _) = counts.filter({ !taken.contains($0.key) }).max(by: { $0.value < $1.value }),
                  let old = existing.first(where: { $0.id == oldID })
            else { continue }
            taken.insert(oldID)
            result.speakers[index] = old.source == .confirmed ? old : Speaker(
                id: old.id, name: old.name, gender: speaker.gender, confidence: speaker.confidence, source: .inferred
            )
            for (cueID, assignment) in assignments where assignment.speakerID == speaker.id {
                result.assignments[cueID]?.speakerID = oldID
            }
        }
        return result
    }
}

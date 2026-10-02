import AITools
import AppKit
import EditorCommands
import Foundation
import MediaAnalysis
import SubtitleCore
import SubtitleTranslation
import Synchronization

/// Makes providers for the current settings. `live` uses the real ones (API keys
/// from the Keychain), `scripted` fixed answers for UI tests.
@MainActor
public struct AIProviderFactory {
    public var transcriber: @MainActor (AISettings) throws -> any Transcriber
    public var translator: @MainActor (AISettings) throws -> any CueTranslator
    /// Builds the episode brief after transcription; nil when there is none to use.
    public var briefBuilder: @MainActor (AISettings) throws -> (any EpisodeBriefBuilder)?
    /// Reviews the transcript once the brief is confirmed; nil when there is none to use.
    public var scriptReviewer: @MainActor (AISettings) throws -> (any ScriptReviewer)?
    /// Describes each scene from its picked frames, for the brief; nil when there is none to use.
    public var sceneDescriber: @MainActor (AISettings) throws -> (any SceneDescriber)?

    public init(
        transcriber: @escaping @MainActor (AISettings) throws -> any Transcriber,
        translator: @escaping @MainActor (AISettings) throws -> any CueTranslator,
        briefBuilder: @escaping @MainActor (AISettings) throws -> (any EpisodeBriefBuilder)? = { _ in nil },
        scriptReviewer: @escaping @MainActor (AISettings) throws -> (any ScriptReviewer)? = { _ in nil },
        sceneDescriber: @escaping @MainActor (AISettings) throws -> (any SceneDescriber)? = { _ in nil }
    ) {
        self.transcriber = transcriber
        self.translator = translator
        self.briefBuilder = briefBuilder
        self.scriptReviewer = scriptReviewer
        self.sceneDescriber = sceneDescriber
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
                    return ClaudeTranslator(
                        apiKey: key, model: settings.translation.claudeModel ?? ClaudeTranslator.defaultModel,
                        effort: settings.reasoningEffort
                    )
                case .openAILuna:
                    guard settings.allowsCloud else { throw AIError.cloudNotAllowed }
                    guard let key = keys.key(for: .openAI) else { throw AIError.missingAPIKey(provider: "OpenAI") }
                    return OpenAITranslator(apiKey: key, effort: settings.reasoningEffort)
                }
            },
            briefBuilder: { settings in
                // GPT-6 Luna builds it, whatever translates: it costs about 4 cents an episode.
                guard settings.allowsCloud else { throw AIError.cloudNotAllowed }
                guard let key = keys.key(for: .openAI) else { throw AIError.missingAPIKey(provider: "OpenAI") }
                return OpenAIBriefBuilder(apiKey: key, model: settings.brief.model.rawValue, effort: settings.brief.effort)
            },
            scriptReviewer: { settings in
                guard settings.allowsCloud else { throw AIError.cloudNotAllowed }
                guard let key = keys.key(for: .openAI) else { throw AIError.missingAPIKey(provider: "OpenAI") }
                return OpenAIScriptReviewer(apiKey: key, model: settings.scriptReview.model.rawValue, effort: settings.scriptReview.effort)
            },
            sceneDescriber: { settings in
                guard settings.allowsCloud else { throw AIError.cloudNotAllowed }
                guard settings.sendsVideoFrames else { throw AIError.videoFramesNotAllowed }
                guard let key = keys.key(for: .openAI) else { throw AIError.missingAPIKey(provider: "OpenAI") }
                return OpenAISceneDescriber(apiKey: key, model: settings.scenes.model.rawValue, effort: settings.scenes.effort)
            }
        )
    }

    /// Fixed answers. The episode brief and script review only with `buildsBrief`
    /// (`-UITestEpisodeBrief`), so UI tests of other tools don't get its dialog after transcribing.
    public static func scripted(buildsBrief: Bool = false) -> AIProviderFactory {
        AIProviderFactory(
            transcriber: { _ in ScriptedTranscriber.fixture },
            translator: { _ in ScriptedTranslator() },
            briefBuilder: { _ in buildsBrief ? ScriptedBriefBuilder() : nil },
            scriptReviewer: { _ in buildsBrief ? ScriptedScriptReviewer() : nil },
            sceneDescriber: { _ in buildsBrief ? ScriptedSceneDescriber() : nil }
        )
    }
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
        case EditorCommand.syncSubtitlesToAudio.id:
            return idle && !isTranslating && subtitleSync == nil && transcriptToMatch != nil && !cuesOfTheirOwn.isEmpty
        case EditorCommand.applySubtitleSync.id:
            return subtitleSync != nil
        case EditorCommand.translateWithAI.id:
            // Outside translation mode, the cues being edited become the source.
            return idle && (isTranslating ? !untranslatedCues.isEmpty : track.cues.contains { !$0.text.isEmpty })
        case EditorCommand.clearTranslation.id:
            return idle && isTranslating && track.cues.contains { !$0.text.isEmpty || $0.flag != nil }
        case EditorCommand.clearTranscript.id:
            return idle && (!storedTranscripts.isEmpty || !(sourceTrack ?? track).cues.isEmpty)
        case EditorCommand.reviewWords.id:
            return !cuesToCheck.isEmpty
        case EditorCommand.confirmRemainingWords.id:
            return !cuesToCheck.isEmpty
        case EditorCommand.reviewChoices.id:
            return track.cues.contains { $0.flag?.isResolved == false }
        case EditorCommand.acceptRemainingChoices.id:
            return track.cues.contains { $0.flag?.isResolved == false }
        case EditorCommand.maskProfanity.id, EditorCommand.removeHearingImpaired.id, EditorCommand.fixPunctuation.id:
            return idle && !track.cues.isEmpty
        case EditorCommand.cancelAITask.id:
            return aiTask != nil || aiFlow != nil
        case EditorCommand.acceptChange.id, EditorCommand.rejectChange.id:
            return selectedCueID.flatMap { pendingReview?.change(forCue: $0) } != nil
        case EditorCommand.acceptAllChanges.id, EditorCommand.rejectAllChanges.id:
            return pendingReview != nil
        case EditorCommand.reviewChanges.id:
            return pendingReview != nil
        case EditorCommand.showEpisodeBrief.id:
            return track.brief != nil || (idle && !briefSourceTrack.cues.isEmpty)
        case EditorCommand.rebuildEpisodeBrief.id:
            return track.brief != nil && idle && !briefSourceTrack.cues.isEmpty
        case EditorCommand.reviewScriptWithAI.id:
            return idle && !isTranslating && track.brief?.isConfirmed == true && !track.cues.isEmpty
        case EditorCommand.reviewScriptFindings.id:
            return track.cues.contains { $0.scriptFinding != nil }
        default:
            return false
        }
    }

    func performAI(_ command: EditorCommand) -> Bool {
        switch command.id {
        case EditorCommand.transcribe.id: transcribe()
        case EditorCommand.syncSubtitlesToAudio.id: checkSubtitleSync()
        case EditorCommand.applySubtitleSync.id: applySubtitleSync()
        case EditorCommand.translateWithAI.id:
            // Words the transcription was unsure of would be translated wrong too: offer to check them first.
            let unsure = cuesWithUnsureSource
            if !unsure.isEmpty {
                switch confirmTranslatingUnsureCues(unsure.count) {
                case .review:
                    showReview(.words)
                    return true
                case .cancel:
                    return false
                case .translateAnyway:
                    break
                }
            }
            if !isTranslating { useCuesAsSource() }
            translateUntranslatedCues()
        case EditorCommand.clearTranslation.id: clearTranslation()
        case EditorCommand.clearTranscript.id:
            guard confirmClearingTranscript(isTranslating) else { return false }
            clearTranscript()
        case EditorCommand.reviewWords.id: toggleReviewFilter(.words)
        case EditorCommand.confirmRemainingWords.id: confirmRemainingWords()
        case EditorCommand.reviewChoices.id: toggleReviewFilter(.choices)
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
        case EditorCommand.reviewChanges.id: toggleReviewFilter(.changes)
        case EditorCommand.showEpisodeBrief.id: showEpisodeBrief()
        case EditorCommand.reviewScriptWithAI.id: reviewScript(automatically: false)
        case EditorCommand.reviewScriptFindings.id: toggleReviewFilter(.script)
        case EditorCommand.rebuildEpisodeBrief.id:
            isBriefSheetShown = false
            buildEpisodeBrief(automatically: false)
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
        reviewItemID = nil
        if let first = review.changes.min(by: { $0.cue.start < $1.cue.start }) { select(first.cueID) }
        showReview(.changes)
    }

    /// "transcription", "translation" or "an agent", for the tint's tooltip.
    func aiToolName(for cue: Cue) -> String {
        if agentWrittenCues.contains(cue.id) { return "an agent" }
        return sourceCues[cue.id] != nil ? "translation" : "transcription"
    }

    // MARK: Words to check

    /// Cues with words the transcriber was unsure of, least sure first: what the word review shows.
    public var cuesToCheck: [Cue] {
        func certainty(_ cue: Cue) -> Double { cue.unsureWords?.compactMap(\.confidence).min() ?? 0.5 }
        return track.cues.filter { $0.unsureWords?.isEmpty == false }
            .sorted { (certainty($0), $0.start) < (certainty($1), $1.start) }
    }

    /// How many words are still to check.
    public var wordsToCheckCount: Int {
        track.cues.reduce(0) { $0 + ($1.unsureWords?.count ?? 0) }
    }

    /// Selects a word to check in its cue's text, to type over it.
    public func selectUnsureWord(_ index: Int, forCue id: Cue.ID) {
        guard let word = cue(withID: id)?.unsureWords?[safe: index] else { return }
        select(id)
        wordSelectionRequest = WordSelectionRequest(cueID: id, word: word.text, serial: (wordSelectionRequest?.serial ?? 0) + 1)
        textFocusRequest += 1
    }

    /// Keeps a word as the transcriber heard it: one undoable edit.
    public func confirmUnsureWord(_ index: Int, forCue id: Cue.ID) {
        guard let cueIndex = track.cues.firstIndex(where: { $0.id == id }), let words = track.cues[cueIndex].unsureWords,
              words.indices.contains(index)
        else { return }
        edit("Confirm Word") { track in
            var remaining = words
            remaining.remove(at: index)
            track.cues[cueIndex].unsureWords = remaining.isEmpty ? nil : remaining
        }
    }

    /// Keeps every word still to check, as one undoable edit.
    func confirmRemainingWords() {
        edit(EditorCommand.confirmRemainingWords.title) { track in
            for index in track.cues.indices { track.cues[index].unsureWords = nil }
        }
    }

    /// Plays a word to check with a moment before and after, then pauses.
    public func playUnsureWord(_ index: Int, forCue id: Cue.ID) {
        guard hasMedia, let word = cue(withID: id)?.unsureWords?[safe: index], let start = word.start else { return }
        let lead = MediaTime(value: 300, timescale: 1000)
        let from = start > lead ? start - lead : .zero
        playback.seek(toFrame: from.firstFrame(at: frameRate), rate: frameRate)
        playbackStopTime = (word.end ?? start) + lead
        playback.play(rate: 1)
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
        edit("Choose Translation") { track in track.choose(variant: index, forCue: id) }
    }

    /// Settles every open flag as it stands, as one undoable edit.
    func acceptRemainingChoices() {
        reviewTrials = reviewTrials.filter { $0.value.item.kind != .choice }
        edit(EditorCommand.acceptRemainingChoices.title) { track in track.resolveFlags() }
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

    /// Runs `work` in the background with its progress over the cue list. Results it
    /// passes to `propose` go into the track at once; its final result adds the rest.
    /// `summary` says what the tool did, from the cues it wrote.
    private func startAITask(
        _ status: AITaskStatus,
        afterward: (@MainActor () -> Void)? = nil,
        whenNothingWritten: (@MainActor () -> AITaskSummary?)? = nil,
        summary: @escaping @MainActor (_ written: [Cue]) -> AITaskSummary,
        _ work: @escaping @MainActor (
            _ report: @escaping @Sendable (AITaskStep) -> Void, _ propose: @escaping @Sendable (ProposedChangeSet) -> Void
        ) async throws -> ProposedChangeSet
    ) {
        aiToolWillStart?()
        let title = status.title
        aiSummary = nil
        aiTask = status
        aiTaskGeneration += 1
        let generation = aiTaskGeneration
        appliedAIChanges = []
        partialSerial = 0
        reportSerial = 0
        let serial = SerialCounter()
        let propose: @Sendable (ProposedChangeSet) -> Void = { [weak self] proposal in
            let number = serial.next()
            Task { @MainActor in self?.applyResults(proposal, serial: number) }
        }
        let reports = SerialCounter()
        let report: @Sendable (AITaskStep) -> Void = { [weak self] step in
            let number = reports.next()
            let now = Date()
            Task { @MainActor in
                // Reports can arrive out of order, or from a task that was cancelled.
                guard let self, self.aiTaskGeneration == generation, self.aiTask != nil, number > self.reportSerial else { return }
                self.reportSerial = number
                switch step {
                case .provider(let progress): self.aiTask?.update(with: progress, now: now)
                case .stage(let name, let detail, let fraction): self.aiTask?.enter(name, detail: detail, fraction: fraction)
                case .usualWait(let seconds): self.aiTask?.usualWait = seconds
                }
            }
        }
        aiTaskHandle = Task { [weak self] in
            do {
                let final = try await work(report, propose)
                guard let self, !Task.isCancelled else { return }
                self.applyResults(final)
                let written = self.track.cues.filter { self.appliedAIChanges.contains($0.id) }
                self.aiTask = nil
                // A tool that had cues of the user's to work with wrote none, and says what it did instead.
                if written.isEmpty, let done = whenNothingWritten?() {
                    self.show(done)
                    if !self.reviewItems(in: .all).isEmpty { self.wantsReviewSidebar = true }
                    self.onAITaskEnd?(AITaskEnd(title: "\(title) finished", message: done.fullText, succeeded: true))
                    return
                }
                if written.isEmpty {
                    afterward?()
                    self.reportError("\(title) found nothing to add.", AIError.nothingToDo("Every cue is already as the tool would make it."))
                    self.onAITaskEnd?(AITaskEnd(title: "\(title) found nothing to add", message: "Every cue is already as the tool would make it.", succeeded: false))
                    return
                }
                let done = summary(written)
                afterward?()
                self.show(done)
                if !self.reviewItems(in: .all).isEmpty { self.wantsReviewSidebar = true }
                self.onAITaskEnd?(AITaskEnd(title: "\(title) finished", message: done.fullText, succeeded: true))
            } catch {
                guard let self else { return }
                self.aiTask = nil
                self.endAIFlow()
                // What was written before the failure stays (and undoes like any edit).
                if !(error is CancellationError), !Task.isCancelled {
                    self.reportError("\(title) stopped.", error)
                    self.onAITaskEnd?(AITaskEnd(title: "\(title) stopped", message: error.localizedDescription, succeeded: false))
                }
            }
        }
    }

    func cancelAITask() {
        aiTaskHandle?.cancel()
        aiTaskHandle = nil
        aiTask = nil
        endAIFlow()
    }

    /// Shows what a tool did in the AI bar until `aiSummaryDuration` has passed or another tool starts.
    func show(_ summary: AITaskSummary) {
        aiSummary = summary
        let generation = aiTaskGeneration
        let duration = aiSummaryDuration
        Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard let self, self.aiTaskGeneration == generation, self.aiSummary == summary else { return }
            self.aiSummary = nil
        }
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

    func transcribe() {
        guard let url = status.mediaURL else { return }
        let transcriber: any Transcriber
        do { transcriber = try aiProviders.transcriber(aiSettings) } catch {
            reportError("Transcription could not start.", error)
            return
        }
        let stream = status.audioStreamIndex
        let language = transcriptionLanguage
        let basePipeline = TranscriptionPipeline(
            preset: qcPreset, frameRate: frameRate, shotChanges: shotChangeFrames, wordStartLead: transcriber.wordStartLead,
            keepsSoundDescriptions: aiSettings.includesSoundDescriptions
        )
        let leavesOutWalla = aiSettings.leavesOutWalla
        let existing = track.cues
        // Cues with words of their own (a subtitle file's, or typed) may be the audio's subtitles
        // already: then the transcript adds no cues, and is matched to them instead.
        let own = isTranslating ? [] : cuesOfTheirOwn
        let listened = Mutex<TranscriptAlignment?>(nil)
        let prepare = prepareAudio
        let provider = aiSettings.transcription
        // Words this project already got from the provider are used again, not paid for and uploaded again.
        let stored = storedTranscript(provider: provider, audioStream: stream, language: language)
        // With a subtitle file's cues, it says what it is doing to them.
        let title = matchesSubtitlesToAudio ? "Audio Match" : "Transcription"
        let status = if stored != nil {
            AITaskStatus(
                title: title, provider: transcriber.name, stages: (leavesOutWalla ? ["Preparing audio"] : []) + ["Transcribing"],
                detail: "Using the saved transcript"
            )
        } else {
            AITaskStatus(
                title: title, provider: transcriber.name,
                stages: ["Preparing audio"] + (transcriber.uploadsInOnePiece ? ["Compressing audio", "Uploading"] : []) + ["Transcribing"]
            )
        }
        // Then the episode brief, and the review waits until it is confirmed.
        startAITask(
            status, afterward: { [weak self] in self?.afterListening() },
            whenNothingWritten: { [weak self] in
                listened.withLock { $0 }.flatMap { self?.addTranscript($0, thenBrief: true) }
            }, summary: Self.transcriptionSummary
        ) { [weak self] report, propose in
            let words: [TranscribedWord]
            let accumulator: TranscriptAccumulator
            var pipeline = basePipeline
            func prepared() async throws -> PreparedAudio {
                let audio = try await prepare(url, stream) { report(.stage("Preparing audio", detail: "Preparing audio · \(AITaskStatus.percent($0))", fraction: $0)) }
                // Walla is told from the dialogue around it by how loud each voice is.
                if leavesOutWalla { pipeline.walla = WallaFilter(levels: SpeechLevels(audio)) }
                return audio
            }
            if let stored {
                // Without the audio (the video is gone), the saved words are used as they are.
                if leavesOutWalla {
                    do { _ = try await prepared() } catch is CancellationError { throw CancellationError() } catch {}
                    report(.stage("Transcribing", detail: "Using the saved transcript", fraction: nil))
                }
                accumulator = TranscriptAccumulator(pipeline: pipeline)
                words = stored
            } else {
                let audio = try await prepared()
                accumulator = TranscriptAccumulator(pipeline: pipeline)
                // How long the provider takes once it has the audio is timed, to say how long it usually takes next time.
                let seconds = audio.duration.seconds
                if let rate = self?.waitRates[provider.rawValue] { report(.usualWait(rate * seconds)) }
                let waitStarted = Mutex<Date?>(nil)
                words = try await transcriber.transcribe(audio, language: language) { progress in
                    if case .waiting = progress { waitStarted.withLock { if $0 == nil { $0 = Date() } } }
                    report(.provider(progress))
                } found: { words in
                    // Cues show as soon as they are complete; not while they may be in the track already.
                    if own.isEmpty { propose(Proposals.transcription(accumulator.add(words), existing: existing)) }
                }
                if let started = waitStarted.withLock({ $0 }), seconds > 0 {
                    self?.recordWait(Date().timeIntervalSince(started) / seconds, provider: provider.rawValue)
                }
                self?.storeTranscript(words, provider: provider, audioStream: stream, language: language)
            }
            guard !words.isEmpty else { throw AIError.nothingToDo("No speech was heard.") }
            if !own.isEmpty {
                let heard = pipeline.corrected(words)
                let alignment = try await Self.runDetached { TranscriptAligner.align(own, to: heard) }
                if alignment.coversAudio {
                    listened.withLock { $0 = alignment }
                    return ProposedChangeSet(title: "Transcription", changes: [])
                }
            }
            let cues = try await Self.runDetached { accumulator.finish(with: words) }
            return Proposals.transcription(cues, existing: existing)
        }
    }

    /// Seconds of waiting per second of audio, by provider, from earlier runs.
    var waitRates: [String: Double] {
        get {
            if cachedWaitRates == nil { cachedWaitRates = settings?.dictionary(forKey: Self.waitRatesKey) as? [String: Double] ?? [:] }
            return cachedWaitRates ?? [:]
        }
        set {
            cachedWaitRates = newValue
            settings?.set(newValue, forKey: Self.waitRatesKey)
        }
    }

    static let waitRatesKey = "AIProviderWaitRates"

    /// Takes in a wait just timed, weighted with the ones before so one slow day doesn't set it.
    func recordWait(_ rate: Double, provider: String) {
        guard rate.isFinite, rate > 0 else { return }
        waitRates[provider] = waitRates[provider].map { $0 * 0.5 + rate * 0.5 } ?? rate
    }

    /// "212 cues transcribed · 9 with words to check".
    static func transcriptionSummary(_ written: [Cue]) -> AITaskSummary {
        let unsure = written.count(where: { $0.unsureWords?.isEmpty == false })
        return AITaskSummary(
            text: written.count == 1 ? "1 cue transcribed" : "\(written.count) cues transcribed",
            followUp: unsure == 0 ? nil : "\(unsure) with words to check"
        )
    }

    /// "640 lines translated · 12 flagged".
    static func translationSummary(_ written: [Cue]) -> AITaskSummary {
        let flagged = written.count(where: { $0.flag?.isResolved == false })
        return AITaskSummary(
            text: written.count == 1 ? "1 line translated" : "\(written.count) lines translated",
            followUp: flagged == 0 ? nil : "\(flagged) flagged"
        )
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

    /// The cues about to become a translation's source that have words the
    /// transcription was unsure of. In translation mode the source can't be edited;
    /// the translator gets the words marked instead, and flags lines that read misheard.
    var cuesWithUnsureSource: [Cue] {
        isTranslating ? [] : cuesToCheck
    }

    /// Target cues with no text whose source has some.
    var untranslatedCues: [Cue] {
        track.cues.filter { cue in
            SubtitleText.visibleLines(of: cue.text).joined().allSatisfy(\.isWhitespace)
                && sourceCues[cue.id].map { !SubtitleText.visibleLines(of: $0.text).joined().allSatisfy(\.isWhitespace) } == true
        }
    }

    func translateUntranslatedCues() {
        let translator: any CueTranslator
        do { translator = try aiProviders.translator(aiSettings) } catch {
            reportError("Translation could not start.", error)
            return
        }
        // Without sound descriptions, a line of nothing else is not translated (its empty cue goes afterwards).
        let keepsSounds = aiSettings.includesSoundDescriptions
        func spoken(_ text: String) -> String { keepsSounds ? text : CleanupTool.withoutSoundDescriptions(text) }
        let cues = untranslatedCues.filter { cue in sourceCues[cue.id].map { !spoken($0.text).isEmpty } ?? true }
        guard let source = sourceTrack, let first = cues.first else {
            removeCuesOfSoundsOnly()
            return
        }
        let glossaryEntries = glossary.entries.filter { entry in cues.contains { glossaryHits[sourceCues[$0.id]?.id ?? UUID()]?.contains(entry) == true } }
        let context: [(source: String, target: String)] = track.cues.filter { $0.start < first.start && !$0.text.isEmpty }
            .suffix(20).compactMap { cue in sourceCues[cue.id].map { ($0.text, cue.text) } }
        let examples = Dictionary(cues.compactMap { cue in
            sourceCues[cue.id].flatMap { memory.matches(for: $0.text, limit: 1).first }.map { (cue.id, ($0.entry.source, $0.entry.target)) }
        }, uniquingKeysWith: { first, _ in first })
        let lines = cues.map { cue in
            TranslationRequest.Line(
                cueID: cue.id, source: spoken(sourceCues[cue.id]?.text ?? ""), start: cue.start, end: cue.end, voices: voices(for: cue),
                speakerName: sourceCues[cue.id]?.speaker ?? cue.speaker, memoryExample: examples[cue.id],
                unsureWords: sourceCues[cue.id]?.unsureWords?.map(\.text)
            )
        }
        let script = source.cues.compactMap { cue -> TranslationRequest.ScriptLine? in
            let text = spoken(cue.text)
            return text.isEmpty ? nil : TranslationRequest.ScriptLine(
                start: cue.start, voice: (cue.speaker.map { [$0] } ?? cue.voices)?.joined(separator: " then "), text: text
            )
        }
        // The confirmed brief's terms go too, where the glossary has no translation of its own.
        let briefTerms = (track.brief?.isConfirmed == true && track.brief?.targetLanguage == track.languageCode ? track.brief?.terms ?? [] : [])
            .filter { term in
                !term.translation.isEmpty && !glossaryEntries.contains { MatchText.normalize($0.source) == MatchText.normalize(term.term) }
            }
        let request = TranslationRequest(
            lines: lines, precedingContext: context, sourceLanguage: source.languageCode, targetLanguage: track.languageCode,
            glossary: glossaryEntries.map { ($0.source, $0.target, $0.note) } + briefTerms.map { ($0.term, $0.translation, $0.note) },
            maxCharactersPerLine: qcPreset.maxCharactersPerLine, maxLines: qcPreset.maxLines, cast: track.cast,
            work: workTitle, notes: translatorNotesWithBrief, script: script, style: aiSettings.translationStyle,
            leavesOutWalla: aiSettings.leavesOutWalla, leavesOutFictionalLanguages: aiSettings.leavesOutFictionalLanguages
        )
        let fixUp = TranslationPipeline(preset: qcPreset)
        let joinsLines = aiSettings.joinsLinesAfterTranslating
        // A sentence over several cues goes as one line, and its translation is shared out again.
        let (ungrouped, groups) = SentenceSpans.grouping(request)
        // Cloud translators hear how loud each line is next to the dialogue around it,
        // from the audio (usually cached from transcribing), to tell crowd chatter.
        let hintsFrom = aiSettings.leavesOutWalla && aiSettings.translation.isCloud ? status.mediaURL : nil
        let stream = status.audioStreamIndex
        let prepare = prepareAudio
        let sourceSpans = source.cues.sorted { $0.start < $1.start }.map { ($0.id, $0.start, $0.end) }
        let sourceIDs = Dictionary(ungrouped.lines.map { ($0.cueID, sourceCues[$0.cueID]?.id) }, uniquingKeysWith: { first, _ in first })
        let status = AITaskStatus(
            title: "Translation", provider: translator.name, stages: (hintsFrom != nil ? ["Preparing audio"] : []) + ["Translating"],
            detail: "\(AITaskStatus.shortName(translator.name)) · 0 of \(ungrouped.lines.count) lines"
        )
        // Lines the translator marked to be left out (crowd chatter, a made-up language), removed once it is done.
        let leftOut = Mutex<[Cue.ID: CueTranslation.LeftOut]>([:])
        startAITask(
            status, afterward: { [weak self] in
                if !keepsSounds { self?.removeCuesOfSoundsOnly() }
                self?.removeLeftOut(leftOut.withLock { $0 })
                if joinsLines { self?.joinTranslatedLines() }
                self?.aiFlowFinished(.translate)
            }, summary: Self.translationSummary
        ) { [weak self] report, propose in
            var grouped = ungrouped
            if let url = hintsFrom {
                do {
                    let audio = try await prepare(url, stream) { report(.stage("Preparing audio", detail: "Preparing audio · \(AITaskStatus.percent($0))", fraction: $0)) }
                    let quieter = WallaFilter(levels: SpeechLevels(audio)).quieterBy(sourceSpans.map { ($0.1, $0.2) })
                    let byID = Dictionary(zip(sourceSpans.map(\.0), quieter), uniquingKeysWith: { first, _ in first })
                    for index in grouped.lines.indices {
                        grouped.lines[index].quieterBy = sourceIDs[grouped.lines[index].cueID].flatMap { $0 }.flatMap { byID[$0] }.flatMap { $0 }
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Without the audio, the translator goes by the words alone.
                }
                report(.stage("Translating", detail: "\(AITaskStatus.shortName(translator.name)) · 0 of \(grouped.lines.count) lines", fraction: nil))
            }
            let request = grouped
            let found = TranslationCollector()
            let whole = try await translator.translate(request, progress: { report(.provider($0)) }) { batch in
                propose(Proposals.translation(found.add(fixUp.spread(fixUp.fix(batch, request: request), groups: groups, request: request)), cues: cues))
            }
            let translations = fixUp.spread(whole, groups: groups, request: request)
            // Lines the translator never sent back (a model declined them) stay empty: say so.
            leftOut.withLock { marked in
                marked = Dictionary(translations.translations.compactMap { t in t.leftOut.map { (t.cueID, $0) } }, uniquingKeysWith: { first, _ in first })
            }
            let done = Set(translations.translations.filter(\.isAnswered).map(\.cueID))
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
            return Proposals.translation(fixUp.spread(fixUp.fix(whole, request: request), groups: groups, request: request), cues: cues)
        }
    }

    /// What is being translated, from the video's file name without release tags:
    /// "A Knight of the Seven Kingdoms (2026) S01E01 The Hedge Knight".
    var workTitle: String? {
        guard let url = status.mediaURL ?? mediaReference.map({ URL(fileURLWithPath: $0.path) }) else { return nil }
        return Self.workTitle(fromFileName: url.deletingPathExtension().lastPathComponent)
    }

    static func workTitle(fromFileName name: String) -> String? {
        var title = name.replacing(/\[[^\]]*\]/, with: "")
        // Parentheses with release details go; a year stays.
        title = title.replacing(/\(([^)]*)\)/) { match in
            let inside = String(match.output.1)
            return inside.wholeMatch(of: /(19|20)\d\d/) != nil ? "(\(inside))" : ""
        }
        if !title.contains(" ") { title = title.replacing(/[._]/, with: " ") }
        // Everything from the first release tag on goes.
        if let tag = title.firstMatch(of: /(?i)\b(\d{3,4}p|web-?(rip|dl)?|bluray|bdrip|hdtv|x26[45]|h\.?26[45]|hevc|remux|amzn|nf|hdr|dv)\b/) {
            title = String(title[..<tag.range.lowerBound])
        }
        title = title.replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespaces.union(["-"]))
        return title.isEmpty ? nil : title
    }

    /// Removes the empty target cues whose source is only sound descriptions
    /// ("(door opens)"): subtitles for the hearing leave them out. One undoable edit.
    func removeCuesOfSoundsOnly() {
        let ids = Set(track.cues.filter { cue in
            SubtitleText.visibleLines(of: cue.text).joined().allSatisfy(\.isWhitespace)
                && sourceCues[cue.id].map { !$0.text.isEmpty && CleanupTool.withoutSoundDescriptions($0.text).isEmpty } == true
        }.map(\.id))
        guard !ids.isEmpty else { return }
        edit("Remove Sound Descriptions") { track in track.cues.removeAll { ids.contains($0.id) } }
    }

    /// Removes the cues the translator marked to be left out that are still empty:
    /// crowd chatter (walla) and lines in a made-up language. One undoable edit for each.
    func removeLeftOut(_ marked: [Cue.ID: CueTranslation.LeftOut]) {
        let empty = track.cues.filter { marked[$0.id] != nil && SubtitleText.visibleLines(of: $0.text).joined().allSatisfy(\.isWhitespace) }
        for (reason, name) in [(CueTranslation.LeftOut.walla, "Remove Crowd Chatter"), (.fictionalLanguage, "Remove Made-Up Language")] {
            let ids = Set(empty.filter { marked[$0.id] == reason }.map(\.id))
            guard !ids.isEmpty else { continue }
            edit(name) { track in track.cues.removeAll { ids.contains($0.id) } }
        }
    }

    // MARK: Joining lines

    /// Joins the lines a translation just wrote that nobody has edited since
    /// (`CueJoiner`): one undoable edit after the translation's own.
    func joinTranslatedLines() {
        let written = appliedAIChanges
        let proposal = joinProposal { written.contains($0.id) && $0.isAIGenerated == true }
        guard !proposal.isEmpty else { return }
        edit(proposal.title) { track in proposal.apply(to: &track) }
    }

    /// The joins `CueJoiner` finds among the cues `eligible` accepts. Cues are
    /// only joined with neighbours that are eligible too.
    func joinProposal(eligible: (Cue) -> Bool) -> ProposedChangeSet {
        var joiner = CueJoiner(preset: qcPreset)
        joiner.sentencePerLine = TranslationStyle.endsLinesBare(track.languageCode) && aiSettings.translationStyle.dropsFinalPunctuation
        var runs: [[Cue]] = [[]]
        for cue in track.cues.sorted(by: { $0.start < $1.start }) {
            if eligible(cue) {
                runs[runs.count - 1].append(cue)
            } else if !runs[runs.count - 1].isEmpty {
                runs.append([])
            }
        }
        var original: [Cue] = []
        var joined: [Cue] = []
        for run in runs where run.count > 1 {
            original += run
            joined += joiner.join(run.map(joinLine(for:)))
        }
        return Proposals.join(original, into: joined)
    }

    /// A cue as the joiner sees it: who says it and, in a translation, its source text.
    func joinLine(for cue: Cue) -> CueJoiner.Line {
        let source = sourceCues[cue.id]
        let voices = source?.voices ?? cue.voices
        let speaker = cue.speaker ?? source?.speaker ?? (voices?.count == 1 ? voices?.first : nil)
        return CueJoiner.Line(cue: cue, speaker: speaker, source: isTranslating ? source?.text : nil)
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

    /// Empties every target cue (text, flagged choices, AI tint), keeping its timing
    /// and source link so a translation can fill it again. One undoable edit.
    func clearTranslation() {
        edit("Clear Translation") { track in
            for index in track.cues.indices {
                track.cues[index].text = ""
                track.cues[index].flag = nil
                track.cues[index].unsureWords = nil
                track.cues[index].isAIGenerated = nil
            }
        }
    }

    /// Removes the transcribed cues and the transcripts the project keeps. In translation
    /// mode the transcript is the source, so the translation made from it goes too and
    /// the editor leaves translation mode, back in the source's language. A subtitle
    /// file's cues stay, without what listening to the audio added to them. One undoable edit.
    func clearTranscript() {
        let language = sourceTrack?.languageCode
        let keepsSubtitles = !isTranslating && textIsFromSubtitles && !storedTranscripts.isEmpty
        editIncludingSources("Clear Transcript") { track, sources in
            track.cues = !keepsSubtitles ? [] : track.cues.filter { $0.isAIGenerated != true }.map { cue in
                var cue = cue
                cue.voices = nil
                if cue.scriptFinding?.tried == nil { cue.scriptFinding = nil }
                return cue
            }
            track.brief = nil
            if let language { track.languageCode = language }
            sources = SourceState(sourceTrack: nil, sourceFile: nil, transcripts: [])
        }
        subtitleSync = nil
        briefAwaitsSync = false
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

/// A step of a running AI tool, as its work reports it.
enum AITaskStep: Sendable {
    /// The provider's own report.
    case provider(AIProgress)
    /// A stage the editor does itself: preparing audio, building cues.
    case stage(String, detail: String?, fraction: Double?)
    /// How long the provider's wait usually takes for this audio, from earlier runs.
    case usualWait(TimeInterval)
}

/// How an AI tool ended, for a notification when Spotline is in the background.
public struct AITaskEnd: Sendable, Equatable {
    public var title: String
    public var message: String
    public var succeeded: Bool
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


extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// A word to select in a cue's text editor (`EditorState.selectUnsureWord`).
public struct WordSelectionRequest: Equatable, Sendable {
    public var cueID: Cue.ID
    public var word: String
    public var serial: Int
}

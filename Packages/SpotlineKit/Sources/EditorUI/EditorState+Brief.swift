import AITools
import Foundation
import SubtitleCore
import SubtitleTranslation

/// The episode brief: right after transcription, AI works out who each voice is,
/// their gender and spellings, and the show's places and terms (GPT-6 Luna, with a
/// web lookup of the show). It opens in a dialog to confirm as it is or edit first,
/// and the review waits for that: its cards show once the brief is confirmed. The
/// confirmed people go into the cast, which translation uses.
extension EditorState {
    /// The cues the brief is about: the source when translating, else the cues being edited.
    var briefSourceTrack: SubtitleTrack { sourceTrack ?? track }

    /// True while the review waits: for the brief (being built, or built and not
    /// confirmed), then for the AI script review.
    public var isReviewHeld: Bool {
        isBuildingBrief || track.brief.map { !$0.isConfirmed } == true || isReviewingScript
    }

    /// The confirmed brief, for the translator: its plot and scenes as notes, nil until confirmed.
    var confirmedBrief: EpisodeBrief? {
        track.brief?.isConfirmed == true ? track.brief : nil
    }

    /// Opens the brief, or builds one when there is none yet.
    func showEpisodeBrief() {
        if track.brief != nil {
            isBriefSheetShown = true
        } else {
            buildEpisodeBrief(automatically: false)
        }
    }

    /// The language the transcript is in.
    var briefSourceLanguage: String {
        let code = briefSourceTrack.languageCode
        if code != "und" { return code }
        return Self.detectLanguage(of: briefSourceTrack.cues) ?? transcriptionLanguage ?? "und"
    }

    /// What the brief builder gets: every line with its voices and unsure words, the
    /// episode's title from the file name, and the cast and glossary the project has.
    func briefRequest() -> BriefRequest {
        let source = briefSourceLanguage
        let target = isTranslating ? track.languageCode : defaultTargetLanguage(avoiding: source)
        let lines = briefSourceTrack.cues.compactMap { cue -> BriefRequest.Line? in
            let text = SubtitleText.visibleLines(of: cue.text).joined(separator: " ")
            guard !text.allSatisfy(\.isWhitespace) else { return nil }
            let voices = cue.speaker.map { [$0] } ?? voices(for: cue) ?? []
            return BriefRequest.Line(start: cue.start, voices: voices, text: text, unsureWords: cue.unsureWords?.map(\.text) ?? [])
        }
        let spellings = isTranslating ? glossary.entries.map { BriefRequest.Spelling(source: $0.source, target: $0.target) } : []
        var request = BriefRequest(lines: lines, sourceLanguage: source, targetLanguage: target, work: workTitle, cast: track.cast, spellings: spellings)
        request.isFromSubtitles = textIsFromSubtitles
        request.sceneDescriptions = pendingSceneNotes ?? ""
        return request
    }

    /// Builds the brief in the background, holding the review meanwhile, and opens it
    /// when it is ready. `automatically` (after transcription): only when there is
    /// none yet and a builder is set up, and quietly skipped otherwise.
    func buildEpisodeBrief(automatically: Bool) {
        if automatically, track.brief != nil || !aiSettings.buildsBrief { return }
        let builder: (any EpisodeBriefBuilder)?
        do { builder = try aiProviders.briefBuilder(aiSettings) } catch {
            if !automatically { reportError("The episode brief could not start.", error) }
            return
        }
        guard let builder else {
            if !automatically {
                reportError("The episode brief could not start.", AIError.provider(aiSettings.brief.model.setupHint))
            }
            return
        }
        let request = briefRequest()
        guard !request.lines.isEmpty else { return }
        isBuildingBrief = true
        aiSummary = nil
        aiTask = AITaskStatus(
            title: "Episode Brief", provider: builder.name, stages: ["Building the brief"],
            detail: request.work == nil ? "Reading the transcript" : "Reading the transcript and looking up the show"
        )
        aiTaskGeneration += 1
        let generation = aiTaskGeneration
        // The scenes are described right after the brief: their frames are read meanwhile, on this Mac.
        if aiSettings.sendsVideoFrames, canPickSceneFrames, sceneFrames == nil, sceneFramesJob == nil { pickSceneFrames() }
        aiTaskHandle = Task { [weak self] in
            do {
                var brief = try await builder.buildBrief(request)
                guard let self else { return }
                self.isBuildingBrief = false
                guard !Task.isCancelled, self.aiTaskGeneration == generation else { return }
                self.aiTask = nil
                // Scenes described first went into the brief's own scene list, and stay as written.
                if !request.sceneDescriptions.isEmpty {
                    brief.seen = request.sceneDescriptions
                    brief.scenesIncludeVideo = true
                    self.pendingSceneNotes = nil
                } else if let earlier = self.track.brief, brief.seen.isEmpty {
                    // What the video showed stays when the brief is built again; describing the scenes replaces it.
                    brief.seen = earlier.seen
                    brief.scenesIncludeVideo = earlier.scenesIncludeVideo
                }
                // A term the glossary has already is not added again; one it translates differently
                // shows the glossary's translation in the dialog, and ticking it replaces that.
                for index in brief.terms.indices where self.glossary.entry(for: brief.terms[index].term) != nil {
                    brief.terms[index].addsToGlossary = false
                }
                self.edit("Episode Brief") { track in track.brief = brief }
                if self.aiFlow != nil {
                    // The plan says what is next: the scenes, or the brief to confirm.
                    self.aiFlowFinished(.brief)
                } else if self.aiSettings.sendsVideoFrames, self.hasMedia, brief.seen.isEmpty {
                    // The brief opens once the scenes are described, or at once when they cannot be.
                    self.describeScenes(automatically: true)
                } else {
                    self.isBriefSheetShown = true
                }
                if self.isBriefSheetShown {
                    self.onAITaskEnd?(AITaskEnd(title: "Episode brief ready", message: "Check who is who, then confirm it to see the review.", succeeded: true))
                }
            } catch {
                guard let self else { return }
                self.isBuildingBrief = false
                if self.aiTaskGeneration == generation { self.aiTask = nil }
                self.endAIFlow()
                if !(error is CancellationError), !Task.isCancelled {
                    self.reportError("The episode brief stopped.", error)
                    self.onAITaskEnd?(AITaskEnd(title: "Episode brief stopped", message: error.localizedDescription, succeeded: false))
                }
                // Without a brief, the review shows as it did before.
                if !self.reviewItems(in: .all).isEmpty { self.wantsReviewSidebar = true }
            }
        }
    }

    /// Confirms the brief as edited in the dialog, as one undoable edit: its people go
    /// into the cast (genders settled), and the terms ticked go into the glossary of the
    /// language pair. Then the review shows.
    public func confirmEpisodeBrief(_ edited: EpisodeBrief) {
        // Confirming it the first time starts the script review; later edits rerun nothing.
        let startsReview = track.brief?.isConfirmed != true
        var brief = edited
        brief.terms.removeAll { $0.term.trimmingCharacters(in: .whitespaces).isEmpty }
        brief.mergeDuplicateTerms()
        edit("Confirm Episode Brief") { track in track.confirm(brief) }
        // A show's names and terms go into its own glossary.
        let entries = brief.terms.filter { $0.addsToGlossary && !$0.translation.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { Glossary.Entry(source: $0.term, target: $0.translation, note: $0.note, show: glossaryShow) }
        if !entries.isEmpty {
            let pair = TranslationStore.pairKey(source: briefSourceLanguage, target: brief.targetLanguage)
            if pair == translationPair {
                glossary.merge(entries)
            } else if let store = translationStore {
                var stored = store.glossary(pair: pair, show: glossaryShow)
                stored.merge(entries)
                try? store.save(stored, pair: pair, show: glossaryShow)
            }
        }
        isBriefSheetShown = false
        if aiFlow != nil {
            // The plan says what is next: the script review if ticked, then translating.
            advanceAIFlow()
        } else if startsReview, !textIsFromSubtitles, aiSettings.reviewsScript {
            // A subtitle file's words were not misheard: its review is the lines where the audio differs.
            reviewScript(automatically: true)
        }
        if !reviewItems(in: .all).isEmpty { wantsReviewSidebar = true }
    }

    /// Closes the dialog without confirming; the review keeps waiting for the brief.
    public func dismissEpisodeBrief() {
        isBriefSheetShown = false
    }

    /// The first line spoken in any of `voices`, for the dialog to show and play.
    public func firstLine(of voices: [String]) -> Cue? {
        guard !voices.isEmpty else { return nil }
        return briefSourceTrack.cues.first { cue in
            let heard = cue.speaker.map { [$0] } ?? self.voices(for: cue) ?? []
            return !Set(heard).isDisjoint(with: voices)
        }
    }

    /// Plays the first line of `voices`, then pauses, to hear who it is.
    public func playFirstLine(of voices: [String]) {
        guard hasMedia, let cue = firstLine(of: voices) else { return }
        playback.seek(toFrame: cue.start.firstFrame(at: frameRate), rate: frameRate)
        playbackStopTime = cue.end
        playback.play(rate: 1)
    }
}

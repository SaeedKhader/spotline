import AITools
import Foundation
import SubtitleCore

/// The AI script review: once the episode brief is confirmed, GPT-6 Luna reads the
/// whole transcript with it and flags the lines that look misheard, misspell a name
/// or make no sense in their scene, each with fixes and how sure it is. They show as
/// AI Review cards with the other checks, once it is done (the review waits for it).
/// Nothing changes until a fix is tried and confirmed.
extension EditorState {
    /// Reviews the transcript with the confirmed brief. `automatically` (after the
    /// brief's first Confirm): quietly skipped without a reviewer. Not in translation
    /// mode, where the transcript is the read-only source.
    func reviewScript(automatically: Bool) {
        guard !isTranslating, let brief = track.brief, brief.isConfirmed else {
            if !automatically {
                reportError("The script review could not start.", AIError.nothingToDo("It needs a transcript and a confirmed episode brief."))
            }
            return
        }
        let reviewer: (any ScriptReviewer)?
        do { reviewer = try aiProviders.scriptReviewer(aiSettings) } catch {
            if !automatically { reportError("The script review could not start.", error) }
            return
        }
        guard let reviewer else {
            if !automatically {
                reportError("The script review could not start.", AIError.provider("It needs GPT-6 Luna: allow cloud AI and add an OpenAI API key in Settings › AI."))
            }
            return
        }
        let lines = track.cues.compactMap { cue -> ScriptReviewRequest.Line? in
            guard !SubtitleText.visibleLines(of: cue.text).joined().allSatisfy(\.isWhitespace) else { return nil }
            return ScriptReviewRequest.Line(
                cueID: cue.id, start: cue.start, voices: cue.speaker.map { [$0] } ?? voices(for: cue) ?? [], text: cue.text,
                unsureWords: cue.unsureWords?.map(\.text) ?? []
            )
        }
        guard !lines.isEmpty else { return }
        let request = ScriptReviewRequest(lines: lines, language: briefSourceLanguage, brief: brief)
        isReviewingScript = true
        aiSummary = nil
        aiTask = AITaskStatus(
            title: "Script Review", provider: reviewer.name, stages: ["Reviewing the script"], detail: "0 of \(lines.count) lines"
        )
        aiTaskGeneration += 1
        let generation = aiTaskGeneration
        aiTaskHandle = Task { [weak self] in
            do {
                let findings = try await reviewer.review(request) { done, total in
                    Task { @MainActor in
                        guard let self, self.aiTaskGeneration == generation, total > 0 else { return }
                        self.aiTask?.detail = "\(done) of \(total) lines"
                        self.aiTask?.fraction = Double(done) / Double(total)
                    }
                }
                guard let self else { return }
                self.isReviewingScript = false
                guard !Task.isCancelled, self.aiTaskGeneration == generation else { return }
                self.aiTask = nil
                self.addScriptFindings(findings)
                let count = self.track.cues.count(where: { $0.scriptFinding != nil })
                self.onAITaskEnd?(AITaskEnd(
                    title: "Script review finished", message: count == 1 ? "1 line to check" : "\(count) lines to check", succeeded: true
                ))
                if !self.reviewItems(in: .all).isEmpty { self.wantsReviewSidebar = true }
            } catch {
                guard let self else { return }
                self.isReviewingScript = false
                if self.aiTaskGeneration == generation { self.aiTask = nil }
                if !(error is CancellationError), !Task.isCancelled {
                    self.reportError("The script review stopped.", error)
                    self.onAITaskEnd?(AITaskEnd(title: "Script review stopped", message: error.localizedDescription, succeeded: false))
                }
                // Without it, the review shows what it has.
                if !self.reviewItems(in: .all).isEmpty { self.wantsReviewSidebar = true }
            }
        }
    }

    /// Puts what the review found on its cues, as one undoable edit, replacing what an
    /// earlier review found. A line edited while it ran is left out.
    func addScriptFindings(_ findings: [Cue.ID: ScriptFinding]) {
        edit("AI Script Review") { track in
            for index in track.cues.indices {
                let cue = track.cues[index]
                if let finding = findings[cue.id], finding.original == cue.text {
                    track.cues[index].scriptFinding = finding
                } else if cue.scriptFinding?.tried == nil {
                    track.cues[index].scriptFinding = nil
                }
            }
        }
    }

    /// Puts a fix in the line to see it; the card stays until it is confirmed. One undoable edit.
    public func tryScriptFix(_ index: Int, forCue id: Cue.ID) {
        guard let cueIndex = track.cues.firstIndex(where: { $0.id == id }), let finding = track.cues[cueIndex].scriptFinding,
              finding.fixes.indices.contains(index), finding.tried != index
        else { return }
        edit("Try Fix") { track in
            track.cues[cueIndex].text = finding.fixes[index].text
            track.cues[cueIndex].scriptFinding?.tried = index
        }
    }

    /// Keeps the fix being tried: the card goes. One undoable edit.
    func confirmScriptFix(forCue id: Cue.ID) {
        guard let cueIndex = track.cues.firstIndex(where: { $0.id == id }), track.cues[cueIndex].scriptFinding != nil else { return }
        edit("Use Fix") { track in track.cues[cueIndex].scriptFinding = nil }
    }

    /// Keeps the line as it was reviewed (a fix being tried comes out again, unless the
    /// line was typed over since): the card goes. One undoable edit.
    func keepScriptLine(forCue id: Cue.ID) {
        guard let cueIndex = track.cues.firstIndex(where: { $0.id == id }), let finding = track.cues[cueIndex].scriptFinding else { return }
        edit("Keep Line") { track in
            if let tried = finding.tried, track.cues[cueIndex].text == finding.fixes[safe: tried]?.text {
                track.cues[cueIndex].text = finding.original
            }
            track.cues[cueIndex].scriptFinding = nil
        }
    }
}

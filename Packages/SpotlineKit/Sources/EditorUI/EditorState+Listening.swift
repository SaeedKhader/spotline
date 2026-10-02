import AITools
import Foundation
import QualityControl
import SubtitleCore

/// Listening to the audio of a video that has its subtitles already (an imported
/// file, an embedded track): the cues' words are right, so Transcribe Audio adds no
/// cues. The transcript's words are matched to the cues' (`TranscriptAligner`), which
/// tells who says each line, flags the lines where something else is said, and
/// whether the whole file runs early, late or at another speed than the audio.
extension EditorState {
    /// Whether the cues are a subtitle file's rather than a transcription: nearly all
    /// of those with text were not written by AI. The episode brief is told so, and the
    /// AI script review (which looks for misheard words) is not run by itself.
    var textIsFromSubtitles: Bool {
        let spoken = briefSourceTrack.cues.filter { !SubtitleText.visibleLines(of: $0.text).joined().allSatisfy(\.isWhitespace) }
        guard !spoken.isEmpty else { return false }
        return spoken.count(where: { $0.isAIGenerated != true }) * 5 >= spoken.count * 4
    }

    /// The cues with text that AI did not write: what a transcript is matched to.
    var cuesOfTheirOwn: [Cue] {
        track.cues.filter { $0.isAIGenerated != true && !SubtitleText.visibleLines(of: $0.text).joined().allSatisfy(\.isWhitespace) }
    }

    /// The transcript the project keeps that tells speakers apart, else the last one.
    var transcriptToMatch: [TranscribedWord]? {
        let stored = storedTranscripts.last(where: { $0.words.contains { $0.speaker != nil } }) ?? storedTranscripts.last
        return stored.flatMap { $0.words.isEmpty ? nil : $0.words }
    }

    /// Puts what the audio tells on the cues, as one undoable edit: each cue's voices,
    /// and an AI Review card on the lines where something else is said. Then asks about
    /// the timing when the file is off the audio; the episode brief (`thenBrief`) waits
    /// for that answer, as its scenes go by the cues' times.
    @discardableResult
    func addTranscript(_ alignment: TranscriptAlignment, thenBrief: Bool) -> AITaskSummary {
        let matches = Dictionary(alignment.cues.map { ($0.cueID, $0) }, uniquingKeysWith: { first, _ in first })
        var heard = 0, differing = 0
        edit("Match Subtitles to Audio") { track in
            for index in track.cues.indices {
                let cue = track.cues[index]
                guard let match = matches[cue.id] else { continue }
                if match.matched > 0 { heard += 1 }
                if let voices = TranscriptAligner.voices(of: match, text: cue.text) { track.cues[index].voices = voices }
                // Signs at the top are not said.
                guard cue.position == .bottom, cue.scriptFinding == nil, let instead = TranscriptAligner.heardInstead(of: match) else { continue }
                let text = QualityControl.rebalanced(instead.text, preset: qcPreset) ?? instead.text
                guard text != cue.text else { continue }
                track.cues[index].scriptFinding = ScriptFinding(
                    words: zip(match.words, match.heardAs).filter { $0.1 == nil }.map(\.0),
                    fixes: [ScriptFinding.Fix(text: text, confidence: instead.confidence)],
                    reason: "The audio says something else here.", original: cue.text
                )
                differing += 1
            }
        }
        if let sync = alignment.sync {
            subtitleSync = sync
            briefAwaitsSync = thenBrief
        } else if thenBrief {
            buildEpisodeBrief(automatically: true)
        }
        let total = alignment.cues.count
        return AITaskSummary(
            text: "Heard \(heard) of \(total == 1 ? "1 cue" : "\(total) cues") in the audio",
            followUp: differing == 0 ? nil : differing == 1 ? "1 line differs" : "\(differing) lines differ"
        )
    }

    /// After a subtitle file is imported into a project that has a transcript already:
    /// matched at once, when the file is this audio's.
    func matchImportedSubtitles() {
        guard !isTranslating, aiTask == nil, let words = transcriptToMatch else { return }
        let cues = cuesOfTheirOwn
        guard !cues.isEmpty else { return }
        let alignment = TranscriptAligner.align(cues, to: words)
        guard alignment.coversAudio else { return }
        show(addTranscript(alignment, thenBrief: false))
        if !reviewItems(in: .all).isEmpty { wantsReviewSidebar = true }
    }

    /// Who says a cue, for its row: its speaker, else each of its voices (the source
    /// cue's when translating) by the name the cast has for it, or "Voice 3" until
    /// the episode brief names it. Empty when nothing tells.
    public func speakerNames(of cue: Cue) -> [String] {
        let spoken = sourceCues[cue.id] ?? cue
        if let speaker = spoken.speaker, !speaker.isEmpty { return [speaker] }
        var names: [String] = []
        for voice in spoken.voices ?? [] {
            let name = track.cast.first { $0.voices.contains(voice) }?.name ?? Self.voiceName(voice)
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// "speaker_2" as people count: "Voice 3".
    static func voiceName(_ label: String) -> String {
        guard let number = label.split(separator: "_").last.flatMap({ Int($0) }) else { return label }
        return "Voice \(number + 1)"
    }

    // MARK: Sync

    /// AI › Sync Subtitles to Audio…: works the timing out again and asks, or says why not.
    func checkSubtitleSync() {
        guard let words = transcriptToMatch else { return }
        let alignment = TranscriptAligner.align(cuesOfTheirOwn, to: words)
        if let sync = alignment.sync {
            subtitleSync = sync
        } else if alignment.coversAudio {
            reportError("The subtitles are on the audio.", AIError.nothingToDo("No shift or change of speed would bring them closer to when the lines are said."))
        } else {
            reportError(
                "The subtitles can't be synced to the audio.",
                AIError.nothingToDo("Too few of their words were heard in it: they may be another video's, or in another language than the transcript.")
            )
        }
    }

    /// What the sync question says: "The subtitles are 1.2 s late."
    public var subtitleSyncSummary: String? {
        subtitleSync?.summary(over: (track.cues.last?.end ?? .zero).seconds)
    }

    /// Moves every cue onto the audio (the question's Sync button), as one undoable edit.
    func applySubtitleSync() {
        guard let sync = subtitleSync else { return }
        let rate = frameRate
        let oneFrame = MediaTime(frame: 1, rate: rate)
        edit("Sync Subtitles to Audio") { track in
            for index in track.cues.indices {
                let start = sync.corrected(track.cues[index].start, rate: rate)
                track.cues[index].start = start
                track.cues[index].end = max(sync.corrected(track.cues[index].end, rate: rate), start + oneFrame)
            }
        }
        subtitleSync = nil
        subtitleSyncDecided()
    }

    /// Leaves the timing as it is (the question's other button).
    public func dismissSubtitleSync() {
        guard subtitleSync != nil else { return }
        subtitleSync = nil
        subtitleSyncDecided()
    }

    private func subtitleSyncDecided() {
        guard briefAwaitsSync else { return }
        briefAwaitsSync = false
        buildEpisodeBrief(automatically: true)
    }
}

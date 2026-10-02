import AITools
import EditorCommands
import Foundation
import MediaAnalysis
import PlaybackCore
import SubtitleCore
import Testing
@testable import EditorUI

/// Transcribing a video whose subtitles are in the track already (an imported file).
@MainActor
struct ListeningStateTests {
    let tests = AIStateTests()
    let rate = FrameRate.fps25

    func time(_ seconds: Double) -> MediaTime { MediaTime(seconds: seconds, timescale: 1000) }

    /// Twenty lines, four seconds apart, said by two voices in turn.
    static let lines: [String] = (0..<20).map { index in
        let things = ["horse", "sword", "tent", "shield", "river", "tower", "squire", "knight", "lance", "helm"]
        return "We lost the \(things[index % 10]) number \(index) today."
    }

    /// The lines as a transcriber hears them: each word with its time and voice.
    var heard: [TranscribedWord] {
        Self.lines.enumerated().flatMap { index, line in
            line.split(separator: " ").enumerated().map { position, word in
                let at = 2 + Double(index) * 4 + Double(position) * 0.4
                return TranscribedWord(text: String(word), start: time(at), end: time(at + 0.3), speaker: "speaker_\(index % 2)", confidence: 0.9)
            }
        }
    }

    /// The lines as a subtitle file has them, `late` seconds after they are said.
    func subtitles(late: Double = 0) -> [Cue] {
        Self.lines.enumerated().map { index, line in
            let start = 2 + Double(index) * 4 + late
            return Cue(start: time(start), end: time(start + 3), text: line)
        }
    }

    /// An editor with a two-minute video, the cues, and a transcriber that hears `heard`.
    func makeEditor(cues: [Cue], briefBuilder: (any EpisodeBriefBuilder)? = nil) -> EditorState {
        let editor = EditorState(
            launchOptions: LaunchOptions(isUITestMode: true), playback: SimulatedPlaybackEngine(frameRate: rate, frameCount: 25 * 120),
            track: SubtitleTrack(cues: cues)
        )
        editor.open(URL(fileURLWithPath: "/tmp/clip.mov"))
        editor.prepareAudio = { _, _, progress in
            progress(1)
            return PreparedAudio(source: .mix, audioStreamIndex: 0, duration: MediaTime(value: 120, timescale: 1), chunks: [])
        }
        editor.reportError = { title, error in Issue.record("\(title) \(error)") }
        let words = heard
        editor.aiProviders = AIProviderFactory(
            transcriber: { _ in ScriptedTranscriber(words: words) }, translator: { _ in ScriptedTranslator() },
            briefBuilder: { _ in briefBuilder }, scriptReviewer: { _ in ScriptedScriptReviewer() }
        )
        editor.wantsReviewSidebar = false
        return editor
    }

    @Test func transcribingASubtitledVideoAddsNoCuesAndTellsWhoSpeaks() async {
        let editor = makeEditor(cues: subtitles())
        #expect(editor.perform(.transcribe))
        await tests.finish(editor)
        #expect(editor.track.cues.map(\.text) == Self.lines, "The file's words stay as they are")
        #expect(editor.track.cues.allSatisfy { $0.isAIGenerated == nil })
        #expect(editor.track.cues.prefix(3).map(\.voices) == [["speaker_0"], ["speaker_1"], ["speaker_0"]])
        #expect(editor.aiSummary?.fullText == "Heard 20 of 20 cues in the audio")
        #expect(editor.subtitleSync == nil)
        #expect(editor.storedTranscripts.count == 1)
        // One undo takes the voices off again.
        editor.perform(.undo)
        #expect(editor.track.cues.allSatisfy { $0.voices == nil })
    }

    @Test func aFewTypedCuesStillGetTheRestTranscribed() async {
        let editor = makeEditor(cues: Array(subtitles().prefix(2)))
        #expect(editor.perform(.transcribe))
        await tests.finish(editor)
        #expect(editor.track.cues.count == 20, "The gaps are filled, as before")
        #expect(editor.track.cues.prefix(2).allSatisfy { $0.isAIGenerated == nil })
        #expect(editor.track.cues.dropFirst(2).allSatisfy { $0.isAIGenerated == true })
    }

    @Test func lateSubtitlesAreAskedAboutAndTheBriefWaitsForTheAnswer() async throws {
        let editor = makeEditor(cues: subtitles(late: 1.5), briefBuilder: ScriptedBriefBuilder())
        #expect(!editor.canPerform(.syncSubtitlesToAudio), "Nothing was heard yet")
        #expect(editor.perform(.transcribe))
        await tests.finish(editor)
        let sync = try #require(editor.subtitleSync)
        // Back onto the audio, up a moment before the first word as subtitles are.
        #expect(abs(sync.offset + 1.65) < 0.05)
        #expect(editor.subtitleSyncSummary?.hasSuffix("s late.") == true)
        #expect(editor.track.cues[0].voices == ["speaker_0"], "Matched by their words, whatever their times")
        #expect(!editor.isBuildingBrief && editor.track.brief == nil)

        #expect(editor.perform(.applySubtitleSync))
        #expect(editor.subtitleSync == nil)
        #expect(abs(editor.track.cues[0].start.seconds - 1.85) < 0.03)
        #expect(abs(editor.track.cues[19].end.seconds - 80.85) < 0.03)
        #expect(editor.isBuildingBrief, "The brief is built from the cues where they belong")
        await tests.finish(editor)
        #expect(editor.track.brief != nil)
        #expect(editor.briefRequest().isFromSubtitles)
        // A subtitle file's words were not misheard: confirming the brief starts no AI script review.
        editor.confirmEpisodeBrief(editor.track.brief!)
        #expect(!editor.isReviewingScript)
        // In sync now.
        editor.reportError = { _, _ in }
        #expect(editor.perform(.syncSubtitlesToAudio))
        #expect(editor.subtitleSync == nil)
    }

    @Test func leavingTheTimingKeepsTheCuesAndCanBeAskedAgain() async {
        let late = subtitles(late: 1.5)
        let editor = makeEditor(cues: late)
        editor.perform(.transcribe)
        await tests.finish(editor)
        #expect(editor.subtitleSync != nil)
        editor.dismissSubtitleSync()
        #expect(editor.subtitleSync == nil)
        #expect(editor.track.cues.map(\.start) == late.map(\.start))
        // AI › Sync Subtitles to Audio… asks again; syncing is one undo step.
        #expect(editor.perform(.syncSubtitlesToAudio))
        #expect(editor.subtitleSync != nil)
        #expect(editor.perform(.applySubtitleSync))
        #expect(abs(editor.track.cues[0].start.seconds - 1.85) < 0.03)
        editor.perform(.undo)
        #expect(editor.track.cues.map(\.start) == late.map(\.start))
    }

    @Test func aLineWhereSomethingElseIsSaidGetsAReviewCard() async throws {
        var cues = subtitles()
        cues[5].text = "Nobody ever told me about that."
        let editor = makeEditor(cues: cues)
        editor.perform(.transcribe)
        await tests.finish(editor)
        #expect(editor.aiSummary?.followUp == "1 line differs")
        let item = try #require(editor.reviewItems(in: .script).first)
        #expect(item.cueID == cues[5].id)
        let finding = try #require(editor.cue(withID: item.cueID)?.scriptFinding)
        #expect(finding.reason == "The audio says something else here.")
        #expect(finding.fixes.map(\.text) == ["We lost the tower number 5 today."])
        #expect(editor.isReviewSidebarVisible)
        // Trying the fix puts what was heard in; keeping the line takes it out again.
        editor.decide(item, .primary)
        #expect(editor.cue(withID: item.cueID)?.text == "We lost the tower number 5 today.")
        editor.decide(item, .reject)
        #expect(editor.cue(withID: item.cueID)?.text == "Nobody ever told me about that.")
        #expect(editor.reviewItems(in: .script).isEmpty)
    }

    @Test func subtitlesImportedAfterTranscribingAreMatchedAtOnce() async throws {
        let editor = makeEditor(cues: [])
        editor.perform(.transcribe)
        await tests.finish(editor)
        #expect(editor.track.cues.allSatisfy { $0.isAIGenerated == true })
        let file = FileManager.default.temporaryDirectory.appending(path: "listening-\(UUID().uuidString).srt")
        defer { try? FileManager.default.removeItem(at: file) }
        let srt = Self.lines.enumerated().map { index, line in
            let start = 2 + index * 4
            return "\(index + 1)\n00:\(String(format: "%02d:%02d", start / 60, start % 60)),000 --> 00:\(String(format: "%02d:%02d", (start + 3) / 60, (start + 3) % 60)),000\n\(line)\n"
        }.joined(separator: "\n")
        try srt.write(to: file, atomically: true, encoding: .utf8)
        editor.importSubtitles(from: file)
        #expect(editor.track.cues.map(\.text) == Self.lines)
        #expect(editor.track.cues.prefix(2).map(\.voices) == [["speaker_0"], ["speaker_1"]])
        #expect(editor.aiSummary?.fullText == "Heard 20 of 20 cues in the audio")
        #expect(editor.textIsFromSubtitles)
    }

    @Test func clearingTheTranscriptKeepsTheSubtitleFilesCues() async {
        let editor = makeEditor(cues: subtitles())
        editor.perform(.transcribe)
        await tests.finish(editor)
        editor.confirmClearingTranscript = { _ in true }
        #expect(editor.perform(.clearTranscript))
        #expect(editor.track.cues.map(\.text) == Self.lines)
        #expect(editor.track.cues.allSatisfy { $0.voices == nil })
        #expect(editor.storedTranscripts.isEmpty)
        editor.perform(.undo)
        #expect(editor.track.cues[0].voices == ["speaker_0"])
        #expect(editor.storedTranscripts.count == 1)
    }

    @Test func agentsLeaveTheSyncQuestionToThePerson() async {
        let editor = makeEditor(cues: subtitles(late: 1.5))
        editor.perform(.transcribe)
        await tests.finish(editor)
        await #expect(throws: (any Error).self) {
            _ = try await editor.runAgentTool(.runCommand, arguments: ["id": .string(EditorCommand.applySubtitleSync.id)])
        }
        #expect(editor.subtitleSync != nil)
    }
}

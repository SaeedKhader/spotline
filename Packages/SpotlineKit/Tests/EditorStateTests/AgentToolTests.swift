import AgentBridge
import AITools
import EditorCommands
import Foundation
import MediaAnalysis
import PlaybackCore
import SubtitleCore
import Testing
@testable import EditorUI

/// The agent bridge's tools, run against the editor: each edit is one undo step,
/// and AI tools follow the same review rule as from the menus.
@MainActor
struct AgentToolTests {
    let rate = FrameRate.fps25
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "AgentToolTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func makeEditor(_ texts: [String] = ["One", "Two", "Three"]) -> EditorState {
        let cues = texts.enumerated().map { index, text in
            let second = Int64(index * 2 + 1)
            return Cue(start: MediaTime(value: second, timescale: 1), end: MediaTime(value: second + 1, timescale: 1), text: text)
        }
        let editor = EditorState(
            launchOptions: LaunchOptions(isUITestMode: true), playback: SimulatedPlaybackEngine(frameRate: rate, frameCount: 250),
            track: SubtitleTrack(cues: cues)
        )
        editor.open(URL(fileURLWithPath: "/tmp/clip.mov"))
        editor.prepareAudio = { _, _, progress in
            progress(1)
            return PreparedAudio(source: .mix, audioStreamIndex: 0, duration: MediaTime(value: 10, timescale: 1), chunks: [])
        }
        editor.reportError = { title, error in Issue.record("\(title) \(error)") }
        return editor
    }

    @discardableResult
    func run(_ editor: EditorState, _ tool: AgentTool, _ arguments: [String: JSONValue] = [:]) async throws -> JSONValue {
        try await editor.runAgentTool(tool, arguments: arguments)
    }

    func failure(_ editor: EditorState, _ tool: AgentTool, _ arguments: [String: JSONValue] = [:]) async -> String? {
        do {
            try await run(editor, tool, arguments)
            return nil
        } catch {
            return (error as? AgentToolError)?.message
        }
    }

    @Test func readsCuesAndTheProject() async throws {
        let editor = makeEditor()
        let page = try await run(editor, .getCues, ["from": 2, "count": 5])
        #expect(page["total"] == 3)
        let cues = try #require(page["cues"]?.arrayValue)
        #expect(cues.map { $0["number"] } == [2, 3])
        #expect(cues[0]["text"] == "Two")
        #expect(cues[0]["start"]?["timecode"] == "00:00:03:00")
        #expect(cues[0]["end"]?["time"] == "00:00:04,000")

        let project = try await run(editor, .getProject)
        #expect(project["media"]?["path"] == "/tmp/clip.mov")
        #expect(project["subtitles"]?["cue_count"] == 3)
        #expect(project["playhead"]?["frame"] == 0)
        #expect(project["qc"]?["preset"]?.stringValue == editor.qcPreset.id)
    }

    @Test func textEditsAreOneUndoStepEachAndTintedAsAI() async throws {
        let editor = makeEditor()
        try await run(editor, .setCueText, ["cue": 2, "text": "Deux"])
        try await run(editor, .setCueText, ["cue": 2, "text": "Zwei"])
        #expect(editor.track.cues[1].text == "Zwei")
        #expect(editor.track.cues[1].isAIGenerated == true)
        #expect(editor.aiToolName(for: editor.track.cues[1]) == "an agent")
        // Not joined together like typing: each undoes on its own.
        editor.perform(.undo)
        #expect(editor.track.cues[1].text == "Deux")
        // The agent's undo is the same command.
        try await run(editor, .runCommand, ["id": "editing.undo"])
        #expect(editor.track.cues[1].text == "Two")
        #expect(editor.track.cues[1].isAIGenerated == nil)
    }

    @Test func cuesAreFoundByNumberOrID() async throws {
        let editor = makeEditor()
        let id = editor.track.cues[2].id
        let selected = try await run(editor, .selectCue, ["cue": .string(id.uuidString)])
        #expect(selected["cue"]?["number"] == 3)
        #expect(editor.selectedCueID == id)
        try await run(editor, .selectCue, ["cue": "1"])
        #expect(editor.selectedCueID == editor.track.cues[0].id)
        #expect(await failure(editor, .selectCue, ["cue": 4]) == "There is no cue 4; there are 3.")
        #expect(await failure(editor, .selectCue, [:]) == "cue is required.")
    }

    @Test func timingAddingSplittingMergingAndDeleting() async throws {
        let editor = makeEditor()
        try await run(editor, .setCueTiming, ["cue": 1, "end": "00:00:02:10"])
        #expect(editor.track.cues[0].end == MediaTime(frame: 60, rate: rate))
        #expect(await failure(editor, .setCueTiming, ["cue": 1, "start": "soon"]) != nil)

        #expect(await failure(editor, .addCue, ["start": "00:00:03,500", "end": "00:00:04,500"])?.hasPrefix("It would overlap cue 2") == true)
        let added = try await run(editor, .addCue, ["start": "00:00:07:00", "end": "00:00:08:00", "text": "Four"])
        #expect(added["cue"]?["number"] == 4)
        #expect(editor.selectedCue?.text == "Four")
        // A top cue may sit over dialogue.
        try await run(editor, .addCue, ["start": "00:00:03:00", "end": "00:00:04:00", "text": "SIGN", "position": "top"])
        #expect(editor.track.cues.count == 5)

        let split = try await run(editor, .splitCue, ["cue": 1, "at": "00:00:01,500"])
        #expect(split["second"]?["start"]?["time"] == "00:00:01,500")
        #expect(editor.track.cues.count == 6)
        try await run(editor, .mergeCues, ["cue": 1])
        #expect(editor.track.cues.count == 5)
        #expect(editor.track.cues[0].end == MediaTime(frame: 60, rate: rate))
        try await run(editor, .deleteCue, ["cue": 1])
        #expect(editor.track.cues.first?.text == "Two")
        try await run(editor, .setCuePosition, ["cue": 1, "position": "top"])
        #expect(editor.track.cues[0].position == .top)

        // Every change is an undo step.
        for _ in 0..<7 { editor.perform(.undo) }
        #expect(editor.track.cues.map(\.text) == ["One", "Two", "Three"])
        #expect(editor.track.cues[0].end == MediaTime(value: 2, timescale: 1))
    }

    @Test func seekingMovesThePlayhead() async throws {
        let editor = makeEditor()
        let playhead = try await run(editor, .seek, ["cue": 2])
        #expect(playhead["timecode"] == "00:00:03:00")
        #expect(editor.currentFrame == 75)
        try await run(editor, .seek, ["time": "00:00:01:05"])
        #expect(editor.currentFrame == 30)
        try await run(editor, .play)
        #expect(editor.isPlaying)
        try await run(editor, .pause)
        #expect(!editor.isPlaying)
    }

    @Test func commandsRunByIDExceptDialogsAndReviewDecisions() async throws {
        let editor = makeEditor()
        let commands = try #require(try await run(editor, .listCommands).arrayValue)
        #expect(commands.contains { $0["id"] == "cue.split" })
        #expect(!commands.contains { $0["id"] == "ai.acceptAll" })
        #expect(!commands.contains { $0["id"] == "file.openMedia" })

        let result = try await run(editor, .runCommand, ["id": "navigation.nextCue"])
        #expect(result["selected_cue"]?["number"] == 1)
        #expect(await failure(editor, .runCommand, ["id": "file.exportSubtitles"])?.contains("export_subtitles") == true)
        #expect(await failure(editor, .runCommand, ["id": "ai.acceptAll"]) == "Accepting and rejecting AI proposals is left to the person, in Spotline.")
        #expect(await failure(editor, .runCommand, ["id": "editing.redo"]) == "“Redo” can't run now.")
        #expect(await failure(editor, .runCommand, ["id": "nope"]) != nil)
    }

    @Test func agentsClearTheTranscriptWithoutADialog() async throws {
        let editor = makeEditor()
        editor.confirmClearingTranscript = { _ in
            Issue.record("Agents never see dialogs")
            return false
        }
        try await run(editor, .runCommand, ["id": "ai.clearTranscript"])
        #expect(editor.track.cues.isEmpty)
        #expect(await failure(editor, .runCommand, ["id": "ai.clearTranslation"]) == "“Clear Translation” can't run now.")
        try await run(editor, .runCommand, ["id": "editing.undo"])
        #expect(editor.track.cues.map(\.text) == ["One", "Two", "Three"])
    }

    @Test func qcRunsWithAPreset() async throws {
        let editor = makeEditor(["One", "", "Three"])
        let report = try await run(editor, .runQC, ["preset": "netflix"])
        #expect(editor.qcPreset.id == "netflix")
        let issues = try #require(report["issues"]?.arrayValue)
        #expect(issues.contains { $0["cue"] == 2 && $0["severity"] == "error" })
        #expect(await failure(editor, .runQC, ["preset": "nope"])?.hasPrefix("No preset") == true)
    }

    @Test func importAndExportTakePathsAndReportErrorsToTheAgent() async throws {
        let editor = makeEditor()
        let file = directory.appending(path: "in.srt")
        try "1\n00:00:01,000 --> 00:00:02,000\nImported\n".write(to: file, atomically: true, encoding: .utf8)
        let project = try await run(editor, .importSubtitles, ["path": .string(file.path)])
        #expect(project["subtitles"]?["cue_count"] == 1)
        #expect(editor.track.cues.map(\.text) == ["Imported"])

        let out = directory.appending(path: "out.vtt")
        try await run(editor, .exportSubtitles, ["path": .string(out.path)])
        #expect(try String(contentsOf: out, encoding: .utf8).hasPrefix("WEBVTT"))
        #expect(!editor.hasUnsavedChanges)

        #expect(await failure(editor, .exportSubtitles, ["path": .string(directory.appending(path: "out.doc").path)])?.contains(".srt") == true)
        let broken = directory.appending(path: "broken.srt")
        try "not subtitles at all".write(to: broken, atomically: true, encoding: .utf8)
        // The error goes to the agent (no alert, which would record an issue here).
        #expect(await failure(editor, .importSubtitles, ["path": .string(broken.path)])?.contains("could not be imported") == true)
        #expect(await failure(editor, .importSubtitles, ["path": "relative.srt"]) == "path must be an absolute file path.")
    }

    @Test func openingMediaKeepsUnsavedSubtitlesUnlessTold() async throws {
        let editor = makeEditor()
        try await run(editor, .setCueText, ["cue": 1, "text": "Changed"])
        let media = directory.appending(path: "other.mov")
        FileManager.default.createFile(atPath: media.path, contents: Data())
        #expect(await failure(editor, .openMedia, ["path": .string(media.path)])?.contains("discard_unsaved_changes") == true)
        let project = try await run(editor, .openMedia, ["path": .string(media.path), "discard_unsaved_changes": true])
        #expect(project["media"]?["path"]?.stringValue == media.path)
        #expect(editor.track.cues.isEmpty)
    }

    @Test func transcriptionFillsCuesDirectly() async throws {
        let editor = makeEditor([])
        let started = try await run(editor, .startAITool, ["tool": "transcribe"])
        #expect(started["running"] == "Transcription")
        #expect(await failure(editor, .startAITool, ["tool": "transcribe"])?.hasPrefix("Transcription is running") == true)
        for _ in 0..<200 where editor.aiTask != nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(editor.pendingReview == nil)
        #expect(editor.track.cues.map(\.text) == ["Hello there. How are you?", "Fine, thanks."])
        let status = try await run(editor, .getAIStatus)
        #expect(status["running"] == .null)
    }

    @Test func translationTakesATargetLanguage() async throws {
        let editor = makeEditor(["Where are you going?", "Home."])
        try await run(editor, .startAITool, ["tool": "translate", "target_language": "fr"])
        #expect(editor.isTranslating)
        #expect(editor.track.languageCode == "fr")
        for _ in 0..<200 where editor.aiTask != nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(editor.track.cues.allSatisfy { $0.text.hasPrefix("[fr] ") && $0.isAIGenerated == true })
        #expect(editor.pendingReview == nil, "Translation is not reviewed")
    }

    @Test func cleanupIsProposedForThePersonToReview() async throws {
        let editor = makeEditor(["(sighs) Fine.", "OK"])
        let started = try await run(editor, .startAITool, ["tool": "remove_hearing_impaired"])
        #expect(started["proposed_changes"] == 1)
        #expect(editor.track.cues[0].text == "(sighs) Fine.", "Nothing changes until the person accepts")
        let status = try await run(editor, .getAIStatus)
        let change = try #require(status["review"]?["changes"]?.arrayValue?.first)
        #expect(change["cue"] == 1)
        #expect(change["text"] == "Fine.")
        #expect(change["text_before"] == "(sighs) Fine.")
        #expect(await failure(editor, .startAITool, ["tool": "fix_punctuation"])?.contains("waiting for the person") == true)
        // The cue list shows it too.
        let cues = try await run(editor, .getCues)
        #expect(cues["cues"]?.arrayValue?.first?["proposed_change"]?["kind"] == "update")
    }

    @Test func aiToolsExplainWhyTheyCannotStart() async throws {
        let editor = EditorState(launchOptions: LaunchOptions(isUITestMode: true), playback: SimulatedPlaybackEngine(frameRate: rate))
        #expect(await failure(editor, .startAITool, ["tool": "transcribe"]) == "No media is open.")
        #expect(await failure(editor, .startAITool, ["tool": "translate"]) == "There are no cues with text to translate.")
        #expect(await failure(editor, .startAITool, ["tool": "summarize"])?.hasPrefix("tool must be one of") == true)
    }
}

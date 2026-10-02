import AITools
import EditorCommands
import Foundation
import SubtitleCore
import Testing
@testable import EditorUI

@MainActor
struct ScriptReviewStateTests {
    let tests = AIStateTests()

    /// Transcribed, with the scripted brief built and the scripted script reviewer ready.
    func transcribed() async -> EditorState {
        let editor = tests.makeEditor()
        editor.aiProviders = AIProviderFactory(
            transcriber: { _ in ScriptedTranscriber.fixture }, translator: { _ in ScriptedTranslator() },
            briefBuilder: { _ in ScriptedBriefBuilder() }, scriptReviewer: { _ in ScriptedScriptReviewer() }
        )
        editor.wantsReviewSidebar = false
        editor.perform(.transcribe)
        await tests.finish(editor)
        return editor
    }

    var hello: String { "Hello there. How are you?" }

    @Test func confirmingTheBriefReviewsTheScriptAndTheReviewWaitsForIt() async throws {
        let editor = await transcribed()
        editor.confirmEpisodeBrief(editor.track.brief!)
        #expect(editor.isReviewingScript)
        #expect(editor.isReviewHeld)
        #expect(editor.aiTask?.title == "Script Review")
        #expect(editor.reviewItems(in: .all).isEmpty)
        await tests.finish(editor)
        #expect(!editor.isReviewingScript)
        #expect(!editor.isReviewHeld)
        let cue = try #require(editor.track.cues.first { $0.text == hello })
        #expect(cue.scriptFinding?.fixes.map(\.confidence) == [0.72, 0.4])
        #expect(editor.reviewItems(in: .script).map(\.cueID) == [cue.id])
        #expect(editor.isReviewSidebarVisible)
        // Editing the brief later reruns nothing.
        editor.confirmEpisodeBrief(editor.track.brief!)
        #expect(!editor.isReviewingScript)
    }

    @Test func aFixIsTriedThenConfirmedInUndoableSteps() async throws {
        let editor = await transcribed()
        editor.confirmEpisodeBrief(editor.track.brief!)
        await tests.finish(editor)
        let item = try #require(editor.reviewItems(in: .script).first)
        // Return with nothing tried puts the most likely fix in; the card stays.
        editor.decide(item, .primary)
        #expect(editor.cue(withID: item.cueID)?.text == "Hello Rick. How are you?")
        #expect(editor.cue(withID: item.cueID)?.scriptFinding?.tried == 0)
        editor.decide(item, .variant(1))
        #expect(editor.cue(withID: item.cueID)?.text == "Hello Morty. How are you?")
        editor.decide(item, .primary)
        #expect(editor.cue(withID: item.cueID)?.scriptFinding == nil)
        #expect(editor.cue(withID: item.cueID)?.text == "Hello Morty. How are you?")
        #expect(editor.reviewItems(in: .script).isEmpty)
        editor.perform(.undo)
        #expect(editor.cue(withID: item.cueID)?.scriptFinding?.tried == 1)
    }

    @Test func keepingTheLinePutsItBackAsItWas() async throws {
        let editor = await transcribed()
        editor.confirmEpisodeBrief(editor.track.brief!)
        await tests.finish(editor)
        let item = try #require(editor.reviewItems(in: .script).first)
        editor.decide(item, .variant(0))
        editor.decide(item, .reject)
        #expect(editor.cue(withID: item.cueID)?.text == hello)
        #expect(editor.cue(withID: item.cueID)?.scriptFinding == nil)
    }

    @Test func theCommandReviewsAgainAndLinesEditedMeanwhileAreLeftOut() async throws {
        let editor = await transcribed()
        editor.confirmEpisodeBrief(editor.track.brief!)
        await tests.finish(editor)
        let item = try #require(editor.reviewItems(in: .script).first)
        editor.decide(item, .reject)
        #expect(editor.canPerform(.reviewScriptWithAI))
        #expect(editor.perform(.reviewScriptWithAI))
        // Typed over while the review runs: what it found no longer fits.
        editor.setText("Hello there, Rick. How are you?", forCue: item.cueID)
        await tests.finish(editor)
        #expect(editor.reviewItems(in: .script).isEmpty)
        editor.setText(hello, forCue: item.cueID)
        editor.perform(.reviewScriptWithAI)
        await tests.finish(editor)
        #expect(editor.reviewItems(in: .script).count == 1)
    }

    @Test func notInTranslationModeOrWithoutAConfirmedBrief() async {
        let editor = await transcribed()
        #expect(!editor.canPerform(.reviewScriptWithAI), "The brief is not confirmed yet")
        editor.useCuesAsSource()
        editor.confirmEpisodeBrief(editor.track.brief!)
        #expect(!editor.isReviewingScript)
        #expect(!editor.canPerform(.reviewScriptWithAI))
    }
}

import AITools
import EditorCommands
import Foundation
import MediaAnalysis
import PlaybackCore
import SubtitleCore
import Testing
@testable import EditorUI

/// A brief builder that fails, as a provider can.
private struct DownBriefBuilder: EpisodeBriefBuilder {
    var name: String { "Down" }
    func buildBrief(_ request: BriefRequest) async throws -> EpisodeBrief { throw AIError.provider("Down") }
}

/// Translate with AI: the plan and the run of its steps.
@MainActor
struct AIFlowStateTests {
    let tests = AIStateTests()

    /// An editor with media and scripted providers for every step.
    func makeEditor(cues: [Cue] = []) -> EditorState {
        let editor = tests.makeEditor(cues: cues)
        editor.aiProviders = .scripted(buildsBrief: true)
        editor.grabFrames = { _, times, _ in SceneFramesStateTests.grabbed(times) }
        editor.aiSettings.allowsCloud = true
        editor.wantsReviewSidebar = false
        // Never a dialog in tests: a project's video that is not there is simply not found.
        editor.locateMissingMedia = { _ in nil }
        return editor
    }

    /// Waits until the flow stops for the user or ends.
    func settle(_ editor: EditorState) async {
        for _ in 0..<600 where editor.aiTask != nil || (editor.aiFlow != nil && editor.aiFlow?.stop == nil) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: The plan

    @Test func aNewVideoGetsEveryStepButTheScenes() {
        let editor = makeEditor()
        editor.aiSettings.joinsLinesAfterTranslating = true
        #expect(editor.canPerform(.planAIFlow))
        #expect(editor.page == .edit)
        #expect(editor.perform(.planAIFlow))
        #expect(editor.page == .translate, "Translate with AI shows the Translate page")
        #expect(editor.defaultAIPlanTicks == [.listen, .brief, .scriptReview, .translate, .join], "Frames are only sent when allowed")
        editor.aiSettings.sendsVideoFrames = true
        #expect(editor.defaultAIPlanTicks.contains(.scenes))
        let rows = editor.aiPlanRows(ticked: editor.defaultAIPlanTicks)
        #expect(rows.map(\.step) == AIFlowStep.allCases)
        #expect(rows.allSatisfy { $0.isAvailable && !$0.isDone })
        #expect(rows[0].title == "Transcribe the audio")
    }

    @Test func aSubtitleFileIsMatchedToTheAudioAndNeedsNoScriptReview() {
        let editor = makeEditor(cues: [tests.cue("Hello there. How are you?", at: 0), tests.cue("Fine, thanks.", at: 3)])
        editor.aiSettings.joinsLinesAfterTranslating = true
        #expect(editor.aiPlanRows(ticked: []).first?.title == "Match the subtitles to the audio")
        #expect(editor.defaultAIPlanTicks == [.listen, .brief, .translate, .join])
        // It can still be ticked.
        #expect(editor.aiPlanRows(ticked: [.brief]).first { $0.step == .scriptReview }?.isAvailable == true)
    }

    @Test func untickingAStepUnticksWhatNeedsIt() {
        let editor = makeEditor()
        #expect(editor.availableAIPlanTicks([.listen, .scenes, .scriptReview, .translate, .join]) == [.listen, .scenes, .translate, .join], "No brief: no review; the scenes come before it")
        #expect(editor.availableAIPlanTicks([.listen, .brief, .join]) == [.listen, .brief], "Joining goes with translating")
        #expect(editor.availableAIPlanTicks([.brief, .translate]).isEmpty, "Nothing to work on without listening")
        let rows = editor.aiPlanRows(ticked: [.listen])
        #expect(rows.first { $0.step == .scenes }?.isAvailable == true)
        #expect(rows.first { $0.step == .scriptReview }?.detail == "Needs the episode brief")
        #expect(rows.map(\.step) == [.listen, .scenes, .brief, .scriptReview, .translate, .join])
    }

    @Test func costsAreRoughAndFollowTheModel() {
        #expect(EditorState.cost(0) == "free")
        #expect(EditorState.cost(0.04) == "~4¢")
        #expect(EditorState.cost(0.001) == "~1¢")
        #expect(EditorState.cost(3.4) == "~$3.40")
        let editor = makeEditor(cues: (0..<700).map { tests.cue("Line \($0)", at: Int64($0) * 2) })
        editor.aiSettings.translation = .claude
        func cost(_ step: AIFlowStep) -> String? { editor.aiPlanRows(ticked: [.brief, .translate]).first { $0.step == step }?.cost }
        #expect(cost(.translate) == "~$3.43")
        #expect(cost(.brief) == "~4¢")
        editor.aiSettings.brief.model = .sol
        #expect(cost(.brief) == "~80¢")
        editor.aiSettings.translation = .appleTranslation
        #expect(cost(.translate) == "free")
    }

    @Test func stepSettingsAreSaved() throws {
        let suite = "AIFlowStateTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AISettings.load(from: defaults).scenes == AISettings.Step(model: .luna, effort: .high))
        var settings = AISettings()
        settings.brief = AISettings.Step(model: .sol, effort: .low)
        settings.buildsBrief = false
        settings.reviewsScript = false
        settings.save(to: defaults)
        let loaded = AISettings.load(from: defaults)
        #expect(loaded.brief == AISettings.Step(model: .sol, effort: .low))
        #expect(!loaded.buildsBrief && !loaded.reviewsScript)
        #expect(loaded.scriptReview == AISettings.Step())
    }

    // MARK: The run

    @Test func runsEveryStepStoppingForTheBriefAndTheLinesToCheck() async throws {
        let editor = makeEditor()
        #expect(editor.currentStage == .source)
        #expect(editor.stageState(.source) == .toDo)
        editor.startAIFlow(editor.planTicks)
        #expect(editor.aiFlow?.current == .listen)
        #expect(editor.stageState(.source) == .running)
        await settle(editor)

        // Transcribed, the brief built, and it waits for the brief.
        #expect(editor.track.cues.map(\.text) == ["Hello there. How are you?", "Fine, thanks."])
        #expect(editor.aiFlow?.finished == [.listen, .brief])
        #expect(editor.aiFlow?.stop == .confirmBrief)
        #expect(editor.isBriefSheetShown)
        #expect(editor.aiFlowStopText == "Confirm the episode brief to go on")
        #expect(editor.stageState(.source) == .done)
        #expect(editor.stageState(.brief) == .waiting)
        #expect(editor.currentStage == .brief)
        #expect(editor.stageSummary(.brief) == "Waiting for you to confirm")
        // Not Now leaves it waiting; its button shows the brief again.
        editor.dismissEpisodeBrief()
        #expect(editor.aiFlow?.stop == .confirmBrief)
        #expect(editor.aiFlowContinueTitle == "Open Brief")
        #expect(editor.perform(.continueAIFlow))
        #expect(editor.isBriefSheetShown)

        editor.confirmEpisodeBrief(try #require(editor.track.brief))
        #expect(editor.aiFlow?.current == .scriptReview)
        await settle(editor)
        // The review flagged a line: it waits before translating it.
        #expect(editor.aiFlow?.stop == .checkLines(1))
        #expect(editor.aiFlowStopText == "1 line to check before translating")
        #expect(editor.stageState(.brief) == .done)
        #expect(editor.stageState(.check) == .waiting)
        #expect(editor.stageSummary(.check) == "1 line to check")
        #expect(editor.wantsReviewSidebar)
        #expect(!editor.isTranslating)

        #expect(editor.perform(.continueAIFlow))
        #expect(editor.aiFlow?.current == .translate)
        await settle(editor)
        #expect(editor.aiFlow == nil, "Done")
        #expect(editor.isTranslating)
        #expect(editor.untranslatedCues.isEmpty)
        #expect(editor.track.cues.allSatisfy { $0.text.hasPrefix("[ar]") })

        // "How are you?" reads two ways in Arabic: one choice is left to confirm.
        #expect(editor.cuesToChoose.count == 1)
        #expect(TranslateStage.allCases.map { editor.stageState($0) } == [.done, .done, .done, .done, .toDo])
        #expect(editor.currentStage == .choices)
        #expect(editor.stageSummary(.choices) == "1 to confirm")
        // Opening the plan again: everything is done, and nothing is ticked.
        let rows = editor.aiPlanRows(ticked: [])
        #expect(rows.filter(\.isDone).map(\.step) == [.listen, .brief, .translate])
        #expect(editor.defaultAIPlanTicks.isEmpty)
    }

    @Test func describesTheScenesBeforeTheBriefIsConfirmedWhenTicked() async {
        let editor = makeEditor()
        var ticked = editor.defaultAIPlanTicks
        ticked.insert(.scenes)
        ticked.remove(.scriptReview)
        editor.startAIFlow(ticked)
        #expect(editor.aiSettings.sendsVideoFrames, "Ticking the step allows frames")
        await settle(editor)
        #expect(editor.aiFlow?.finished == [.listen, .scenes, .brief])
        #expect(editor.aiFlow?.stop == .confirmBrief)
        // Described before the brief, so without names; the brief read them into its own scene list.
        #expect(editor.track.brief?.seen.contains("In view: a man in a lab coat") == true)
        #expect(editor.track.brief?.scenesIncludeVideo == true)
        #expect(editor.pendingSceneNotes == nil)
        #expect(editor.isBriefSheetShown)

        editor.confirmEpisodeBrief(editor.track.brief!)
        await settle(editor)
        #expect(editor.aiFlow == nil)
        #expect(editor.isTranslating && editor.untranslatedCues.isEmpty, "No review ticked, nothing to check: straight to translating")
    }

    @Test func onlyTheTickedStepsRunAndTheTicksAreRemembered() async {
        let editor = makeEditor()
        editor.startAIFlow([.listen])
        await settle(editor)
        #expect(editor.aiFlow == nil)
        #expect(editor.track.cues.count == 2)
        #expect(editor.track.brief == nil, "The brief was not ticked")
        #expect(!editor.aiSettings.buildsBrief)
        #expect(!editor.isBriefSheetShown)

        // Later, only the brief: it is shown when the run ends, to be confirmed.
        let again = makeEditor(cues: [tests.cue("Hello there.", at: 0)])
        again.startAIFlow([.brief])
        await settle(again)
        #expect(again.aiFlow == nil)
        #expect(again.track.brief != nil)
        #expect(again.isBriefSheetShown)
        #expect(again.aiSettings.buildsBrief)
    }

    @Test func aFailedStepEndsTheRun() async {
        let editor = makeEditor()
        var reported: [String] = []
        editor.reportError = { title, _ in reported.append(title) }
        editor.aiProviders.briefBuilder = { _ in DownBriefBuilder() }
        editor.startAIFlow(editor.defaultAIPlanTicks)
        await settle(editor)
        #expect(reported == ["The episode brief stopped."])
        #expect(editor.aiFlow == nil)
        #expect(editor.track.cues.count == 2, "What was done stays")
        #expect(editor.canPerform(.planAIFlow))
    }

    @Test func cancellingEndsTheRun() async {
        let editor = makeEditor()
        editor.startAIFlow(editor.defaultAIPlanTicks)
        #expect(editor.aiTask != nil)
        #expect(editor.perform(.cancelAITask))
        #expect(editor.aiFlow == nil && editor.aiTask == nil)

        // While it waits for the brief, the same command ends it.
        editor.startAIFlow([.listen, .brief, .translate])
        await settle(editor)
        #expect(editor.aiFlow?.stop == .confirmBrief)
        #expect(editor.canPerform(.cancelAITask))
        editor.perform(.cancelAITask)
        #expect(editor.aiFlow == nil)
    }

    @Test func withoutARunTheStepsStillFollowEachOtherAsBefore() async {
        let editor = makeEditor()
        #expect(editor.perform(.transcribe))
        await tests.finish(editor)
        for _ in 0..<200 where !editor.isBriefSheetShown { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(editor.aiFlow == nil)
        #expect(editor.isBriefSheetShown, "Transcribing alone still builds the brief")
    }

    @Test func translatingLinesAloneKeepsItsCommandAndTheShortcutOpensThePlan() {
        #expect(EditorCommand.translateWithAI.id == "ai.translate")
        #expect(EditorCommand.translateWithAI.defaultShortcut == nil)
        #expect(EditorCommand.planAIFlow.title == "Translate with AI…")
        #expect(EditorCommand.planAIFlow.defaultShortcut == KeyShortcut(.character("t"), modifiers: [.command, .control]))
        #expect(EditorState.commandsAgentsCannotRun.contains(EditorCommand.planAIFlow.id), "Agents never open dialogs")
    }

    // MARK: Pages

    @Test func thePageIsSavedWithTheProject() {
        let editor = makeEditor(cues: [tests.cue("Hello there.", at: 0)])
        var changes = 0
        editor.projectDidChange = { _ in changes += 1 }
        #expect(editor.perform(.showTranslatePage))
        #expect(editor.page == .translate)
        #expect(editor.isOn(.showTranslatePage) == true && editor.isOn(.showEditPage) == false)
        #expect(changes == 1, "Switching pages is saved")
        let project = editor.projectFile(savingTo: nil)
        #expect(project.page == "translate")

        let reopened = makeEditor()
        reopened.loadProject(project, from: nil)
        #expect(reopened.page == .translate)
        var older = project
        older.page = nil
        reopened.loadProject(older, from: nil)
        #expect(reopened.page == .edit, "Projects from before pages open on the editor")
    }

    @Test func theTicksOnThePageFollowTheProjectUntilChosen() {
        let editor = makeEditor()
        editor.aiSettings.joinsLinesAfterTranslating = true
        #expect(editor.planTicks == [.listen, .brief, .scriptReview, .translate, .join])
        editor.setPlanTick(.brief, false)
        #expect(editor.planTicks == [.listen, .translate, .join], "No brief: no review either")
        editor.setPlanTick(.translate, false)
        #expect(editor.planTicks == [.listen])
        editor.setPlanTick(.translate, true)
        #expect(editor.planTicks == [.listen, .translate, .join], "Joining comes back with translating")
        #expect(editor.stageState(.brief) == .off)
        #expect(editor.stageSummary(.brief) == "Not ticked")
    }
}

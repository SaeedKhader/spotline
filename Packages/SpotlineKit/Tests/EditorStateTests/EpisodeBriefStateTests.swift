import AITools
import EditorCommands
import Foundation
import MediaAnalysis
import PlaybackCore
import SubtitleCore
import Testing
@testable import EditorUI

/// A brief builder that fails, as a provider can.
private struct FailingBriefBuilder: EpisodeBriefBuilder {
    var name: String { "Failing brief" }
    func buildBrief(_ request: BriefRequest) async throws -> EpisodeBrief { throw AIError.provider("Down") }
}

@MainActor
struct EpisodeBriefStateTests {
    let tests = AIStateTests()

    /// An editor with a cue that has a word to check (at 8 s, after what transcription writes),
    /// and the scripted brief builder, or `builder`.
    func makeEditor(builder: (any EpisodeBriefBuilder)? = ScriptedBriefBuilder()) -> EditorState {
        var unsure = tests.cue("Ser Duncan the Tall.", at: 8)
        unsure.unsureWords = ["Duncan"]
        let editor = tests.makeEditor(cues: [unsure])
        editor.aiProviders = AIProviderFactory(
            transcriber: { _ in ScriptedTranscriber.fixture }, translator: { _ in ScriptedTranslator() }, briefBuilder: { _ in builder }
        )
        // Hidden, to see what shows it.
        editor.wantsReviewSidebar = false
        return editor
    }

    @Test func theReviewWaitsForTheBriefBuiltAfterTranscribing() async {
        let editor = makeEditor()
        #expect(!editor.reviewItems(in: .all).isEmpty)
        #expect(editor.perform(.transcribe))
        await tests.finish(editor)
        let brief = editor.track.brief
        #expect(brief?.isConfirmed == false)
        #expect(brief?.people.map(\.name) == ["Rick"])
        #expect(brief?.targetLanguage == "ar")
        #expect(editor.isBriefSheetShown)
        // Nothing to review, and the sidebar stays as it was, until the brief is confirmed.
        #expect(editor.isReviewHeld)
        #expect(editor.reviewItems(in: .all).isEmpty)
        #expect(!editor.hasAnythingToReview)
        #expect(!editor.isReviewSidebarVisible)

        var edited = brief!
        edited.people[0].name = "Rick Sanchez"
        edited.terms.append(EpisodeBrief.Term(term: "  "))
        editor.confirmEpisodeBrief(edited)
        #expect(!editor.isBriefSheetShown)
        #expect(!editor.isReviewHeld)
        #expect(editor.track.brief?.isConfirmed == true)
        #expect(editor.track.brief?.terms.map(\.term) == ["Citadel"])
        #expect(editor.track.cast.map(\.name) == ["Rick Sanchez"])
        #expect(editor.track.cast[0].isConfirmed && editor.track.cast[0].gender == .male)
        #expect(editor.track.cast[0].translatedName == "ريك")
        #expect(editor.reviewItems(in: .words).count == 1)
        #expect(editor.isReviewSidebarVisible)

        // Confirming undoes as one step, and the review waits again.
        editor.perform(.undo)
        #expect(editor.isReviewHeld)
        #expect(editor.track.cast.isEmpty)
    }

    @Test func notNowKeepsTheReviewWaitingAndTheCommandOpensTheBriefAgain() async {
        let editor = makeEditor()
        editor.perform(.transcribe)
        await tests.finish(editor)
        editor.dismissEpisodeBrief()
        #expect(!editor.isBriefSheetShown)
        #expect(editor.isReviewHeld)
        #expect(editor.canPerform(.showEpisodeBrief))
        #expect(editor.perform(.showEpisodeBrief))
        #expect(editor.isBriefSheetShown)
        #expect(editor.aiTask == nil, "Opening a brief that exists builds nothing")
    }

    @Test func buildingAgainReplacesTheBrief() async {
        let editor = makeEditor()
        #expect(!editor.canPerform(.rebuildEpisodeBrief), "Nothing to build again yet")
        editor.perform(.transcribe)
        await tests.finish(editor)
        editor.confirmEpisodeBrief(editor.track.brief!)
        #expect(editor.canPerform(.rebuildEpisodeBrief))
        #expect(editor.perform(.rebuildEpisodeBrief))
        #expect(editor.isReviewHeld)
        await tests.finish(editor)
        #expect(editor.track.brief?.isConfirmed == false)
        #expect(editor.track.brief?.plot == "Rick wakes Morty to go on an adventure.")
        #expect(editor.isBriefSheetShown)
        // The cast confirmed before stays until the new brief is confirmed.
        #expect(editor.track.cast.map(\.name) == ["Rick"])
    }

    @Test func withoutABriefBuilderTheReviewShowsAtOnce() async {
        let editor = makeEditor(builder: nil)
        editor.perform(.transcribe)
        await tests.finish(editor)
        #expect(editor.track.brief == nil)
        #expect(!editor.isReviewHeld)
        #expect(!editor.reviewItems(in: .all).isEmpty)
        #expect(editor.isReviewSidebarVisible)
    }

    @Test func aFailedBriefIsReportedAndTheReviewShows() async {
        let editor = makeEditor(builder: FailingBriefBuilder())
        var errors: [String] = []
        editor.reportError = { title, _ in errors.append(title) }
        editor.perform(.transcribe)
        await tests.finish(editor)
        #expect(errors == ["The episode brief stopped."])
        #expect(editor.track.brief == nil)
        #expect(!editor.isReviewHeld)
        #expect(editor.isReviewSidebarVisible)
    }

    @Test func aBriefIsBuiltFromTheCommandAndItsTermsGoIntoTheGlossary() async {
        let editor = makeEditor()
        editor.perform(.transcribe)
        await tests.finish(editor)
        editor.confirmEpisodeBrief(editor.track.brief!)
        // Built again from the command in translation mode: spelled in the target's language.
        editor.useCuesAsSource()
        editor.edit("Forget") { track in track.brief = nil }
        #expect(editor.perform(.showEpisodeBrief))
        await tests.finish(editor)
        #expect(editor.track.brief?.isConfirmed == false)
        var brief = editor.track.brief!
        brief.terms.append(EpisodeBrief.Term(term: "Portal gun", translation: "مسدس البوابات", addsToGlossary: false))
        editor.confirmEpisodeBrief(brief)
        #expect(editor.glossary.entries.map(\.source) == ["Citadel"])
        #expect(editor.glossary.entries.map(\.target) == ["القلعة"])
    }

    @Test func clearingTheTranscriptClearsTheBrief() async {
        let editor = makeEditor()
        editor.perform(.transcribe)
        await tests.finish(editor)
        editor.clearTranscript()
        #expect(editor.track.brief == nil)
        #expect(!editor.isReviewHeld)
    }

    @Test func translationGetsTheConfirmedBriefsTerms() async throws {
        let editor = makeEditor()
        editor.perform(.transcribe)
        await tests.finish(editor)
        editor.useCuesAsSource()
        editor.edit("Forget") { track in track.brief = nil }
        editor.perform(.showEpisodeBrief)
        await tests.finish(editor)
        var brief = editor.track.brief!
        brief.terms[0].addsToGlossary = false
        editor.confirmEpisodeBrief(brief)
        let recorder = RecordingTranslator()
        editor.aiProviders.translator = { _ in recorder }
        // It translates nothing, which is reported.
        editor.reportError = { _, _ in }
        editor.perform(.translateWithAI)
        await tests.finish(editor)
        let request = try #require(recorder.requests.first)
        #expect(request.glossary.map(\.source).contains("Citadel"))
        #expect(request.cast.first?.name == "Rick" && request.cast.first?.isConfirmed == true)
        #expect(request.brief?.contains("Plot: Rick wakes Morty to go on an adventure.") == true)
        #expect(request.scenes.map(\.text) == ["0:00 Rick greets Morty, who says he is fine."])
        #expect(request.notes == nil, "The brief is not the user's notes")
    }
}

/// Keeps the requests it gets and translates nothing.
private final class RecordingTranslator: CueTranslator, @unchecked Sendable {
    var name: String { "Recording" }
    private let lock = NSLock()
    private var recorded: [TranslationRequest] = []
    var requests: [TranslationRequest] { lock.withLock { recorded } }

    func translate(
        _ request: TranslationRequest, progress: @escaping @Sendable (AIProgress) -> Void,
        found: @escaping @Sendable (TranslationBatch) -> Void
    ) async throws -> TranslationBatch {
        lock.withLock { recorded.append(request) }
        return TranslationBatch()
    }
}

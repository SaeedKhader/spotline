import AITools
import EditorCommands
import Foundation
import MediaAnalysis
import PlaybackCore
import SubtitleCore
import Testing
@testable import EditorUI

@MainActor
struct AIStateTests {
    let rate = FrameRate.fps25

    /// An editor with media, scripted AI providers and silent prepared audio.
    func makeEditor(cues: [Cue] = []) -> EditorState {
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

    func cue(_ text: String, at second: Int64) -> Cue {
        Cue(start: MediaTime(value: second, timescale: 1), end: MediaTime(value: second + 1, timescale: 1), text: text)
    }

    /// Waits for the running AI task to finish.
    func finish(_ editor: EditorState) async {
        for _ in 0..<200 where editor.aiTask != nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func transcriptionIsProposedThenAcceptedAsOneEdit() async {
        let editor = makeEditor()
        #expect(editor.perform(.transcribe))
        #expect(editor.aiTask?.title == "Transcribing")
        await finish(editor)
        let review = try! #require(editor.pendingReview)
        #expect(review.changes.map(\.cue.text) == ["Hello there. How are you?", "Fine, thanks."])
        #expect(editor.track.cues.isEmpty, "Nothing is applied before review")
        #expect(editor.proposedInserts.count == 2)
        #expect(editor.selectedCueID == review.changes[0].cueID)
        // Tools wait while a review is open.
        #expect(!editor.canPerform(.transcribe))

        #expect(editor.perform(.acceptAllChanges))
        #expect(editor.track.cues.map(\.text) == ["Hello there. How are you?", "Fine, thanks."])
        #expect(editor.pendingReview == nil)
        editor.perform(.undo)
        #expect(editor.track.cues.isEmpty)
    }

    @Test func changesAreAcceptedOrRejectedOneByOne() {
        let editor = makeEditor(cues: [cue("(sighs) Fine.", at: 0), cue("OK", at: 2), cue("[music]", at: 4), cue("JOHN: Go.", at: 6)])
        #expect(editor.perform(.removeHearingImpaired))
        let review = try! #require(editor.pendingReview)
        #expect(review.changes.count == 3)
        let first = editor.track.cues[0].id
        #expect(editor.selectedCueID == first)

        // Accept moves on to the next change.
        #expect(editor.perform(.acceptChange))
        #expect(editor.track.cues[0].text == "Fine.")
        #expect(editor.selectedCueID == editor.track.cues[2].id)
        // Reject leaves the cue (the sound description stays) and moves on.
        #expect(editor.perform(.rejectChange))
        #expect(editor.track.cues[2].text == "[music]")
        #expect(editor.selectedCueID == editor.track.cues[3].id)
        #expect(editor.pendingReview?.changes.count == 1)
        #expect(editor.perform(.rejectAllChanges))
        #expect(editor.pendingReview == nil)
        #expect(editor.track.cues.map(\.text) == ["Fine.", "OK", "[music]", "JOHN: Go."])
        // One undo step per accepted change.
        editor.perform(.undo)
        #expect(editor.track.cues[0].text == "(sighs) Fine.")
    }

    @Test func removingAllTextProposesDeletingTheCue() {
        let editor = makeEditor(cues: [cue("[door slams]", at: 0), cue("Who's there?", at: 2)])
        editor.perform(.removeHearingImpaired)
        #expect(editor.perform(.acceptAllChanges))
        #expect(editor.track.cues.map(\.text) == ["Who's there?"])
    }

    @Test func translationProposesAddresseeVariants() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "AIStateTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appending(path: "Pilot.en.srt")
        try "1\n00:00:01,000 --> 00:00:02,000\nWhere are you going?\n\n2\n00:00:03,000 --> 00:00:04,000\nHome.\n".write(
            to: source, atomically: true, encoding: .utf8
        )
        let editor = makeEditor()
        editor.openSourceSubtitles(from: source)
        editor.setTargetLanguage("ar")
        #expect(editor.perform(.translateWithAI))
        await finish(editor)
        let review = try #require(editor.pendingReview)
        #expect(review.changes.count == 2)
        editor.perform(.acceptAllChanges)
        let first = editor.track.cues[0]
        #expect(first.text == "[ar] Where are you going? ♀")
        #expect(first.addressee?.needsReview == true)
        #expect(first.variants?.count == 3)
        #expect(editor.track.cues[1].text == "[ar] Home.")
        #expect(!editor.canPerform(.translateWithAI), "Everything is translated")

        // One click on the chip picks the male wording and confirms it.
        editor.chooseAddressee(.male, forCue: first.id)
        #expect(editor.track.cues[0].text == "[ar] Where are you going? ♂")
        #expect(editor.track.cues[0].addressee == AddresseeTag(.male, confidence: 1, source: .confirmed))
        #expect(editor.issues[first.id]?.contains { $0.kind == .addresseeGuess } != true)
        editor.perform(.undo)
        #expect(editor.track.cues[0].text == "[ar] Where are you going? ♀")
    }

    @Test func transcribedCuesCanBeTranslatedDirectly() async throws {
        var line = cue("Where are you going?", at: 1)
        let speaker = Speaker(gender: .male, confidence: 0.9)
        line.speakerID = speaker.id
        let editor = makeEditor(cues: [line, cue("Home.", at: 3)])
        #expect(!editor.isTranslating)
        #expect(editor.canPerform(.translateWithAI))
        #expect(editor.perform(.translateWithAI))
        #expect(editor.isTranslating)
        #expect(editor.sourceTrack?.cues.map(\.text) == ["Where are you going?", "Home."])
        #expect(editor.track.languageCode == "ar")
        #expect(editor.track.cues[0].speakerID == speaker.id)
        await finish(editor)
        editor.perform(.acceptAllChanges)
        #expect(editor.track.cues.map(\.text) == ["[ar] Where are you going? ♀", "[ar] Home."])
    }

    @Test func cancellingStopsWithoutProposing() async {
        let editor = makeEditor()
        editor.prepareAudio = { _, _, _ in
            try await Task.sleep(for: .seconds(10))
            throw CancellationError()
        }
        editor.perform(.transcribe)
        #expect(editor.canPerform(.cancelAITask))
        #expect(editor.perform(.cancelAITask))
        #expect(editor.aiTask == nil)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(editor.pendingReview == nil)
        #expect(editor.canPerform(.transcribe))
    }

    @Test func cloudProvidersNeedConsent() {
        let editor = makeEditor()
        var reported: String?
        editor.reportError = { _, error in reported = (error as? LocalizedError)?.errorDescription }
        editor.aiProviders = .live(keys: APIKeyStore(service: "spotline-tests-\(UUID().uuidString)"))
        editor.aiSettings.transcription = .openAIWhisper
        editor.perform(.transcribe)
        #expect(reported == AIError.cloudNotAllowed.errorDescription)
        editor.aiSettings.allowsCloud = true
        editor.perform(.transcribe)
        #expect(reported == AIError.missingAPIKey(provider: "OpenAI").errorDescription)
        #expect(editor.aiTask == nil)
    }

    @Test func splittingDropsVariants() {
        var withVariants = Cue(start: .zero, end: MediaTime(value: 2, timescale: 1), text: "انت مشغول\nجدا")
        withVariants.variants = [TextVariant(addressee: .male, text: "انت مشغول\nجدا")]
        let editor = makeEditor(cues: [withVariants])
        editor.select(withVariants.id)
        editor.perform(.splitCue)
        #expect(editor.track.cues.allSatisfy { $0.variants == nil })
    }
}

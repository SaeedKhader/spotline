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

    @Test func transcriptionGoesStraightIntoTheCueList() async {
        let editor = makeEditor()
        #expect(editor.perform(.transcribe))
        #expect(editor.aiTask?.title == "Transcription")
        await finish(editor)
        #expect(editor.pendingReview == nil, "Transcription is not reviewed")
        #expect(editor.track.cues.map(\.text) == ["Hello there. How are you?", "Fine, thanks."])
        #expect(editor.track.cues.allSatisfy { $0.isAIGenerated == true })
        // Typing makes a cue the user's.
        editor.setText("Hello there! How are you?", forCue: editor.track.cues[0].id)
        #expect(editor.track.cues[0].isAIGenerated == nil)
        // One undo step per batch: the first sentence came before the second.
        editor.perform(.undo)
        editor.perform(.undo)
        #expect(editor.track.cues.map(\.text) == ["Hello there. How are you?"])
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

    @Test func translationFlagsLinesThatReadMoreThanOneWay() async throws {
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
        #expect(editor.pendingReview == nil)
        let first = editor.track.cues[0]
        // The recommendation goes straight in, tinted, with the other variants and the reason kept.
        #expect(first.text == "[ar] Where are you going? ♀")
        #expect(first.isAIGenerated == true)
        #expect(first.flag?.variants.count == 3)
        #expect(first.flag?.note == "Beth answered last")
        #expect(first.flag?.isResolved == false)
        #expect(editor.track.cues[1].flag == nil)
        #expect(editor.track.cast.map(\.name) == ["Beth", "Jerry"], "The translator's cast is kept")
        #expect(editor.cuesToChoose.map(\.id) == [first.id])
        #expect(!editor.canPerform(.translateWithAI), "Everything is translated")

        // One click picks another variant and settles the choice, as one undoable step.
        editor.chooseVariant(1, forCue: first.id)
        #expect(editor.track.cues[0].text == "[ar] Where are you going? ♂")
        #expect(editor.track.cues[0].flag?.isResolved == true)
        #expect(editor.track.cast.member(named: "Jerry")?.isConfirmed == true)
        #expect(editor.cuesToChoose.isEmpty)
        editor.perform(.undo)
        #expect(editor.track.cues[0].text == "[ar] Where are you going? ♀")
        #expect(editor.track.cues[0].flag?.isResolved == false)
        #expect(editor.track.cast.member(named: "Jerry")?.isConfirmed == false)
    }

    /// Two open choices about Beth, the second less sure; and one about Jerry.
    func flaggedCues() -> [Cue] {
        func line(_ at: Int64, _ confidence: Double, _ variants: [TranslationVariant]) -> Cue {
            var cue = cue(variants[0].text, at: at)
            cue.isAIGenerated = true
            cue.flag = TranslationFlag(reasons: [.listener], variants: variants, confidence: confidence, note: "")
            return cue
        }
        return [
            line(0, 0.7, [
                TranslationVariant(text: "انت مستعد؟", listeners: ["Beth"], listenerGender: .male, listenerCount: .one),
                TranslationVariant(text: "انتِ مستعدة؟", listeners: ["Beth"], listenerGender: .female, listenerCount: .one),
            ]),
            line(2, 0.4, [
                TranslationVariant(text: "هل انت جائع؟", listeners: ["Beth"], listenerGender: .male, listenerCount: .one),
                TranslationVariant(text: "هل انتِ جائعة؟", listeners: ["Beth"], listenerGender: .female, listenerCount: .one),
                TranslationVariant(text: "هل انتم جائعون؟", listeners: ["Beth", "Jerry"], listenerGender: .mixed, listenerCount: .two),
            ]),
            line(4, 0.9, [
                TranslationVariant(text: "اجلس.", listeners: ["Jerry"], listenerGender: .male, listenerCount: .one),
                TranslationVariant(text: "اجلسي.", listeners: ["Jerry"], listenerGender: .female, listenerCount: .one),
            ]),
        ]
    }

    @Test func aPickAboutSomeoneReranksTheirOtherLines() {
        let cues = flaggedCues()
        let editor = makeEditor(cues: cues)
        // Least sure first.
        #expect(editor.cuesToChoose.map(\.id) == [cues[1].id, cues[0].id, cues[2].id])
        // Beth is a woman: her other line switches to the feminine form and is settled,
        // the line to Beth and Jerry keeps its choice open, Jerry's line is untouched.
        editor.chooseVariant(1, forCue: cues[1].id)
        #expect(editor.track.cues[1].text == "هل انتِ جائعة؟")
        #expect(editor.track.cast.member(named: "Beth")?.gender == .female)
        #expect(editor.track.cues[0].text == "انتِ مستعدة؟")
        #expect(editor.track.cues[0].flag?.isResolved == true)
        #expect(editor.track.cues[2].text == "اجلس.")
        #expect(editor.track.cues[2].flag?.isResolved == false)
        // All of it is one undo step.
        editor.perform(.undo)
        #expect(editor.track.cues.map(\.text) == cues.map(\.text))
        #expect(editor.track.cast.isEmpty)
    }

    @Test func reviewingShowsOnlyOpenChoicesAndAcceptingTheRestEndsIt() {
        let cues = flaggedCues()
        let editor = makeEditor(cues: cues)
        #expect(editor.isOn(.reviewChoices) == false)
        #expect(editor.perform(.reviewChoices))
        #expect(editor.isReviewingChoices)
        #expect(editor.selectedCueID == cues[1].id, "The least sure line is selected")
        // Up and down move through the flagged lines in the review's order.
        #expect(editor.perform(.nextCue))
        #expect(editor.selectedCueID == cues[0].id)
        // A pick moves on to the next open choice.
        editor.chooseVariant(0, forCue: cues[0].id)
        #expect(editor.selectedCueID == cues[2].id)
        #expect(editor.perform(.acceptRemainingChoices))
        #expect(!editor.isReviewingChoices)
        #expect(editor.cuesToChoose.isEmpty)
        #expect(editor.track.cues[2].text == "اجلس.", "Accepting keeps the translator's picks")
        #expect(!editor.canPerform(.reviewChoices))
        editor.perform(.undo)
        #expect(editor.cuesToChoose.count == 2)
    }

    @Test func typingSettlesTheChoice() {
        let cues = flaggedCues()
        let editor = makeEditor(cues: cues)
        editor.setText("انتِ جاهزة؟", forCue: cues[0].id)
        #expect(editor.track.cues[0].flag?.isResolved == true)
        #expect(editor.track.cues[0].isAIGenerated == nil)
    }

    @Test func linesTheTranslatorLeavesOutAreReported() async throws {
        let editor = makeEditor(cues: [cue("Hello.", at: 1), cue("Leave me alone.", at: 3)])
        editor.aiProviders = AIProviderFactory(transcriber: { _ in ScriptedTranscriber.fixture }, translator: { _ in SkippingTranslator() })
        var reported: [String] = []
        editor.reportError = { title, _ in reported.append(title) }
        #expect(editor.perform(.translateWithAI))
        await finish(editor)
        #expect(editor.track.cues.map(\.text) == ["[ar] Hello.", ""])
        #expect(reported == ["1 line was not translated."])
        #expect(editor.issues[editor.track.cues[1].id]?.contains { $0.kind == .notTranslated } == true)
    }

    @Test func transcribedCuesCanBeTranslatedDirectly() async throws {
        var line = cue("Where are you going?", at: 1)
        line.voices = ["speaker_0"]
        let editor = makeEditor(cues: [line, cue("Home.", at: 3)])
        #expect(!editor.isTranslating)
        #expect(editor.canPerform(.translateWithAI))
        #expect(editor.perform(.translateWithAI))
        #expect(editor.isTranslating)
        #expect(editor.sourceTrack?.cues.map(\.text) == ["Where are you going?", "Home."])
        #expect(editor.track.languageCode == "ar")
        #expect(editor.voices(for: editor.track.cues[0]) == ["speaker_0"], "The source's voices go to the translator")
        await finish(editor)
        #expect(editor.track.cues.map(\.text) == ["[ar] Where are you going? ♀", "[ar] Home."])
    }

    @Test func cuesShowWhileTranscribingAndEditsAreKept() async throws {
        let editor = makeEditor()
        let release = AsyncStream<Void>.makeStream()
        let words = ScriptedTranscriber.fixture.words
        editor.aiProviders = AIProviderFactory(
            transcriber: { _ in PausingTranscriber(words: words, gate: release.stream) },
            translator: { _ in ScriptedTranslator() }
        )
        editor.perform(.transcribe)
        // The first sentence is complete once "Fine," is heard; it shows before the task ends.
        for _ in 0..<200 where editor.track.cues.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(editor.aiTask != nil)
        #expect(editor.track.cues.map(\.text) == ["Hello there. How are you?"])
        let first = editor.track.cues[0].id
        editor.setText("Hi there. How are you?", forCue: first)

        release.continuation.yield()
        await finish(editor)
        #expect(editor.track.cues.map(\.text) == ["Hi there. How are you?", "Fine, thanks."])
        #expect(editor.track.cues.first?.id == first)
    }

    @Test func cleanupIsStillReviewed() {
        let editor = makeEditor(cues: [cue("Holy shit.", at: 0)])
        editor.perform(.maskProfanity)
        #expect(editor.pendingReview?.changes.count == 1)
        #expect(editor.track.cues[0].text == "Holy shit.")
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
        #expect(editor.track.cues.isEmpty)
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
        var flagged = Cue(start: .zero, end: MediaTime(value: 2, timescale: 1), text: "انت مشغول\nجدا")
        flagged.flag = TranslationFlag(reasons: [.listener], variants: [
            TranslationVariant(text: "انت مشغول\nجدا"), TranslationVariant(text: "انتِ مشغولة\nجدا"),
        ], confidence: 0.5, note: "")
        let editor = makeEditor(cues: [flagged])
        editor.select(flagged.id)
        editor.perform(.splitCue)
        #expect(editor.track.cues.allSatisfy { $0.flag == nil })
    }
}

/// Hears the first five words, then waits for `gate` before the rest.
private struct PausingTranscriber: Transcriber {
    var name: String { "Pausing" }
    let words: [TranscribedWord]
    let gate: AsyncStream<Void>

    func transcribe(
        _ audio: PreparedAudio, language: String?, progress: @escaping @Sendable (Double) -> Void,
        found: @escaping @Sendable ([TranscribedWord]) -> Void
    ) async throws -> [TranscribedWord] {
        found(Array(words.prefix(6)))
        for await _ in gate { break }
        found(Array(words.dropFirst(6)))
        return words
    }
}

/// Translates every line but the ones with "alone" in them, as a model that declines them would.
private struct SkippingTranslator: CueTranslator {
    var name: String { "Skipping" }

    func translate(
        _ request: TranslationRequest, progress: @escaping @Sendable (Double) -> Void,
        found: @escaping @Sendable (TranslationBatch) -> Void
    ) async throws -> TranslationBatch {
        let batch = TranslationBatch(translations: request.lines.filter { !$0.source.contains("alone") }.map {
            CueTranslation(cueID: $0.cueID, text: "[ar] " + $0.source)
        })
        found(batch)
        return batch
    }
}

import Foundation
import MediaAnalysis
import QualityControl
import SubtitleCore
import Testing
@testable import AITools

struct TranscriptionFixUpTests {
    let rate = FrameRate.fps25

    func words(_ list: [(String, Double, Double)]) -> [TranscribedWord] {
        list.map { TranscribedWord(text: $0.0, start: MediaTime(seconds: $0.1, timescale: 1000), end: MediaTime(seconds: $0.2, timescale: 1000)) }
    }

    @Test func wordStartLeadMovesCueStartsLater() {
        let heard = words([("Hello", 1.0, 1.4), ("there.", 1.45, 1.9)])
        let plain = TranscriptionPipeline(preset: .netflix, frameRate: rate).cues(from: heard)
        let corrected = TranscriptionPipeline(preset: .netflix, frameRate: rate, wordStartLead: 0.1).cues(from: heard)
        #expect(plain[0].start == MediaTime(frame: 25, rate: rate))
        #expect(corrected[0].start == MediaTime(frame: 28, rate: rate))
    }

    @Test func shortGapsCloseToTheMinimumGap() {
        // The second line starts 0.3 s after the first would end (last word + linger): the first runs on to it.
        let cues = CueSegmenter(preset: .netflix, frameRate: rate).cues(from: words([
            ("I", 0.0, 0.2), ("never", 0.25, 0.6), ("said", 0.65, 0.9), ("that.", 0.95, 1.4),
            ("You", 2.2, 2.4), ("did", 2.45, 2.7), ("say", 2.75, 3.0), ("it.", 3.05, 3.5),
        ]))
        #expect(cues.count == 2)
        #expect(cues[1].start.firstFrame(at: rate) - cues[0].end.firstFrame(at: rate) == 2)
    }

    @Test func cuesStayUpLongEnoughToRead() {
        // 43 characters said in 1.2 s: at 20 c/s the cue needs 2.15 s, and the next cue is far away.
        let cues = CueSegmenter(preset: .netflix, frameRate: rate).cues(from: words([
            ("Absolutely", 0.0, 0.3), ("extraordinary", 0.3, 0.7), ("circumstances,", 0.7, 1.0), ("really.", 1.0, 1.2),
            ("Yes.", 6.0, 6.3),
        ]))
        #expect(cues[0].readingSpeed <= 20)
    }

    @Test func aCueStartsEarlyOnAShotChangeButNotLate() {
        let heard = words([("Somewhere", 0.92, 1.5), ("else.", 1.55, 2.2)])
        // The cut 8 frames after the voice would make the text lag: the cue starts with the voice.
        let late = CueSegmenter(preset: .netflix, frameRate: rate, shotChanges: [31]).cues(from: heard)
        #expect(late[0].start == MediaTime(frame: 23, rate: rate))
        let early = CueSegmenter(preset: .netflix, frameRate: rate, shotChanges: [15]).cues(from: heard)
        #expect(early[0].start == MediaTime(frame: 15, rate: rate))
    }

    @Test func shortSentencesGetTheirOwnCueWhenThereIsTimeToReadThem() {
        let segmenter = CueSegmenter(preset: .netflix, frameRate: rate)
        // "What's going on?" (16 characters) has 1.5 s before the next word: its own cue.
        let roomy = segmenter.cues(from: words([
            ("What's", 0.0, 0.3), ("going", 0.3, 0.6), ("on?", 0.6, 0.9), ("I", 1.5, 1.6), ("got", 1.6, 1.8), ("a", 1.8, 1.9), ("surprise.", 1.9, 2.4),
        ]))
        #expect(roomy.map(\.text) == ["What's going on?", "I got a surprise."])
        // Said in a rush, it would be unreadable alone: it stays with the next sentence.
        let rushed = segmenter.cues(from: words([
            ("What's", 0.0, 0.1), ("going", 0.1, 0.2), ("on?", 0.2, 0.3), ("I", 0.35, 0.4), ("got", 0.4, 0.5), ("a", 0.5, 0.55), ("surprise.", 0.55, 0.9),
        ]))
        #expect(rushed.map(\.text) == ["What's going on? I got a surprise."])
    }
}

struct TranslationFixUpTests {
    let pipeline = TranslationPipeline(preset: .netflix)
    let request = TranslationRequest(lines: [], sourceLanguage: "en", targetLanguage: "ar")

    @Test func blankLinesGoAndTextIsLaidOutAgain() {
        let fixed = pipeline.fix([CueTranslation(cueID: UUID(), text: "فكر في هذا\n\nمركبة طائرة، مورتي؟")], request: request)
        #expect(fixed[0].text == "فكر في هذا مركبة طائرة، مورتي؟")
        let long = "لقد قمت ببنائها من الأشياء التي وجدتها في المرآب يا مورتي."
        let lines = pipeline.layout(long).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.count <= 42 })
    }

    @Test func dialogueKeepsALinePerSpeaker() {
        #expect(pipeline.layout("- مرحبا.\n\n- أهلا.") == "- مرحبا.\n- أهلا.")
        #expect(AppleTranslator.sourceText("- Hi.\n- Hello.") == "- Hi.\n- Hello.")
        #expect(AppleTranslator.sourceText("I built it out of\nstuff I found.") == "I built it out of stuff I found.")
    }

    @Test func sentencesOverSeveralCuesAreJoinedAndSharedOutAgain() {
        func line(_ text: String, _ start: Double, _ end: Double) -> (text: String, start: MediaTime, end: MediaTime) {
            (text, MediaTime(seconds: start, timescale: 1000), MediaTime(seconds: end, timescale: 1000))
        }
        let groups = SentenceSpans.groups([
            line("What do you think of this", 0, 1.5), line("flying vehicle, Morty?", 1.6, 3),
            line("I had to...", 3.1, 4), line("I had to make a bomb.", 4.1, 5),
            line("Wait", 9, 9.5), line("for me.", 12, 13),
        ])
        #expect(groups == [[0, 1], [2], [3], [4], [5]])

        let parts = SentenceSpans.split("ما رأيك في هذه السيارة الطائرة يا مورتي؟", like: ["What do you think of this", "flying vehicle, Morty?"])
        #expect(parts.count == 2)
        #expect(parts.joined(separator: " ") == "ما رأيك في هذه السيارة الطائرة يا مورتي؟")
        #expect(parts.allSatisfy { !$0.isEmpty })
    }

    @Test func glossaryTermsReplaceTheModelsOwnRendering() {
        let enforcer = GlossaryEnforcer(terms: [("Mega seeds", "بذور ضخمة", "بذور ميجا")])
        #expect(enforcer.apply(to: "أنا أتحدث عن بذور ميجا.", source: "I'm talking about Mega seeds.") == "أنا أتحدث عن بذور ضخمة.")
        // Not in the source, or already agreed: left alone.
        #expect(enforcer.apply(to: "بذور ميجا", source: "Seeds") == "بذور ميجا")
        #expect(enforcer.apply(to: "بذور ضخمة", source: "Mega seeds") == "بذور ضخمة")
    }
}

struct ElevenLabsTests {
    @Test func scribeWordsKeepPunctuationAndSkipSpacingAndEvents() throws {
        let json = """
            {"language_code": "en", "text": "Morty, come on.", "words": [
              {"text": "Morty,", "type": "word", "start": 3.12, "end": 3.5},
              {"text": " ", "type": "spacing", "start": 3.5, "end": 3.52},
              {"text": "(laughs)", "type": "audio_event", "start": 3.52, "end": 3.9},
              {"text": "come", "type": "word", "start": 3.9, "end": 4.1},
              {"text": "on.", "type": "word", "start": 4.1, "end": 4.3}
            ]}
            """
        let words = try ElevenLabsTranscriber.words(from: Data(json.utf8))
        #expect(words.map(\.text) == ["Morty,", "come", "on."])
        #expect(words[0].start == MediaTime(value: 3120, timescale: 1000))
    }

    @Test func chunksGoOnOneTimelineWithSilenceBetween() {
        let audio = PreparedAudio(
            source: .mix, audioStreamIndex: 0, duration: MediaTime(value: 3, timescale: 1),
            chunks: [AudioChunk(id: 0, start: MediaTime(value: 1, timescale: 1), samples: [Float](repeating: 0.5, count: 16_000))]
        )
        let samples = ElevenLabsTranscriber.samples(of: audio)
        #expect(samples.count == 48_000)
        #expect(samples[15_999] == 0)
        #expect(samples[16_000] == 0.5)
        #expect(samples[32_000] == 0)
    }
}

import Foundation
import MediaAnalysis
import SubtitleCore
import Testing
@testable import AITools

struct SpeakerAnalysisTests {
    static let rate = PreparedAudio.sampleRate

    /// A voice-like sound: a fundamental with harmonics shaped by two formants.
    static func voice(pitch: Double, formants: (Double, Double), seconds: Double) -> [Float] {
        let count = Int(seconds * Double(rate))
        let harmonics = Array(1...Int(4000 / pitch))
        return (0..<count).map { index in
            let t = Double(index) / Double(rate)
            // A little vibrato, as in real speech.
            let f0 = pitch * (1 + 0.02 * sin(2 * .pi * 5 * t))
            var sample = 0.0
            for h in harmonics {
                let frequency = f0 * Double(h)
                let gain = exp(-pow((frequency - formants.0) / 250, 2)) + 0.7 * exp(-pow((frequency - formants.1) / 350, 2)) + 0.05
                sample += gain * sin(2 * .pi * frequency * t) / Double(harmonics.count) * 4
            }
            return Float(sample * 0.3)
        }
    }

    /// Six lines alternating between a low male voice and a high female voice, a second of silence apart.
    static func conversation() -> (PreparedAudio, [Cue]) {
        var samples: [Float] = []
        var cues: [Cue] = []
        for line in 0..<6 {
            let male = line.isMultiple(of: 2)
            let start = samples.count
            samples += male
                ? voice(pitch: 110, formants: (500, 1500), seconds: 1.5)
                : voice(pitch: 220, formants: (850, 2300), seconds: 1.5)
            cues.append(Cue(
                start: MediaTime(value: Int64(start), timescale: Int64(rate)),
                end: MediaTime(value: Int64(samples.count), timescale: Int64(rate)),
                text: "Line \(line)"
            ))
            samples += [Float](repeating: 0, count: rate)
        }
        let audio = PreparedAudio(
            source: .mix, audioStreamIndex: 0, duration: MediaTime(value: Int64(samples.count), timescale: Int64(rate)),
            chunks: [AudioChunk(id: 0, start: .zero, samples: samples)]
        )
        return (audio, cues)
    }

    @Test func pitchIsFound() {
        let low = VoiceSpeakerAnalyzer.voiceprint(Self.voice(pitch: 110, formants: (500, 1500), seconds: 1), sampleRate: Self.rate)
        let high = VoiceSpeakerAnalyzer.voiceprint(Self.voice(pitch: 220, formants: (850, 2300), seconds: 1), sampleRate: Self.rate)
        #expect(abs((low.pitch ?? 0) - 110) < 8)
        #expect(abs((high.pitch ?? 0) - 220) < 12)
        #expect(low.voicedSeconds > 0.6, "\(low.voicedSeconds)")
    }

    @Test func twoVoicesMakeTwoSpeakersWithGenders() {
        let (audio, cues) = Self.conversation()
        let result = VoiceSpeakerAnalyzer().analyze(cues, in: audio)
        #expect(result.speakers.count == 2)
        #expect(result.speakers.map(\.gender) == [.male, .female])
        #expect(result.speakers.allSatisfy { $0.confidence >= 0.75 })
        let ids = cues.map { result.assignments[$0.id]?.speakerID }
        #expect(ids == (0..<6).map { result.speakers[$0 % 2].id })
    }

    @Test func silentCuesGetNoSpeaker() {
        let (audio, cues) = Self.conversation()
        let silent = Cue(start: MediaTime(value: 1_000, timescale: 1), end: MediaTime(value: 1_001, timescale: 1), text: "?")
        let result = VoiceSpeakerAnalyzer().analyze(cues + [silent], in: audio)
        #expect(result.assignments[silent.id] == nil)
    }
}

struct AddresseeInferenceTests {
    let man = Speaker(gender: .male, confidence: 0.95)
    let woman = Speaker(gender: .female, confidence: 0.95)
    let third = Speaker(gender: .male, confidence: 0.9)

    func line(_ text: String, at second: Int64, by speaker: Speaker?) -> SceneAddresseeInferrer.Line {
        SceneAddresseeInferrer.Line(
            cueID: UUID(), text: text, start: MediaTime(value: second, timescale: 1), end: MediaTime(value: second + 1, timescale: 1),
            speakerID: speaker?.id, speakerConfidence: 0.9
        )
    }

    @Test func twoPeopleTalkingAddressEachOther() {
        let lines = [
            line("Where are you going?", at: 0, by: man),
            line("Leave me alone.", at: 2, by: woman),
            line("I said nothing.", at: 4, by: man),
        ]
        let tags = SceneAddresseeInferrer().infer(lines, speakers: [man, woman], language: "en")
        #expect(tags[lines[0].cueID]?.addressee == .female)
        #expect(tags[lines[0].cueID]?.needsReview == false)
        #expect(tags[lines[1].cueID]?.addressee == .male, "An imperative addresses someone")
        #expect(tags[lines[2].cueID] == nil, "No “you”, no addressee")
    }

    @Test func formsOfAddressDecide() {
        let lines = [
            line("Good evening, ladies.", at: 0, by: man),
            line("Hello everyone, thank you for coming.", at: 2, by: man),
            line("Yes, sir.", at: 4, by: woman),
            line("Did you see your mom?", at: 6, by: man),
        ]
        let tags = SceneAddresseeInferrer().infer(lines, speakers: [man, woman], language: "en")
        #expect(tags[lines[0].cueID]?.addressee == .groupFemale)
        #expect(tags[lines[1].cueID]?.addressee == .groupMixed)
        #expect(tags[lines[2].cueID]?.addressee == .male)
        // "your mom" is not addressing a mother: the listener is the woman who spoke before.
        #expect(tags[lines[3].cueID]?.addressee == .female)
    }

    @Test func crowdedScenesAndUnknownVoicesAreFlagged() {
        let lines = [
            line("I'm here.", at: 0, by: woman),
            line("So am I.", at: 2, by: third),
            line("What do you want?", at: 4, by: man),
        ]
        let tags = SceneAddresseeInferrer().infer(lines, speakers: [man, woman, third], language: "en")
        #expect(tags[lines[2].cueID]?.addressee == .male, "The last speaker before")
        #expect(tags[lines[2].cueID]?.needsReview == true, "Three people: only a guess")

        let alone = [line("Are you there?", at: 0, by: nil)]
        let unknown = SceneAddresseeInferrer().infer(alone, speakers: [], language: "en")
        #expect(unknown[alone[0].cueID]?.addressee == .unknown)
        #expect(unknown[alone[0].cueID]?.needsReview == true)
    }

    @Test func longPausesEndScenes() {
        let lines = [
            line("Hi.", at: 0, by: woman),
            line("Where are you?", at: 60, by: man),
        ]
        let tags = SceneAddresseeInferrer().infer(lines, speakers: [man, woman], language: "en")
        #expect(tags[lines[1].cueID]?.addressee == .unknown)
    }
}

struct CloudProviderTests {
    func request(target: String = "ar") -> TranslationRequest {
        TranslationRequest(
            lines: [
                .init(cueID: UUID(), source: "You are busy.", start: .zero, end: MediaTime(value: 2, timescale: 1),
                      speaker: .init(label: "A", gender: .male, confidence: 0.9)),
                .init(cueID: UUID(), source: "Winterfell is cold.", start: MediaTime(value: 3, timescale: 1), end: MediaTime(value: 4, timescale: 1)),
            ],
            sourceLanguage: "en", targetLanguage: target, glossary: [("Winterfell", "وينترفيل", "place")],
            maxCharactersPerLine: 42, maxLines: 2
        )
    }

    @Test func claudeRequestAsksForStructuredOutput() throws {
        let body = ClaudeTranslator.body(for: request())
        #expect(body["model"] as? String == "claude-opus-5-5")
        #expect(body["fallbacks"] as? String == "default")
        let config = try #require(body["output_config"] as? [String: Any])
        let format = try #require(config["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        let user = try #require((body["messages"] as? [[String: Any]])?.first?["content"] as? String)
        #expect(user.contains("Winterfell → وينترفيل (place)"))
        #expect(user.contains("L1 | 0.0s | speaker A (male voice, 90% sure) | You are busy."))
        #expect((body["system"] as? String)?.contains("variants") == true, "Arabic asks for addressees and variants")
        let english = ClaudeTranslator.body(for: request(target: "en"))
        #expect((english["system"] as? String)?.contains("variants") == false)
        #expect(try JSONSerialization.data(withJSONObject: body).count > 0)
    }

    @Test func claudeAnswerMapsBackToCues() throws {
        let request = request()
        let output = """
            {"translations": [
              {"id": "L1", "text": "انتِ مشغولة.", "addressee": "female", "confidence": 0.55,
               "variants": [{"addressee": "male", "text": "انت مشغول."}, {"addressee": "groupMixed", "text": "انتم مشغولون."}]},
              {"id": "L2", "text": "وينترفيل باردة.", "addressee": "unknown", "confidence": 0.9, "variants": []}
            ]}
            """
        let response: [String: Any] = ["content": [["type": "text", "text": output]], "stop_reason": "end_turn"]
        let translations = try ClaudeTranslator.translations(from: JSONSerialization.data(withJSONObject: response), request: request)
        #expect(translations.count == 2)
        #expect(translations[0].cueID == request.lines[0].cueID)
        #expect(translations[0].addressee == AddresseeTag(.female, confidence: 0.55))
        #expect(translations[0].variants?.map(\.addressee) == [.female, .male, .groupMixed])
        #expect(translations[1].addressee == nil, "A confident “nobody” needs no tag")
        #expect(translations[1].variants == nil)
    }

    @Test func claudeRefusalIsAnError() throws {
        let response: [String: Any] = ["content": [], "stop_reason": "refusal"]
        #expect(throws: AIError.self) {
            try ClaudeTranslator.translations(from: JSONSerialization.data(withJSONObject: response), request: request())
        }
    }

    @Test func whisperWordsKeepPunctuationAndMediaTime() throws {
        let json = """
            {"text": "Hello, John. Ready?", "segments": [{"text": " Hello, John. Ready?"}],
             "words": [{"word": "Hello", "start": 0.0, "end": 0.4}, {"word": "John", "start": 0.5, "end": 0.9}, {"word": "Ready", "start": 1.2, "end": 1.6}]}
            """
        let chunk = AudioChunk(id: 0, start: MediaTime(value: 10, timescale: 1), samples: [])
        let words = try OpenAITranscriber.words(from: Data(json.utf8), chunk: chunk)
        #expect(words.map(\.text) == ["Hello,", "John.", "Ready?"])
        #expect(words[1].start == MediaTime(value: 10_500, timescale: 1000))
    }

    @Test func languagesAreNormalized() {
        #expect(Languages.base("eng") == "en")
        #expect(Languages.base("ar-EG") == "ar")
        #expect(Languages.addressesByGender("ar"))
        #expect(!Languages.addressesByGender("en"))
    }
}

import Foundation
import SubtitleCore
import Testing
@testable import AITools

struct EpisodeBriefBuilderTests {
    func request(work: String? = "A Knight of the Seven Kingdoms S01E01") -> BriefRequest {
        BriefRequest(
            lines: [
                .init(start: .zero, voices: ["speaker_0"], text: "Dunk, the horse is lame.", unsureWords: ["Dunk"]),
                .init(start: MediaTime(value: 65, timescale: 1), voices: ["speaker_1"], text: "Then we walk to Ashford."),
                .init(start: MediaTime(value: 70, timescale: 1), voices: ["speaker_2"], text: "Ser, a word."),
            ],
            sourceLanguage: "en", targetLanguage: "ar", work: work,
            cast: [CastMember(name: "Egg", gender: .male, isConfirmed: true, voices: ["speaker_0"], translatedName: "إيغ")],
            spellings: [.init(source: "Ashford", target: "آشفورد")]
        )
    }

    @Test func requestSendsTheTranscriptWithVoicesAndSearchesOnlyForANamedShow() throws {
        let body = OpenAIBriefBuilder.body(for: request())
        #expect(body["model"] as? String == "gpt-6-luna")
        #expect(body["store"] as? Bool == false)
        let input = try #require(body["input"] as? String)
        #expect(input.contains("A Knight of the Seven Kingdoms S01E01"))
        #expect(input.contains("[0:00] speaker_0: [Dunk?], the horse is lame."))
        #expect(input.contains("[1:05] speaker_1: Then we walk to Ashford."))
        #expect(input.contains("- Egg → إيغ (male, confirmed, voice speaker_0)"))
        #expect(input.contains("- Ashford → آشفورد"))
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.map { $0["type"] as? String } == ["web_search"])
        #expect(body["max_tool_calls"] as? Int == 3)
        let format = try #require((body["text"] as? [String: Any])?["format"] as? [String: Any])
        #expect(format["strict"] as? Bool == true)
        #expect((body["instructions"] as? String)?.contains("Arabic") == true)
        #expect((body["instructions"] as? String)?.contains("who talks to whom") == true)
        #expect((body["instructions"] as? String)?.contains("the scenes and every note in English") == true)
        let schema = try #require(format["schema"] as? [String: Any])
        #expect((schema["required"] as? [String]) == ["people", "plot", "scenes", "terms"])
        // Without a title there is nothing to look up.
        let untitled = OpenAIBriefBuilder.body(for: request(work: nil))
        #expect(untitled["tools"] == nil)
        #expect((untitled["instructions"] as? String)?.contains("search the web") == false)
    }

    @Test func answerBecomesABriefWithARowForEveryVoice() throws {
        let output = """
            {"people": [
              {"voices": ["speaker_0"], "name": "Dunk", "gender": "male", "translation": "دانك", "confidence": 0.9, "note": "Egg calls him Dunk"},
              {"voices": ["speaker_1", "speaker_0", "speaker_9"], "name": "Egg", "gender": "male", "translation": "إيغ", "confidence": 1.4, "note": ""},
              {"voices": [], "name": "Aerion", "gender": "male", "translation": "إيريون", "confidence": 0.7, "note": "Spoken about"},
              {"voices": ["speaker_7"], "name": "", "gender": "unknown", "translation": "", "confidence": 0.1, "note": ""}
            ],
            "terms": [
              {"term": "Ashford Meadow", "heard_as": ["Ash for Meadow", "ashford meadow"], "translation": "مرج آشفورد", "note": "The tourney ground", "confidence": 0.8},
              {"term": " ", "heard_as": [], "translation": "", "note": "", "confidence": 0.5}
            ],
            "plot": " Dunk buries his knight and rides to Ashford. ",
            "scenes": [
              {"start_seconds": 0, "summary": "Dunk talks to his dead knight."},
              {"start_seconds": 65.4, "summary": "Egg asks Dunk to take him on."},
              {"start_seconds": 90, "summary": " "}
            ]}
            """
        let brief = try OpenAIBriefBuilder.brief(from: CloudProviderTests.openAIResponse(output), request: request())
        #expect(brief.targetLanguage == "ar")
        #expect(brief.work == "A Knight of the Seven Kingdoms S01E01")
        #expect(!brief.isConfirmed)
        // A voice goes to the first person named with it; made-up voices go; a voice nobody named gets a row.
        #expect(brief.people.map(\.name) == ["Dunk", "Egg", "Aerion", ""])
        #expect(brief.people.map(\.voices) == [["speaker_0"], ["speaker_1"], [], ["speaker_2"]])
        #expect(brief.people[0].translatedName == "دانك")
        #expect(brief.people[1].confidence == 1)
        #expect(brief.people[3].confidence == 0)
        #expect(brief.terms.map(\.term) == ["Ashford Meadow"])
        #expect(brief.terms[0].heardAs == ["Ash for Meadow"])
        #expect(brief.terms[0].addsToGlossary)
        #expect(brief.plot == "Dunk buries his knight and rides to Ashford.")
        #expect(brief.scenes == "0:00 Dunk talks to his dead knight.\n1:05 Egg asks Dunk to take him on.")
    }

    @Test func aRefusedOrCutOffAnswerIsAnError() throws {
        let refused = try JSONSerialization.data(withJSONObject: [
            "status": "completed", "output": [["type": "message", "content": [["type": "refusal", "refusal": "No"]]]],
        ])
        #expect(throws: AIError.declined) { try OpenAIBriefBuilder.brief(from: refused, request: request()) }
        let cut = try CloudProviderTests.openAIResponse("{\"people\": [", status: "incomplete")
        #expect(throws: AIError.cutOff) { try OpenAIBriefBuilder.brief(from: cut, request: request()) }
    }
}

import Foundation
import SubtitleCore
import Testing
@testable import AITools

struct ClaudeHelpersTests {
    static let haiku = AISettings.HelperModel.haiku.rawValue

    static func answer(_ text: String, stopReason: String = "end_turn") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "content": [["type": "thinking", "thinking": ""], ["type": "text", "text": text]], "stop_reason": stopReason,
        ])
    }

    @Test func briefIsAskedForInJSONWithTheWebNotesAndNoSearchTool() throws {
        let request = EpisodeBriefBuilderTests().request()
        let body = ClaudeBriefBuilder.body(for: request, webNotes: "Dunk (Peter Claffey), male.", model: Self.haiku, effort: .medium)
        #expect(body["model"] as? String == "claude-haiku-5-5")
        #expect(body["fallbacks"] == nil, "Haiku has no model to fall back to")
        #expect(body["max_tokens"] as? Int == 32000, "room for Haiku's thinking on a whole episode")
        #expect(body["tools"] == nil, "search results come with citations, which a JSON answer cannot carry")
        let config = try #require(body["output_config"] as? [String: Any])
        #expect(config["effort"] as? String == "medium")
        #expect((config["format"] as? [String: Any])?["type"] as? String == "json_schema")
        let system = try #require((body["system"] as? [[String: Any]])?.first?["text"] as? String)
        #expect(system.contains("who talks to whom"))
        #expect(!system.contains("search the web"))
        let user = try #require((body["messages"] as? [[String: Any]])?.first?["content"] as? String)
        #expect(user.contains("[0:00] speaker_0: [Dunk?], the horse is lame."))
        #expect(user.contains("Notes from a web search for the show"))
        #expect(user.contains("Dunk (Peter Claffey), male."))
    }

    @Test func theSearchRequestIsCappedAndDated() throws {
        let date = try Date("2026-10-07T12:00:00Z", strategy: .iso8601)
        let body = ClaudeBriefBuilder.searchBody(for: EpisodeBriefBuilderTests().request(), model: Self.haiku, today: date)
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.first?["type"] as? String == "web_search_20250305")
        #expect(tools.first?["max_uses"] as? Int == 3)
        #expect(body["output_config"].flatMap { ($0 as? [String: Any])?["format"] } == nil)
        #expect((body["system"] as? String)?.contains("The current date is 2026-10-07") == true)
        let user = try #require((body["messages"] as? [[String: Any]])?.first?["content"] as? String)
        #expect(user.contains("A Knight of the Seven Kingdoms S01E01"))
    }

    @Test func briefAnswerIsReadLikeLunas() throws {
        let json = #"{"people": [{"voices": ["speaker_1"], "name": "Dunk", "gender": "male", "translation": "دنك", "confidence": 0.9, "note": ""}], "terms": [], "plot": "Dunk rides.", "scenes": []}"#
        let output = try ClaudeMessages.output(OpenAIBriefBuilder.Output.self, from: Self.answer(json), what: "brief")
        let brief = OpenAIBriefBuilder.brief(from: output, request: EpisodeBriefBuilderTests().request())
        #expect(brief.people.first { $0.voices == ["speaker_1"] }?.name == "Dunk")
        #expect(brief.plot == "Dunk rides.")
        #expect(throws: AIError.declined) { try ClaudeMessages.output(OpenAIBriefBuilder.Output.self, from: Self.answer("", stopReason: "refusal"), what: "brief") }
        #expect(throws: AIError.cutOff) { try ClaudeMessages.output(OpenAIBriefBuilder.Output.self, from: Self.answer("{", stopReason: "max_tokens"), what: "brief") }
    }

    @Test func sceneFramesGoAsClaudeImagesUnderTheirTimes() throws {
        let body = ClaudeSceneDescriber.body(for: SceneDescriberTests().request(), model: Self.haiku, effort: .high)
        #expect((body["output_config"] as? [String: Any])?["effort"] as? String == "high")
        let content = try #require((body["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
        #expect(content.map { $0["type"] as? String } == ["text", "text", "image", "text", "image"])
        #expect((content[0]["text"] as? String)?.contains("[12:02] Dunk, speaker_1: I wish to enter") == true)
        #expect(content[3]["text"] as? String == "Frame 2, at 12:12 (the scene's widest view), while someone says “Yes.”:")
        let source = try #require(content[4]["source"] as? [String: Any])
        #expect(source["media_type"] as? String == "image/jpeg")
        #expect(source["data"] as? String == Data([0xFF, 0xD8, 2]).base64EncodedString())
    }

    @Test func eachReviewBatchCachesTheRulesAndTranscriptThenSendsItsLines() throws {
        let request = ScriptReviewerTests().request()
        let body = ClaudeScriptReviewer.body(for: request, checking: 2..<4, model: Self.haiku, effort: .medium)
        let system = try #require((body["system"] as? [[String: Any]])?.first)
        #expect((system["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
        #expect((system["text"] as? String)?.contains("Ser [Aron?] will ride.") == true, "the whole transcript")
        let user = try #require((body["messages"] as? [[String: Any]])?.first?["content"] as? String)
        #expect(user.contains("L1 | [1:00] speaker_0: Then we walk\\nto Ashford."))
        #expect(!user.contains("the horse is lame"))
    }

    @Test func eachHelperModelNeedsItsOwnKey() {
        #expect(AISettings.HelperModel.haiku.apiKeyProvider == .anthropic)
        #expect(AISettings.HelperModel.luna.apiKeyProvider == .openAI)
        #expect(AISettings.HelperModel.haiku.priceFactor == 1)
        #expect(AISettings.HelperModel.haiku.setupHint.contains("Anthropic API key"))
        #expect(AISettings.step("claude-haiku-5-5/low", default: AISettings.Step()) == AISettings.Step(model: .haiku, effort: .low))
    }
}

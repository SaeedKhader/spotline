import Foundation
import MediaAnalysis
import SubtitleCore
import Testing
@testable import AITools

struct CloudProviderTests {
    func request(target: String = "ar", cast: [CastMember] = []) -> TranslationRequest {
        TranslationRequest(
            lines: [
                .init(cueID: UUID(), source: "You are busy.", start: .zero, end: MediaTime(value: 2, timescale: 1), voices: ["speaker_1"]),
                .init(cueID: UUID(), source: "Winterfell is cold.", start: MediaTime(value: 3, timescale: 1), end: MediaTime(value: 4, timescale: 1)),
            ],
            sourceLanguage: "en", targetLanguage: target, glossary: [("Winterfell", "وينترفيل", "place")],
            maxCharactersPerLine: 42, maxLines: 2, cast: cast
        )
    }

    @Test func claudeRequestAsksForStructuredOutput() throws {
        let cast = [CastMember(name: "Beth", gender: .female, isConfirmed: true, voices: ["speaker_1"]), CastMember(name: "Morty", gender: .male)]
        let body = ClaudeTranslator.body(for: request(cast: cast))
        #expect(body["model"] as? String == "claude-opus-5-5")
        #expect(ClaudeTranslator.body(for: request(), model: ClaudeTranslator.sonnetModel)["model"] as? String == "claude-sonnet-5-5")
        #expect(body["fallbacks"] as? String == "default")
        let config = try #require(body["output_config"] as? [String: Any])
        let format = try #require(config["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        let schema = try #require(format["schema"] as? [String: Any])
        #expect((schema["required"] as? [String])?.sorted() == ["cast", "translations"])
        let user = try #require((body["messages"] as? [[String: Any]])?.first?["content"] as? String)
        #expect(user.contains("Winterfell → وينترفيل (place)"))
        #expect(user.contains("L1 | 0.0s | speaker_1 | You are busy."))
        #expect(user.contains("L2 | 3.0s | ? | Winterfell is cold."))
        #expect(user.contains("- Beth (female, confirmed, voice speaker_1)"))
        #expect(user.contains("- Morty (male)"))
        #expect((body["system"] as? String)?.contains("variants") == true, "Arabic asks for flags and variants")
        let english = ClaudeTranslator.body(for: request(target: "en", cast: cast))
        #expect((english["system"] as? String)?.contains("variants") == false)
        #expect((english["messages"] as? [[String: Any]])?.first?["content"] as? String == nil
            || !(((english["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? "").contains("Known people"))
        #expect(try JSONSerialization.data(withJSONObject: body).count > 0)
    }

    static func response(_ output: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": output]], "stop_reason": "end_turn"])
    }

    @Test func claudeAnswerMapsBackToCuesWithFlagsAndCast() throws {
        let request = request()
        let output = """
            {"translations": [
              {"id": "L1", "text": "انتِ مشغولة.", "reasons": ["listener"], "confidence": 0.55, "note": "Morty is talking to Beth",
               "variants": [
                 {"text": "انت مشغول.", "speaker": "Morty", "speaker_gender": "male", "listeners": ["Jerry"], "listener_gender": "male", "listener_count": "one"},
                 {"text": "انتِ مشغولة.", "speaker": "Morty", "speaker_gender": "male", "listeners": ["Beth"], "listener_gender": "female", "listener_count": "one"},
                 {"text": "انتم مشغولون.", "speaker": "", "speaker_gender": "unknown", "listeners": [], "listener_gender": "mixed", "listener_count": "many"}]},
              {"id": "L2", "text": "وينترفيل باردة.", "reasons": [], "confidence": 1, "note": "", "variants": []}
            ],
            "cast": [{"name": "Beth", "gender": "female", "voices": []}, {"name": "Morty", "gender": "male", "voices": ["speaker_1"]}]}
            """
        let batch = try ClaudeTranslator.translations(from: Self.response(output), request: request)
        #expect(batch.translations.count == 2)
        let first = batch.translations[0]
        #expect(first.cueID == request.lines[0].cueID)
        let flag = try #require(first.flag)
        #expect(flag.reasons == [.listener])
        #expect(flag.confidence == 0.55)
        #expect(flag.note == "Morty is talking to Beth")
        // The recommendation (the text) comes first, whatever order the variants came in.
        #expect(flag.variants.map(\.listeners) == [["Beth"], ["Jerry"], []])
        #expect(flag.chosen == 0 && first.text == "انتِ مشغولة.")
        #expect(flag.variants[0].speaker == "Morty" && flag.variants[2].speaker == nil)
        #expect(flag.variants[2].listenerGender == .mixed && flag.variants[2].listenerCount == .many)
        #expect(batch.translations[1].flag == nil, "No reasons, no flag")
        #expect(batch.cast.map(\.name) == ["Beth", "Morty"])
        #expect(batch.cast[1].voices == ["speaker_1"] && !batch.cast[1].isConfirmed)
    }

    @Test func claudePicksThatContradictConfirmedPeopleAreReranked() throws {
        // The user already said Beth is a man (say): the variant for a woman Beth goes last.
        let request = request(cast: [CastMember(name: "Beth", gender: .male, isConfirmed: true)])
        let output = """
            {"translations": [
              {"id": "L1", "text": "انتِ مشغولة.", "reasons": ["listener"], "confidence": 0.6, "note": "",
               "variants": [
                 {"text": "انتِ مشغولة.", "speaker": "", "speaker_gender": "unknown", "listeners": ["Beth"], "listener_gender": "female", "listener_count": "one"},
                 {"text": "انت مشغول.", "speaker": "", "speaker_gender": "unknown", "listeners": ["Beth"], "listener_gender": "male", "listener_count": "one"}]}
            ], "cast": []}
            """
        let batch = try ClaudeTranslator.translations(from: Self.response(output), request: request)
        #expect(batch.translations[0].text == "انت مشغول.")
        #expect(batch.translations[0].flag?.isResolved == true, "Only one variant fits")
    }

    @Test func aFlagNeedsTwoDifferentWordings() throws {
        let output = """
            {"translations": [{"id": "L1", "text": "مرحبا.", "reasons": ["listener"], "confidence": 0.5, "note": "",
               "variants": [{"text": "مرحبا.", "speaker": "", "speaker_gender": "unknown", "listeners": [], "listener_gender": "male", "listener_count": "one"}]}],
             "cast": []}
            """
        let batch = try ClaudeTranslator.translations(from: Self.response(output), request: request())
        #expect(batch.translations[0].flag == nil)
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

/// Answers Claude requests like the API would: every line translated, except
/// that lines with "SKIP" are left out and a request with "REFUSE" in it is declined.
final class FakeClaude: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests = 0
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.requests += 1 }
        var body = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let prompt = ((json?["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
        let lines = prompt.split(separator: "\n").map(String.init).filter { $0.hasPrefix("L") && $0.contains(" | ") }
        var answer: [String: Any]
        if lines.contains(where: { $0.contains("REFUSE") }) {
            answer = ["content": [], "stop_reason": "refusal"]
        } else {
            let items = lines.filter { !$0.contains("SKIP") }.map { line -> [String: Any] in
                let parts = line.components(separatedBy: " | ")
                return ["id": parts[0], "text": "[ar] " + parts[3]]
            }
            let output = try! JSONSerialization.data(withJSONObject: ["translations": items])
            answer = ["content": [["type": "text", "text": String(decoding: output, as: UTF8.self)]], "stop_reason": "end_turn"]
        }
        let data = try! JSONSerialization.data(withJSONObject: answer)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct ClaudeRetryTests {
    @Test func linesLeftOutOrDeclinedAreRetriedAlone() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeClaude.self]
        let translator = ClaudeTranslator(apiKey: "test", session: URLSession(configuration: configuration))
        let sources = ["One.", "SKIP two.", "Three.", "REFUSE four.", "Five.", "Six."]
        let request = TranslationRequest(
            lines: sources.enumerated().map { index, text in
                .init(cueID: UUID(), source: text, start: MediaTime(value: Int64(index), timescale: 1), end: MediaTime(value: Int64(index) + 1, timescale: 1))
            },
            sourceLanguage: "en", targetLanguage: "en"
        )
        FakeClaude.lock.withLock { FakeClaude.requests = 0 }
        let (batch, skipped) = try await translator.translateLines(request)
        #expect(batch.translations.map(\.text) == ["[ar] One.", "[ar] Three.", "[ar] Five.", "[ar] Six."])
        #expect(skipped.map(\.source) == ["SKIP two.", "REFUSE four."])
        #expect(FakeClaude.lock.withLock { FakeClaude.requests } < 12, "Retries stop at single lines")
    }
}

import Foundation
import SubtitleCore
import Testing
@testable import AITools

struct ScriptReviewerTests {
    let ids = (0..<4).map { _ in UUID() }

    func request() -> ScriptReviewRequest {
        let texts = ["Dunk, the horse is lame.", "Ser Aron will ride.", "Then we walk\nto Ashford.", "Ser, a word."]
        let lines = texts.enumerated().map { index, text in
            ScriptReviewRequest.Line(
                cueID: ids[index], start: MediaTime(value: Int64(index * 30), timescale: 1), voices: ["speaker_\(index % 2)"], text: text,
                unsureWords: index == 1 ? ["Aron"] : []
            )
        }
        let brief = EpisodeBrief(
            people: [EpisodeBrief.Person(voices: ["speaker_0"], name: "Dunk", gender: .male), EpisodeBrief.Person(voices: [], name: "Arlan")],
            terms: [EpisodeBrief.Term(term: "Ashford", heardAs: ["Ash ford"], note: "A town")],
            plot: "Dunk rides to Ashford.", targetLanguage: "ar", work: "A Knight of the Seven Kingdoms S01E01", isConfirmed: true
        )
        return ScriptReviewRequest(lines: lines, language: "en", brief: brief)
    }

    @Test func eachBatchHasTheBriefAndWholeTranscriptThenItsLines() throws {
        let body = OpenAIScriptReviewer.body(for: request(), checking: 2..<4)
        #expect(body["model"] as? String == "gpt-6-luna")
        #expect(body["store"] as? Bool == false)
        let instructions = try #require(body["instructions"] as? String)
        #expect(instructions.contains("for A Knight of the Seven Kingdoms S01E01"))
        #expect(instructions.contains("- Dunk (male, voice speaker_0)"))
        #expect(instructions.contains("- Arlan (unknown, does not speak)"))
        #expect(instructions.contains("- Ashford (heard as Ash ford): A town"))
        #expect(instructions.contains("Plot: Dunk rides to Ashford."))
        // The whole transcript, with unsure words marked, in every batch.
        #expect(instructions.contains("[0:30] speaker_1: Ser [Aron?] will ride."))
        let input = try #require(body["input"] as? String)
        #expect(input.contains("L1 | [1:00] speaker_0: Then we walk\\nto Ashford."))
        #expect(input.contains("L2 | [1:30] speaker_1: Ser, a word."))
        #expect(!input.contains("L3"))
    }

    @Test func findingsMapBackToTheirCues() throws {
        let output = """
            {"findings": [
              {"id": "L1", "words": ["Aron"], "reason": "The brief names Arlan",
               "fixes": [{"text": "Ser Aron will ride.", "confidence": 0.9}, {"text": "Ser Arlan will ride.", "confidence": 0.8},
                         {"text": "Ser Arlan will ride.", "confidence": 0.5}, {"text": "Ser Harlan will ride.", "confidence": 1.3},
                         {"text": "Sir Arlan will ride.", "confidence": 0.3}, {"text": "Ser Alan will ride.", "confidence": 0.2}]},
              {"id": "L2", "words": ["Ash"], "reason": "", "fixes": [{"text": "Then we walk\\\\nto Ashford!", "confidence": 0.6}]},
              {"id": "L3", "words": [], "reason": "Out of range", "fixes": [{"text": "x", "confidence": 1}]},
              {"id": "L0", "words": [], "reason": "", "fixes": [{"text": "x", "confidence": 1}]},
              {"id": "L2x", "words": [], "reason": "", "fixes": []}
            ]}
            """
        let findings = try OpenAIScriptReviewer.findings(
            from: CloudProviderTests.openAIResponse(output), request: request(), checking: 1..<3
        )
        #expect(Set(findings.keys) == [ids[1], ids[2]])
        let aron = try #require(findings[ids[1]])
        // The line unchanged and repeats go; most likely first, at most three.
        #expect(aron.fixes.map(\.text) == ["Ser Harlan will ride.", "Ser Arlan will ride.", "Sir Arlan will ride."])
        #expect(aron.fixes[0].confidence == 1)
        #expect(aron.original == "Ser Aron will ride.")
        #expect(aron.words == ["Aron"])
        #expect(aron.tried == nil)
        #expect(findings[ids[2]]?.fixes.first?.text == "Then we walk\nto Ashford!")
    }

    @Test func eachBatchIsItsOwnRequest() async throws {
        final class Recorder: URLProtocol, @unchecked Sendable {
            nonisolated(unsafe) static var inputs: [String] = []
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                var body = request.httpBody
                if body == nil, let stream = request.httpBodyStream {
                    stream.open()
                    var data = Data()
                    var buffer = [UInt8](repeating: 0, count: 65536)
                    while stream.hasBytesAvailable {
                        let read = stream.read(&buffer, maxLength: buffer.count)
                        if read <= 0 { break }
                        data.append(buffer, count: read)
                    }
                    body = data
                }
                let json = (try? JSONSerialization.jsonObject(with: body ?? Data())) as? [String: Any]
                Self.inputs.append(json?["input"] as? String ?? "")
                let answer = try! CloudProviderTests.openAIResponse(#"{"findings": []}"#)
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: answer)
                client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {}
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Recorder.self]
        var reviewer = OpenAIScriptReviewer(apiKey: "test", session: URLSession(configuration: configuration))
        reviewer.batchSize = 3
        let progress = ProgressLog()
        let findings = try await reviewer.review(request()) { done, total in progress.add(done, total) }
        #expect(findings.isEmpty)
        #expect(Recorder.inputs.count == 2)
        #expect(Recorder.inputs.last?.contains("L1 | [1:30]") == true)
        #expect(progress.values == [[0, 4], [3, 4], [4, 4]])
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [[Int]] = []
    var values: [[Int]] { lock.withLock { log } }
    func add(_ done: Int, _ total: Int) { lock.withLock { log.append([done, total]) } }
}

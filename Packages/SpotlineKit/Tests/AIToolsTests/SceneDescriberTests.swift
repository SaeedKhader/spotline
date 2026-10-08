import Foundation
import SubtitleCore
import Testing
@testable import AITools

struct SceneDescriberTests {
    static func time(_ seconds: Double) -> MediaTime { MediaTime(seconds: seconds) }

    func request(start: Double = 722) -> SceneRequest {
        SceneRequest(
            start: Self.time(start),
            frames: [
                SceneRequest.Frame(time: Self.time(728), jpeg: Data([0xFF, 0xD8, 1])),
                SceneRequest.Frame(time: Self.time(732), jpeg: Data([0xFF, 0xD8, 2]), isWidest: true),
            ],
            lines: [
                SceneRequest.Line(start: Self.time(722), voices: ["speaker_1"], name: "Dunk", text: "I wish to enter\nthe lists."),
                SceneRequest.Line(start: Self.time(726), voices: ["speaker_4"], text: "Do you?"),
                SceneRequest.Line(start: Self.time(729), text: "Yes."),
            ],
            people: [SceneRequest.Person(name: "Dunk", gender: .male), SceneRequest.Person(name: "Egg")],
            work: "A Knight of the Seven Kingdoms S01E01"
        )
    }

    @Test func requestSendsTheLinesThenEachFrameUnderItsTime() throws {
        let body = OpenAISceneDescriber.body(for: request())
        #expect(body["model"] as? String == "gpt-6-luna")
        #expect(body["store"] as? Bool == false, "OpenAI keeps no copy")
        #expect((body["reasoning"] as? [String: Any])?["effort"] as? String == "high")
        let format = try #require((body["text"] as? [String: Any])?["format"] as? [String: Any])
        #expect(format["strict"] as? Bool == true)
        #expect(body["tools"] == nil, "No web search: it reports what the frames show")

        let input = try #require(body["input"] as? [[String: Any]])
        #expect(input.count == 1 && input[0]["role"] as? String == "user")
        let content = try #require(input[0]["content"] as? [[String: Any]])
        #expect(content.map { $0["type"] as? String } == ["input_text", "input_text", "input_image", "input_text", "input_image"])
        let text = try #require(content[0]["text"] as? String)
        #expect(text == """
            What is being watched (from the file name): A Knight of the Seven Kingdoms S01E01

            People in the episode:
            - Dunk (male)
            - Egg

            The scene's lines (time, who speaks, line):
            [12:02] Dunk, speaker_1: I wish to enter\\nthe lists.
            [12:06] speaker_4: Do you?
            [12:09] ?: Yes.

            The frames follow, in time order.
            """)
        // Each frame says which line was being said when it was taken.
        #expect(content[1]["text"] as? String == "Frame 1, at 12:08, while speaker_4 says “Do you?”:")
        #expect(content[2]["image_url"] as? String == "data:image/jpeg;base64," + Data([0xFF, 0xD8, 1]).base64EncodedString())
        #expect(content[3]["text"] as? String == "Frame 2, at 12:12 (the scene's widest view), while someone says “Yes.”:")
        #expect(OpenAISceneDescriber.instructions.contains("Never name anyone from their face alone"))
    }

    @Test func answerBecomesANoteAndNamesTheBriefDoesNotHaveAreDropped() throws {
        let answer = """
            {"summary": "A candle-lit office.\\nDunk stands before a man at a desk; they talk alone.",
             "people": [{"description": "a tall young man in a grey tunic", "name": "dunk"},
                        {"description": "an older man in black at a desk", "name": "Plummer"},
                        {"description": " ", "name": ""}],
             "on_screen_text": ["ASHFORD", " "]}
            """
        let note = try OpenAISceneDescriber.note(from: CloudProviderTests.openAIResponse(answer), request: request())
        #expect(note.start == Self.time(722))
        #expect(note.people == [
            SceneNote.Person(id: "P1", description: "a tall young man in a grey tunic", name: "Dunk"),
            SceneNote.Person(id: "P2", description: "an older man in black at a desk"),
        ])
        #expect(note.onScreenText == ["ASHFORD"])
        #expect(note.line == "12:02 A candle-lit office. Dunk stands before a man at a desk; they talk alone. "
            + "In view: Dunk (a tall young man in a grey tunic); an older man in black at a desk. On screen: “ASHFORD”.")
    }

    @Test func peopleCarryTheirVoiceAndEachFrameSaysWhoIsInView() throws {
        let answer = """
            {"summary": "An office; a young man talks to a man at a desk.",
             "people": [{"id": "A", "description": "a tall young man", "name": "", "voice": "speaker_1"},
                        {"id": "B", "description": "an older man at a desk", "name": "", "voice": "speaker_9"}],
             "on_screen_text": [],
             "frames": [{"frame": 2, "in_view": ["A", "B", "Z"], "others": 3}, {"frame": 1, "in_view": ["B"], "others": 0},
                        {"frame": 7, "in_view": ["A"], "others": 0}]}
            """
        let note = try OpenAISceneDescriber.note(from: CloudProviderTests.openAIResponse(answer), request: request())
        // A voice no line of the scene has is dropped, and so are frames and ids that do not exist.
        #expect(note.people.map(\.voice) == ["speaker_1", ""])
        #expect(note.frames == [
            SceneNote.InView(time: Self.time(728), people: ["B"]), SceneNote.InView(time: Self.time(732), people: ["A", "B"], others: 3),
        ])
        #expect(note.line == "12:02 An office; a young man talks to a man at a desk. "
            + "In view: A: a tall young man, voice speaker_1; B: an older man at a desk. By frame: 12:08 B; 12:12 A, B and 3 others.")
        #expect(OpenAISceneDescriber.instructions.contains("one frame is not enough"))
    }

    @Test func aNoteWithNobodyInViewIsJustItsSummary() {
        #expect(SceneNote(start: Self.time(65), summary: "An empty road at dusk.").line == "1:05 An empty road at dusk.")
    }

    @Test func aRefusedOrCutOffAnswerIsAnError() throws {
        let refused = try JSONSerialization.data(withJSONObject: [
            "status": "completed", "output": [["type": "message", "content": [["type": "refusal", "refusal": "No"]]]],
        ])
        #expect(throws: AIError.declined) { try OpenAISceneDescriber.note(from: refused, request: request()) }
        let cut = try CloudProviderTests.openAIResponse("{\"summary\": \"", status: "incomplete")
        #expect(throws: AIError.cutOff) { try OpenAISceneDescriber.note(from: cut, request: request()) }
    }

    /// Declines the scene that starts at 20 s and fails on the one at 99 s.
    struct Picky: SceneDescriber {
        var name: String { "Picky" }
        func describe(_ request: SceneRequest) async throws -> SceneNote {
            if request.start == SceneDescriberTests.time(20) { throw AIError.declined }
            if request.start == SceneDescriberTests.time(99) { throw AIError.provider("Down") }
            return SceneNote(start: request.start, summary: "Scene at \(Int(request.start.seconds))")
        }
    }

    @Test func everySceneIsDescribedInOrderAndADeclinedOneIsLeftOut() async throws {
        let requests = [10.0, 20, 30, 40, 50, 60].map { request(start: $0) }
        let counted = Counter()
        let notes = try await Picky().describe(requests, atOnce: 2) { done, total in counted.add(done, total) }
        #expect(notes.map(\.summary) == ["Scene at 10", "Scene at 30", "Scene at 40", "Scene at 50", "Scene at 60"])
        #expect(counted.last == 6 && counted.total == 6)
    }

    @Test func anyOtherFailureStopsItAll() async {
        await #expect(throws: AIError.provider("Down")) {
            _ = try await Picky().describe([request(start: 10), request(start: 99)]) { _, _ in }
        }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var last = 0
        private(set) var total = 0
        func add(_ done: Int, _ total: Int) {
            lock.withLock {
                last = max(last, done)
                self.total = total
            }
        }
    }
}

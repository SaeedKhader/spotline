import Foundation
import SubtitleCore

/// What a scene describer gets: the few frames picked for one scene
/// (`SceneFramePicker`), the scene's lines with who speaks them, and who the
/// episode brief says each voice is.
public struct SceneRequest: Sendable, Equatable {
    public struct Frame: Sendable, Equatable {
        public var time: MediaTime
        public var jpeg: Data
        /// The scene's widest view, the one with the most people in it.
        public var isWidest: Bool

        public init(time: MediaTime, jpeg: Data, isWidest: Bool = false) {
            self.time = time
            self.jpeg = jpeg
            self.isWidest = isWidest
        }
    }

    public struct Line: Sendable, Equatable {
        public var start: MediaTime
        /// The transcriber's labels for who says it ("speaker_0").
        public var voices: [String]
        /// Who the brief says that is, when it does.
        public var name: String?
        public var text: String

        public init(start: MediaTime, voices: [String] = [], name: String? = nil, text: String) {
            self.start = start
            self.voices = voices
            self.name = name
            self.text = text
        }
    }

    public struct Person: Sendable, Equatable {
        public var name: String
        public var gender: Gender

        public init(name: String, gender: Gender = .unknown) {
            self.name = name
            self.gender = gender
        }
    }

    public var start: MediaTime
    public var frames: [Frame]
    public var lines: [Line]
    /// The people the brief names.
    public var people: [Person]
    /// "A Knight of the Seven Kingdoms S01E01", nil when the file name says nothing.
    public var work: String?

    public init(start: MediaTime, frames: [Frame], lines: [Line], people: [Person] = [], work: String? = nil) {
        self.start = start
        self.frames = frames
        self.lines = lines
        self.people = people
        self.work = work
    }
}

/// What the frames of one scene show.
public struct SceneNote: Sendable, Equatable {
    public struct Person: Sendable, Equatable {
        /// "a tall young man in a grey tunic".
        public var description: String
        /// Who that is, when the lines make it clear; else empty.
        public var name: String

        public init(description: String, name: String = "") {
            self.description = description
            self.name = name
        }
    }

    public var start: MediaTime
    /// Where it is and who is talking to whom, in a sentence or two.
    public var summary: String
    public var people: [Person]
    public var onScreenText: [String]

    public init(start: MediaTime, summary: String, people: [Person] = [], onScreenText: [String] = []) {
        self.start = start
        self.summary = summary
        self.people = people
        self.onScreenText = onScreenText
    }

    /// The note as one line of the brief: "12:02 Dunk stands before the steward's desk. In view: Dunk (a tall young man), …".
    public var line: String {
        let seconds = max(0, Int(start.seconds))
        var text = String(format: "%d:%02d ", seconds / 60, seconds % 60) + summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let seen = people.compactMap { person -> String? in
            let description = person.description.trimmingCharacters(in: .whitespaces)
            let name = person.name.trimmingCharacters(in: .whitespaces)
            if name.isEmpty { return description.isEmpty ? nil : description }
            return description.isEmpty ? name : "\(name) (\(description))"
        }
        if !seen.isEmpty { text += " In view: " + seen.joined(separator: "; ") + "." }
        let written = onScreenText.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !written.isEmpty { text += " On screen: " + written.map { "“\($0)”" }.joined(separator: ", ") + "." }
        return text.replacing(/\s*\n\s*/, with: " ")
    }
}

/// Says what the picked frames of a scene show: who is there, how many, who faces whom.
public protocol SceneDescriber: Sendable {
    /// "OpenAI GPT-6 Luna (cloud)".
    var name: String { get }
    func describe(_ request: SceneRequest) async throws -> SceneNote
}

extension SceneDescriber {
    /// Describes every scene, a few at a time, in order. A scene the model declines
    /// or cannot answer gets no note; anything else that goes wrong stops it all.
    public func describe(
        _ requests: [SceneRequest], atOnce: Int = 4, progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void
    ) async throws -> [SceneNote] {
        progress(0, requests.count)
        var notes = [SceneNote?](repeating: nil, count: requests.count)
        try await withThrowingTaskGroup(of: (Int, SceneNote?).self) { group in
            var next = 0
            var done = 0
            func add() {
                guard next < requests.count else { return }
                let index = next
                next += 1
                group.addTask {
                    do { return (index, try await describe(requests[index])) } catch AIError.declined, AIError.cutOff { return (index, nil) }
                }
            }
            for _ in 0..<max(atOnce, 1) { add() }
            while let (index, note) = try await group.next() {
                notes[index] = note
                done += 1
                progress(done, requests.count)
                add()
            }
        }
        return notes.compactMap { $0 }
    }
}

// MARK: - OpenAI

/// Describes a scene with GPT-6 Luna (the Responses API), one request a scene: its
/// frames as images, each with its time, then its lines. Luna reports what it sees
/// and never words a translation. A frame of 768×384 is about 350 input tokens, so
/// an episode's 30 to 60 scenes cost a few cents.
public struct OpenAISceneDescriber: SceneDescriber {
    public var name: String { model == Self.defaultModel ? "OpenAI GPT-6 Luna (cloud)" : "OpenAI \(model) (cloud)" }
    public static let defaultModel = OpenAITranslator.defaultModel
    let model: String
    let effort: AISettings.ReasoningEffort
    let apiKey: String
    let http: HTTPClient
    var endpoint = URL(string: "https://api.openai.com/v1/responses")!

    public init(
        apiKey: String, model: String = OpenAISceneDescriber.defaultModel, effort: AISettings.ReasoningEffort = .high,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.effort = effort
        http = HTTPClient(session: session)
    }

    public func describe(_ request: SceneRequest) async throws -> SceneNote {
        var urlRequest = URLRequest(url: endpoint, timeoutInterval: 300)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: Self.body(for: request, model: model, effort: effort))
        let data = try await http.send(urlRequest)
        return try Self.note(from: data, request: request)
    }

    /// The Responses API request: the frames and lines as one user message, strict
    /// structured output. `store` is off, so OpenAI keeps no copy.
    static func body(for request: SceneRequest, model: String = defaultModel, effort: AISettings.ReasoningEffort = .high) -> [String: Any] {
        [
            "model": model,
            "instructions": instructions,
            "input": [["role": "user", "content": content(for: request)]],
            "max_output_tokens": 4000,
            "reasoning": ["effort": effort.rawValue],
            "store": false,
            "text": ["format": ["type": "json_schema", "name": "scene_note", "strict": true, "schema": outputSchema]],
        ]
    }

    private static func object(_ properties: [String: Any]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": properties.keys.sorted(), "additionalProperties": false]
    }

    static var outputSchema: [String: Any] {
        let string: [String: Any] = ["type": "string"]
        let person = object(["description": string, "name": string])
        return object([
            "summary": string, "people": ["type": "array", "items": person], "on_screen_text": ["type": "array", "items": string],
        ])
    }

    static let instructions = """
        You help the subtitle translators of a film or TV episode. You get a few frames from one scene, each with \
        the time it was taken, and the scene's lines with their times and who says each. The translators cannot \
        see the picture: tell them what it shows that the lines do not say. Their language changes "you" and verbs \
        with the gender and number of the person spoken to, so who is there matters most.

        Report only what the frames show. When something cannot be told, say so instead of guessing.

        In "people", list each person in view once, across the frames:
        - description: what they look like in a few words, starting with man, woman, boy or girl when that is \
        clear ("a tall young man in a grey tunic", "a bald boy", "a figure in armour, face hidden").
        - name: who it is, from the list of people, only when the lines make it clear: a frame taken while a line \
        is spoken often shows who says it, but it may show who listens instead, so use a name when the frames and \
        lines agree (the same person in view each time that voice speaks, or someone addressed by name). Never name \
        anyone from their face alone. Empty when unsure.
        A crowd or a group in the background is one entry ("about a dozen onlookers, men and women").

        In "summary", say in one or two plain sentences where the scene is and who is with whom: how many people \
        take part in the talk, who faces or speaks to whom when the frames show it, and whether others are present \
        and listening. Use names where you gave them. Do not retell the dialogue.

        In "on_screen_text", copy any writing in the picture that a viewer is meant to read (a sign, a letter, a \
        caption, a title), as written. Leave out credits and watermarks. Empty when there is none.

        Write in English.
        """

    /// The user message: what is being watched, the people, the lines, then each frame under its time.
    static func content(for request: SceneRequest) -> [[String: Any]] {
        var text = ""
        if let work = request.work { text += "What is being watched (from the file name): \(work)\n\n" }
        if !request.people.isEmpty {
            text += "People in the episode:\n"
            for person in request.people {
                text += "- \(person.name)\(person.gender == .unknown ? "" : " (\(person.gender.rawValue))")\n"
            }
            text += "\n"
        }
        text += "The scene's lines (time, who speaks, line):\n"
        for line in request.lines {
            let voice = line.voices.isEmpty ? "?" : line.voices.joined(separator: " then ")
            let speaker = line.name.map { "\($0), \(voice)" } ?? voice
            text += "[\(clock(line.start))] \(speaker): \(ClaudeTranslator.sourceLine(line.text))\n"
        }
        text += "\nThe frames follow, in time order."
        var content: [[String: Any]] = [["type": "input_text", "text": text]]
        for (index, frame) in request.frames.enumerated() {
            let label = "Frame \(index + 1), at \(clock(frame.time))" + (frame.isWidest ? " (the scene's widest view):" : ":")
            content.append(["type": "input_text", "text": label])
            content.append(["type": "input_image", "image_url": "data:image/jpeg;base64," + frame.jpeg.base64EncodedString()])
        }
        return content
    }

    static func clock(_ time: MediaTime) -> String {
        let seconds = max(0, Int(time.seconds))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    struct Output: Decodable {
        struct Person: Decodable {
            var description: String?
            var name: String?
        }

        var summary: String?
        var people: [Person]?
        var on_screen_text: [String]?
    }

    static func note(from data: Data, request: SceneRequest) throws -> SceneNote {
        let response = try JSONDecoder().decode(OpenAITranslator.Response.self, from: data)
        let contents = response.output.filter { $0.type == "message" }.flatMap { $0.content ?? [] }
        if contents.contains(where: { $0.type == "refusal" }) { throw AIError.declined }
        if response.status == "incomplete" {
            throw response.incomplete_details?.reason == "content_filter" ? AIError.declined : AIError.cutOff
        }
        let texts = contents.filter { $0.type == "output_text" }.compactMap(\.text)
        guard let output = texts.reversed().lazy.compactMap({ try? JSONDecoder().decode(Output.self, from: Data($0.utf8)) }).first else {
            throw AIError.provider("OpenAI's scene description could not be read.")
        }
        return note(from: output, request: request)
    }

    /// The answer as a note: a name the brief does not have is dropped, since it was made up or read off a face.
    static func note(from output: Output, request: SceneRequest) -> SceneNote {
        let people = (output.people ?? []).compactMap { person -> SceneNote.Person? in
            let description = (person.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let said = (person.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let name = request.people.first { $0.name.caseInsensitiveCompare(said) == .orderedSame }?.name ?? ""
            guard !description.isEmpty || !name.isEmpty else { return nil }
            return SceneNote.Person(description: description, name: name)
        }
        return SceneNote(
            start: request.start, summary: (output.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines), people: people,
            onScreenText: (output.on_screen_text ?? []).filter { !$0.allSatisfy(\.isWhitespace) }
        )
    }
}

// MARK: - Scripted

/// A fixed description for tests: the frames counted, and the first person of the brief in view.
public struct ScriptedSceneDescriber: SceneDescriber {
    public var name: String { "Scripted scenes" }

    public init() {}

    public func describe(_ request: SceneRequest) async throws -> SceneNote {
        let count = request.frames.count == 1 ? "1 frame" : "\(request.frames.count) frames"
        return SceneNote(
            start: request.start, summary: "Two people talk in a room (\(count), \(request.lines.count) lines).",
            people: [SceneNote.Person(description: "a man in a lab coat", name: request.people.first?.name ?? "")]
        )
    }
}

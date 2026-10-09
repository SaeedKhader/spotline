import Foundation
import SubtitleCore

/// What a brief builder gets: the whole transcript with the transcriber's voice
/// labels, what is being watched (from the file name), and what the project knows.
public struct BriefRequest: Sendable, Equatable {
    /// One line of the transcript.
    public struct Line: Sendable, Equatable {
        public var start: MediaTime
        /// The transcriber's labels for who says it ("speaker_0"), in order.
        public var voices: [String]
        public var text: String
        /// Words the transcriber was unsure of.
        public var unsureWords: [String]

        public init(start: MediaTime, voices: [String] = [], text: String, unsureWords: [String] = []) {
            self.start = start
            self.voices = voices
            self.text = text
            self.unsureWords = unsureWords
        }
    }

    public var lines: [Line]
    public var sourceLanguage: String
    /// The language names are spelled in.
    public var targetLanguage: String
    /// "A Knight of the Seven Kingdoms (2026) S01E01 The Hedge Knight", nil when the file name says nothing.
    public var work: String?
    /// The people the project already knows.
    public var cast: [CastMember]
    /// Agreed spellings (source term, target term).
    public var spellings: [Spelling]
    /// True when the lines are a subtitle file's (their words are right) and only the
    /// voice labels come from a transcriber.
    public var isFromSubtitles = false
    /// What the video shows, scene by scene, described from a few frames of each before the brief
    /// ("12:02 A man stands before a desk. In view: …"), without names; empty when not described.
    public var sceneDescriptions = ""

    public struct Spelling: Sendable, Equatable {
        public var source: String
        public var target: String

        public init(source: String, target: String) {
            self.source = source
            self.target = target
        }
    }

    public init(
        lines: [Line], sourceLanguage: String, targetLanguage: String, work: String? = nil, cast: [CastMember] = [],
        spellings: [Spelling] = []
    ) {
        self.lines = lines
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.work = work
        self.cast = cast
        self.spellings = spellings
    }

    /// Every voice label, in the order they first speak.
    public var voices: [String] {
        var seen: [String] = []
        for line in lines { for voice in line.voices where !seen.contains(voice) { seen.append(voice) } }
        return seen
    }
}

/// Builds an episode brief: who each voice is, their gender and spellings, and the
/// show's places and terms.
public protocol EpisodeBriefBuilder: Sendable {
    /// "OpenAI GPT-6 Luna (cloud)".
    var name: String { get }
    func buildBrief(_ request: BriefRequest) async throws -> EpisodeBrief
}

// MARK: - OpenAI

/// Builds the brief with GPT-6 Luna (the Responses API) in one request: the whole
/// transcript goes up, and Luna may search the web for the show's cast and places
/// (a few searches, about a cent each) when the file name says what the show is.
/// About 4 cents an episode.
public struct OpenAIBriefBuilder: EpisodeBriefBuilder {
    public var name: String { model == Self.defaultModel ? "OpenAI GPT-6 Luna (cloud)" : "OpenAI \(model) (cloud)" }
    public static let defaultModel = OpenAITranslator.defaultModel
    let model: String
    let effort: AISettings.ReasoningEffort
    let apiKey: String
    let http: HTTPClient
    var endpoint = URL(string: "https://api.openai.com/v1/responses")!

    public init(
        apiKey: String, model: String = OpenAIBriefBuilder.defaultModel, effort: AISettings.ReasoningEffort = .medium,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.effort = effort
        http = HTTPClient(session: session)
    }

    public func buildBrief(_ request: BriefRequest) async throws -> EpisodeBrief {
        var urlRequest = URLRequest(url: endpoint, timeoutInterval: 600)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: Self.body(for: request, model: model, effort: effort))
        let data = try await http.send(urlRequest)
        return try Self.brief(from: data, request: request)
    }

    /// Searches the web gets, at most: enough for the cast list and a place or two.
    static let maxSearches = 3

    /// The Responses API request: strict structured output, and web search only when
    /// the file name names the show. `store` is off, so OpenAI keeps no copy.
    static func body(for request: BriefRequest, model: String = defaultModel, effort: AISettings.ReasoningEffort = .medium) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "instructions": instructions(for: request),
            "input": input(for: request),
            "max_output_tokens": 16000,
            "reasoning": ["effort": effort.rawValue],
            "store": false,
            "text": ["format": ["type": "json_schema", "name": "episode_brief", "strict": true, "schema": outputSchema]],
        ]
        if request.work != nil {
            body["tools"] = [["type": "web_search"]]
            body["max_tool_calls"] = maxSearches
        }
        return body
    }

    private static func object(_ properties: [String: Any]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": properties.keys.sorted(), "additionalProperties": false]
    }

    private static var string: [String: Any] { ["type": "string"] }

    /// The answer: people by voice, and terms. Every field is required, as strict outputs need.
    static var outputSchema: [String: Any] {
        let person = object([
            "voices": ["type": "array", "items": string],
            "name": string,
            "gender": ["type": "string", "enum": [Gender.male, .female, .unknown].map(\.rawValue)],
            "translation": string,
            "confidence": ["type": "number"],
            "note": string,
        ])
        let term = object([
            "term": string, "heard_as": ["type": "array", "items": string], "translation": string, "note": string,
            "confidence": ["type": "number"], "glossary": ["type": "boolean"],
        ])
        let scene = object(["start_seconds": ["type": "number"], "summary": string])
        return object([
            "people": ["type": "array", "items": person], "terms": ["type": "array", "items": term], "plot": string,
            "scenes": ["type": "array", "items": scene],
        ])
    }

    /// `searches` false when the brief is written without a web search tool (Claude's searches go first, as notes).
    static func instructions(for request: BriefRequest, searches: Bool = true) -> String {
        let source = Languages.name(request.sourceLanguage)
        let target = Languages.name(request.targetLanguage)
        let opening = request.isFromSubtitles
            ? """
                You prepare a brief for the translators of a film or TV episode, from its \(source) subtitles. The \
                subtitles' words and spellings are right: keep them. A transcriber listened to the audio and labelled \
                the voice of each line ("speaker_0") without knowing who it is; a label can be wrong on a short line, \
                and "?" means it could not tell. A name before a colon ("DUNK: ...") is the subtitles' own label of who speaks.
                """
            : """
                You prepare a brief for the subtitlers of a film or TV episode, from its automatic \(source) transcript. \
                The transcriber labelled each voice ("speaker_0") without knowing who it is, and sometimes mishears names; \
                words it was unsure of are in [brackets?].
                """
        var text = opening + """


            In "people", list who each voice is:
            - voices: the voice labels that are this person (usually one; two when the transcriber split one person).
            - name: the name as the show spells it, from the dialogue (someone addressed or introduced) and what you \
            know of the show. Correct a misheard name ("Aryan" for Aerion). Empty when nothing tells.
            - gender: male or female when the dialogue, the name or the show makes it clear, else unknown.
            - translation: the name as \(target) subtitles conventionally spell it; empty when target and source are the same language.
            - confidence: how sure you are of the name and gender, 0 to 1.
            - note: the evidence in a few words, e.g. "Egg calls him Dunk at 03:12".
            Also list people who are named but do not speak (voices empty), when they matter to the story.

            In "terms", list the places, titles, houses, made-up words and other names that recur or that the transcript \
            may have misheard, with the show's spelling (term), how the transcript heard it when differently (heard_as), \
            its \(target) spelling (translation), a short note and your confidence. Leave out everyday words. \
            List each term once, without a leading "the" ("Seven Kingdoms", not also "the Seven Kingdoms"); a shorter \
            name that means something else ("the Seven", the gods) is its own term. Set "glossary" to true for names \
            (people, places, houses, ships, horses), titles and made-up words, which keep one translation across the \
            whole show; set it to false for an everyday word with a special sense in this episode ("squire", "dragon", \
            "apple tree", "lists" for the jousting field), which the translator should know about but which can mean \
            something else in another line.

            In "plot", say what happens in the episode in 3 to 5 plain sentences, using the names.

            In "scenes", go scene by scene in time order: when it starts (start_seconds) and one line on who is \
            there, who talks to whom and about what, e.g. "Egg asks Dunk to take him on as his squire." A new scene \
            starts when the place or the people change. This tells the subtitlers who "you" is in each line.
            \(sceneRule(request))

            Write the plot, the scenes and every note in English, whatever the languages of the transcript and \
            the subtitles: only "translation" is in \(target).

            Keep every spelling the project already agreed (listed below the transcript). Do not invent people or terms.
            """
        if searches, request.work != nil {
            text += """


                You may search the web (at most \(maxSearches) searches) for the show's cast list and character names, \
                and for place names, to get spellings and genders right. Prefer the episode's own dialogue when they disagree.
                """
        }
        return text
    }

    /// With scene descriptions from the video: how to use them, and that "scenes" is the one list.
    static func sceneRule(_ request: BriefRequest) -> String {
        guard !request.sceneDescriptions.isEmpty else { return "" }
        return """
            Below the transcript are descriptions of what the video shows in each scene, from a few frames of it, \
            written without knowing anyone's name. Use them for who is there, how many are listening, who is a man or a \
            woman, and where the scene is, and name the people in them from the dialogue. Your "scenes" is the only \
            scene list the subtitlers get: start a scene where a description starts one, and say in each line who is in \
            view and who talks to whom ("Dunk and Egg at the inn's table; Dunk asks the innkeeper, a woman, for a room"). \
            Never name someone from the descriptions alone. A person in a description may say which voice they speak \
            with ("voice speaker_1"): use how they look (man, woman, boy, girl) for that voice's gender when the \
            dialogue does not settle it. "By frame" says who was in view when, which tells how many were listening.
            """
    }

    static func input(for request: BriefRequest) -> String {
        var text = ""
        if let work = request.work { text += "What is being watched (from the file name): \(work)\n\n" }
        text += request.isFromSubtitles ? "Subtitles (time, voice, line):\n" : "Transcript (time, voice, line):\n"
        for line in request.lines {
            let seconds = Int(line.start.seconds)
            let voice = line.voices.isEmpty ? "?" : line.voices.joined(separator: " then ")
            text += String(format: "[%d:%02d] ", seconds / 60, seconds % 60)
                + "\(voice): \(ClaudeTranslator.sourceLine(marking: line.unsureWords, in: line.text))\n"
        }
        if !request.sceneDescriptions.isEmpty {
            text += "\nWhat the video shows, scene by scene (time, from a few frames of each, without names):\n"
            text += request.sceneDescriptions.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        }
        if !request.cast.isEmpty {
            text += "\nPeople the project already knows:\n"
            for person in request.cast {
                var facts = [person.gender.rawValue]
                if person.isConfirmed { facts.append("confirmed") }
                if !person.voices.isEmpty { facts.append("voice \(person.voices.joined(separator: ", "))") }
                let spelling = person.translatedName.map { " → \($0)" } ?? ""
                text += "- \(person.name)\(spelling) (\(facts.joined(separator: ", ")))\n"
            }
        }
        if !request.spellings.isEmpty {
            text += "\nAgreed spellings (source → \(Languages.name(request.targetLanguage))):\n"
            for entry in request.spellings { text += "- \(entry.source) → \(entry.target)\n" }
        }
        return text
    }

    struct Output: Decodable {
        struct Person: Decodable {
            var voices: [String]?
            var name: String?
            var gender: String?
            var translation: String?
            var confidence: Double?
            var note: String?
        }

        struct Term: Decodable {
            var term: String?
            var heard_as: [String]?
            var translation: String?
            var note: String?
            var confidence: Double?
            var glossary: Bool?
        }

        struct Scene: Decodable {
            var start_seconds: Double?
            var summary: String?
        }

        var people: [Person]?
        var terms: [Term]?
        var plot: String?
        var scenes: [Scene]?
    }

    static func brief(from data: Data, request: BriefRequest) throws -> EpisodeBrief {
        let response = try JSONDecoder().decode(OpenAITranslator.Response.self, from: data)
        let contents = response.output.filter { $0.type == "message" }.flatMap { $0.content ?? [] }
        if contents.contains(where: { $0.type == "refusal" }) { throw AIError.declined }
        if response.status == "incomplete" {
            throw response.incomplete_details?.reason == "content_filter" ? AIError.declined : AIError.cutOff
        }
        let texts = contents.filter { $0.type == "output_text" }.compactMap(\.text)
        guard let output = texts.reversed().lazy.compactMap({ try? JSONDecoder().decode(Output.self, from: Data($0.utf8)) }).first else {
            throw AIError.provider("OpenAI's brief could not be read.")
        }
        return brief(from: output, request: request)
    }

    /// The answer as a brief: every voice of the transcript gets a row (unnamed when
    /// the answer skipped it), voices it made up are dropped, and a voice named twice stays with the first.
    static func brief(from output: Output, request: BriefRequest) -> EpisodeBrief {
        let known = Set(request.voices)
        var taken: Set<String> = []
        var people: [EpisodeBrief.Person] = []
        for person in output.people ?? [] {
            let voices = (person.voices ?? []).filter { known.contains($0) && !taken.contains($0) }
            taken.formUnion(voices)
            let name = (person.name ?? "").trimmingCharacters(in: .whitespaces)
            // A voice the answer made up, with nobody named, says nothing.
            guard !voices.isEmpty || !name.isEmpty else { continue }
            people.append(EpisodeBrief.Person(
                voices: voices, name: name, gender: person.gender.flatMap(Gender.init) ?? .unknown,
                translatedName: (person.translation ?? "").trimmingCharacters(in: .whitespaces),
                confidence: clamp(person.confidence), note: person.note ?? ""
            ))
        }
        let terms = (output.terms ?? []).compactMap { term -> EpisodeBrief.Term? in
            let text = (term.term ?? "").trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return EpisodeBrief.Term(
                term: text, heardAs: (term.heard_as ?? []).filter { $0.caseInsensitiveCompare(text) != .orderedSame },
                translation: (term.translation ?? "").trimmingCharacters(in: .whitespaces), note: term.note ?? "",
                confidence: clamp(term.confidence), addsToGlossary: term.glossary ?? true
            )
        }
        let scenes = (output.scenes ?? []).compactMap { scene -> String? in
            let summary = (scene.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty else { return nil }
            let seconds = max(0, Int(scene.start_seconds ?? 0))
            return String(format: "%d:%02d ", seconds / 60, seconds % 60) + summary
        }
        var brief = EpisodeBrief(
            people: people, terms: terms, plot: (output.plot ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            scenes: scenes.joined(separator: "\n"), targetLanguage: request.targetLanguage, work: request.work
        )
        brief.addMissingVoices(request.voices)
        brief.mergeDuplicateTerms()
        return brief
    }

    private static func clamp(_ confidence: Double?) -> Double {
        ((min(max(confidence ?? 0.5, 0), 1)) * 100).rounded() / 100
    }
}

// MARK: - Scripted

/// A fixed brief for UI tests: the first voice (or nobody's) is Rick (♂, 95%), the second Morty
/// (♂, 60%), and any other is left unnamed; one term, "Citadel".
public struct ScriptedBriefBuilder: EpisodeBriefBuilder {
    public var name: String { "Scripted brief" }

    public init() {}

    public func buildBrief(_ request: BriefRequest) async throws -> EpisodeBrief {
        let voices = request.voices
        var people: [EpisodeBrief.Person] = []
        people.append(EpisodeBrief.Person(voices: voices.first.map { [$0] } ?? [], name: "Rick", gender: .male, translatedName: "ريك", confidence: 0.95, note: "Named at 00:01"))
        if voices.count > 1 {
            people.append(EpisodeBrief.Person(voices: [voices[1]], name: "Morty", gender: .male, translatedName: "مورتي", confidence: 0.6, note: "Only a guess"))
        }
        var brief = EpisodeBrief(
            people: people, terms: [EpisodeBrief.Term(term: "Citadel", heardAs: ["Citadelle"], translation: "القلعة", note: "A place", confidence: 0.9)],
            plot: "Rick wakes Morty to go on an adventure.", scenes: "0:00 Rick greets Morty, who says he is fine.",
            targetLanguage: request.targetLanguage, work: request.work
        )
        brief.addMissingVoices(voices)
        return brief
    }
}

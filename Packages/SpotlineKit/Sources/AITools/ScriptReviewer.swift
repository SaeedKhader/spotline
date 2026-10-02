import Foundation
import SubtitleCore

/// What a script reviewer gets: every transcribed line, and the confirmed brief.
public struct ScriptReviewRequest: Sendable, Equatable {
    public struct Line: Sendable, Equatable {
        public var cueID: UUID
        public var start: MediaTime
        public var voices: [String]
        public var text: String
        /// Words the transcriber was unsure of.
        public var unsureWords: [String]

        public init(cueID: UUID, start: MediaTime, voices: [String] = [], text: String, unsureWords: [String] = []) {
            self.cueID = cueID
            self.start = start
            self.voices = voices
            self.text = text
            self.unsureWords = unsureWords
        }
    }

    public var lines: [Line]
    public var language: String
    public var brief: EpisodeBrief

    public init(lines: [Line], language: String, brief: EpisodeBrief) {
        self.lines = lines
        self.language = language
        self.brief = brief
    }
}

/// Reads a whole transcript with the episode brief and says which lines look wrong,
/// with fixes.
public protocol ScriptReviewer: Sendable {
    var name: String { get }
    /// `progress` gets how many lines are done.
    func review(_ request: ScriptReviewRequest, progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void) async throws
        -> [UUID: ScriptFinding]
}

// MARK: - OpenAI

/// Reviews the transcript with GPT-6 Luna (the Responses API), in batches: each
/// request has the rules, the brief and the whole transcript first (the same for
/// every batch, so OpenAI's prompt caching reuses them), then the lines to check.
/// A few cents an episode.
public struct OpenAIScriptReviewer: ScriptReviewer {
    public var name: String { model == Self.defaultModel ? "OpenAI GPT-6 Luna (cloud)" : "OpenAI \(model) (cloud)" }
    public static let defaultModel = OpenAITranslator.defaultModel
    let model: String
    let effort: AISettings.ReasoningEffort
    let apiKey: String
    let http: HTTPClient
    var endpoint = URL(string: "https://api.openai.com/v1/responses")!
    var batchSize = 80
    /// Fixes kept a line, most likely first.
    static let maxFixes = 3

    public init(
        apiKey: String, model: String = OpenAIScriptReviewer.defaultModel, effort: AISettings.ReasoningEffort = .medium,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.effort = effort
        http = HTTPClient(session: session)
    }

    public func review(
        _ request: ScriptReviewRequest, progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void
    ) async throws -> [UUID: ScriptFinding] {
        var findings: [UUID: ScriptFinding] = [:]
        let total = request.lines.count
        progress(0, total)
        for start in stride(from: 0, to: total, by: batchSize) {
            try Task.checkCancellation()
            let range = start..<min(start + batchSize, total)
            var urlRequest = URLRequest(url: endpoint, timeoutInterval: 600)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
            urlRequest.httpBody = try JSONSerialization.data(
                withJSONObject: Self.body(for: request, checking: range, model: model, effort: effort)
            )
            let data = try await http.send(urlRequest)
            findings.merge(try Self.findings(from: data, request: request, checking: range)) { first, _ in first }
            progress(range.upperBound, total)
        }
        return findings
    }

    static func body(
        for request: ScriptReviewRequest, checking range: Range<Int>, model: String = defaultModel, effort: AISettings.ReasoningEffort = .medium
    ) -> [String: Any] {
        [
            "model": model,
            "instructions": instructions(for: request),
            "input": input(for: request, checking: range),
            "max_output_tokens": 16000,
            "reasoning": ["effort": effort.rawValue],
            "store": false,
            "text": ["format": ["type": "json_schema", "name": "script_review", "strict": true, "schema": outputSchema]],
        ]
    }

    private static func object(_ properties: [String: Any]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": properties.keys.sorted(), "additionalProperties": false]
    }

    private static var string: [String: Any] { ["type": "string"] }

    static var outputSchema: [String: Any] {
        let fix = object(["text": string, "confidence": ["type": "number"]])
        let finding = object([
            "id": string, "words": ["type": "array", "items": string], "fixes": ["type": "array", "items": fix], "reason": string,
        ])
        return object(["findings": ["type": "array", "items": finding]])
    }

    /// The rules, the brief and the whole transcript: the same for every batch.
    static func instructions(for request: ScriptReviewRequest) -> String {
        let language = Languages.name(request.language)
        var text = """
            You review an automatic \(language) transcript of a film or TV episode before it is subtitled. The \
            transcriber sometimes mishears: names, rare words, words in noise, and words it was sure of but got wrong. \
            Words it was unsure of are in [brackets?].

            Check each line you are asked about against the brief below, the lines around it and the scene. List only \
            the lines that are wrong:
            - a misheard word or name (use the brief's spellings: its people, and its terms with how they were heard),
            - the same name spelled differently from the brief,
            - a line that makes no sense in its scene.
            Leave out lines that are fine, style you would merely write differently, punctuation, and filler words.

            For each line, give its id, the doubtful words as the line has them (words), one to \(maxFixes) fixed lines \
            (fixes: the whole line as it should read, with the line breaks written \\n where the line has them, and how \
            sure you are of each, 0 to 1), and the reason in one short English sentence. Most likely fix first.
            """
        text += "\n\n" + briefText(request.brief)
        text += "\n\nThe whole transcript (time, voice, line):\n"
        for line in request.lines {
            text += timed(line) + "\n"
        }
        return text
    }

    static func briefText(_ brief: EpisodeBrief) -> String {
        var text = "The brief the user confirmed"
        if let work = brief.work { text += " for \(work)" }
        text += ":\n"
        let people = brief.people.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        if !people.isEmpty {
            text += "People:\n"
            for person in people {
                let voices = person.voices.isEmpty ? "does not speak" : "voice \(person.voices.joined(separator: ", "))"
                text += "- \(person.name) (\(person.gender.rawValue), \(voices))\n"
            }
        }
        if !brief.terms.isEmpty {
            text += "Terms:\n"
            for term in brief.terms {
                let heard = term.heardAs.isEmpty ? "" : " (heard as \(term.heardAs.joined(separator: ", ")))"
                text += "- \(term.term)\(heard)\(term.note.isEmpty ? "" : ": \(term.note)")\n"
            }
        }
        if let story = brief.storyNotes { text += story + "\n" }
        return text
    }

    static func input(for request: ScriptReviewRequest, checking range: Range<Int>) -> String {
        var text = "Lines to check (id | time, voice, line):\n"
        for index in range {
            text += "\(ClaudeTranslator.lineID(index - range.lowerBound)) | \(timed(request.lines[index]))\n"
        }
        return text
    }

    private static func timed(_ line: ScriptReviewRequest.Line) -> String {
        let seconds = Int(line.start.seconds)
        let voice = line.voices.isEmpty ? "?" : line.voices.joined(separator: " then ")
        return String(format: "[%d:%02d] ", seconds / 60, seconds % 60)
            + "\(voice): \(ClaudeTranslator.sourceLine(marking: line.unsureWords, in: line.text))"
    }

    struct Output: Decodable {
        struct Finding: Decodable {
            struct Fix: Decodable {
                var text: String?
                var confidence: Double?
            }

            var id: String?
            var words: [String]?
            var fixes: [Fix]?
            var reason: String?
        }

        var findings: [Finding]?
    }

    static func findings(from data: Data, request: ScriptReviewRequest, checking range: Range<Int>) throws -> [UUID: ScriptFinding] {
        let response = try JSONDecoder().decode(OpenAITranslator.Response.self, from: data)
        let contents = response.output.filter { $0.type == "message" }.flatMap { $0.content ?? [] }
        if contents.contains(where: { $0.type == "refusal" }) { throw AIError.declined }
        if response.status == "incomplete" {
            throw response.incomplete_details?.reason == "content_filter" ? AIError.declined : AIError.cutOff
        }
        let texts = contents.filter { $0.type == "output_text" }.compactMap(\.text)
        guard let output = texts.reversed().lazy.compactMap({ try? JSONDecoder().decode(Output.self, from: Data($0.utf8)) }).first else {
            throw AIError.provider("OpenAI's review could not be read.")
        }
        return findings(from: output, request: request, checking: range)
    }

    /// The answer by cue: lines it named that exist, with fixes that change the line
    /// (breaks written "\n" read back as breaks), at most `maxFixes`, most likely first.
    static func findings(from output: Output, request: ScriptReviewRequest, checking range: Range<Int>) -> [UUID: ScriptFinding] {
        var result: [UUID: ScriptFinding] = [:]
        for finding in output.findings ?? [] {
            guard let id = finding.id, id.hasPrefix("L"), let number = Int(id.dropFirst()), number >= 1,
                  range.lowerBound + number - 1 < range.upperBound
            else { continue }
            let line = request.lines[range.lowerBound + number - 1]
            var seen: Set<String> = []
            let fixes = (finding.fixes ?? []).compactMap { fix -> ScriptFinding.Fix? in
                let text = (fix.text ?? "").replacing("\\n", with: "\n").trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty, text != line.text, seen.insert(text).inserted else { return nil }
                return ScriptFinding.Fix(text: text, confidence: ((min(max(fix.confidence ?? 0.5, 0), 1)) * 100).rounded() / 100)
            }
            .sorted { $0.confidence > $1.confidence }
            .prefix(maxFixes)
            guard !fixes.isEmpty else { continue }
            result[line.cueID] = ScriptFinding(
                words: finding.words ?? [], fixes: Array(fixes), reason: finding.reason ?? "", original: line.text
            )
        }
        return result
    }
}

// MARK: - Scripted

/// For UI tests: every line with "there" in it could be "Rick" (72%) or "Morty" (40%).
public struct ScriptedScriptReviewer: ScriptReviewer {
    public var name: String { "Scripted review" }

    public init() {}

    public func review(
        _ request: ScriptReviewRequest, progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void
    ) async throws -> [UUID: ScriptFinding] {
        progress(request.lines.count, request.lines.count)
        var findings: [UUID: ScriptFinding] = [:]
        for line in request.lines where line.text.contains("there") {
            findings[line.cueID] = ScriptFinding(
                words: ["there"],
                fixes: [
                    .init(text: line.text.replacing("there", with: "Rick"), confidence: 0.72),
                    .init(text: line.text.replacing("there", with: "Morty"), confidence: 0.4),
                ],
                reason: "Rick is the one in the scene", original: line.text
            )
        }
        return findings
    }
}

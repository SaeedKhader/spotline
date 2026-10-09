import Foundation
import SubtitleCore

/// The helper steps (episode brief, scene descriptions, script review) with Claude
/// Haiku (Anthropic's Messages API). Each asks what its OpenAI version asks, with the
/// same rules and JSON schema, and reads the answer the same way.
struct ClaudeMessages: Sendable {
    let apiKey: String
    let http: HTTPClient
    var endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    init(apiKey: String, session: URLSession) {
        self.apiKey = apiKey
        http = HTTPClient(session: session)
    }

    func send(_ body: [String: Any], timeout: TimeInterval = 600) async throws -> Data {
        var urlRequest = URLRequest(url: endpoint, timeoutInterval: timeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await http.send(urlRequest)
    }

    /// A request answered in JSON to `schema`. Haiku has no model to fall back to, so a refusal is final.
    /// `maxTokens` counts Haiku's thinking too, which on a whole episode can run past 16,000 by itself.
    static func body(
        model: String, effort: AISettings.ReasoningEffort, maxTokens: Int, system: String, user: Any, schema: [String: Any]
    ) -> [String: Any] {
        [
            "model": model,
            "max_tokens": maxTokens,
            "output_config": ["effort": effort.rawValue, "format": ["type": "json_schema", "schema": schema]],
            // Cached: the script review sends the same rules and transcript with every batch.
            "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
            "messages": [["role": "user", "content": user]],
        ]
    }

    /// The answer's last text block that reads as `T`.
    static func output<T: Decodable>(_ type: T.Type, from data: Data, what: String) throws -> T {
        let response = try JSONDecoder().decode(ClaudeTranslator.Response.self, from: data)
        if response.stop_reason == "refusal" { throw AIError.declined }
        if response.stop_reason == "max_tokens" { throw AIError.cutOff }
        let texts = response.content.filter { $0.type == "text" }.compactMap(\.text)
        guard let output = texts.reversed().lazy.compactMap({ try? JSONDecoder().decode(T.self, from: Data($0.utf8)) }).first else {
            throw AIError.provider("Claude's \(what) could not be read.")
        }
        return output
    }
}

// MARK: - Brief

/// Builds the brief with Claude Haiku. Web search answers with citations, which a JSON
/// answer cannot carry, so when the file name names the show a first request searches
/// (at most 3 searches, a cent each) and writes notes, and a second writes the brief from them.
public struct ClaudeBriefBuilder: EpisodeBriefBuilder {
    public var name: String { "Claude \(model) (cloud)" }
    let model: String
    let effort: AISettings.ReasoningEffort
    let messages: ClaudeMessages

    public init(apiKey: String, model: String, effort: AISettings.ReasoningEffort = .medium, session: URLSession = .shared) {
        self.model = model
        self.effort = effort
        messages = ClaudeMessages(apiKey: apiKey, session: session)
    }

    public func buildBrief(_ request: BriefRequest) async throws -> EpisodeBrief {
        var notes: String?
        if request.work != nil {
            // A failed search leaves the brief to the dialogue, as when the file name says nothing.
            notes = try? await searchNotes(for: request)
        }
        let data = try await messages.send(Self.body(for: request, webNotes: notes, model: model, effort: effort))
        let output: OpenAIBriefBuilder.Output
        do { output = try ClaudeMessages.output(OpenAIBriefBuilder.Output.self, from: data, what: "brief") } catch AIError.cutOff {
            throw AIError.provider("Claude's brief ran past the length it may write. Try again, or a lower effort for the brief.")
        }
        return OpenAIBriefBuilder.brief(from: output, request: request)
    }

    /// Searches for the show and returns what it found, as notes; a paused search is sent back to go on.
    func searchNotes(for request: BriefRequest, today: Date = .now) async throws -> String? {
        var body = Self.searchBody(for: request, model: model, today: today)
        for _ in 0..<3 {
            let data = try await messages.send(body)
            guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = response["content"] as? [[String: Any]]
            else { return nil }
            if response["stop_reason"] as? String == "pause_turn" {
                var turns = body["messages"] as? [[String: Any]] ?? []
                turns.append(["role": "assistant", "content": content])
                body["messages"] = turns
                continue
            }
            let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
            let notes = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return notes.isEmpty ? nil : notes
        }
        return nil
    }

    static func searchBody(for request: BriefRequest, model: String, today: Date = .now) -> [String: Any] {
        let date = today.formatted(.iso8601.year().month().day())
        let system = """
            The current date is \(date). You look up a film or TV episode for its translators into \
            \(Languages.name(request.targetLanguage)). Search the web (at most \(OpenAIBriefBuilder.maxSearches) searches) \
            for its cast list with the characters' names and genders, and for the places and other names that recur. \
            Then write plain notes in English: each character as the show spells them, their gender and who plays them, \
            and each place or term. Only what the sources say; no introduction.
            """
        return [
            "model": model,
            "max_tokens": 4000,
            "output_config": ["effort": AISettings.ReasoningEffort.low.rawValue],
            "system": system,
            "messages": [["role": "user", "content": "What is being watched (from the file name): \(request.work ?? "")"]],
            "tools": [["type": "web_search_20250305", "name": "web_search", "max_uses": OpenAIBriefBuilder.maxSearches]],
        ]
    }

    static func body(for request: BriefRequest, webNotes: String?, model: String, effort: AISettings.ReasoningEffort) -> [String: Any] {
        var user = OpenAIBriefBuilder.input(for: request)
        if let webNotes {
            user += "\nNotes from a web search for the show (prefer the episode's own dialogue when they disagree):\n\(webNotes)\n"
        }
        return ClaudeMessages.body(
            model: model, effort: effort, maxTokens: 32000, system: OpenAIBriefBuilder.instructions(for: request, searches: false),
            user: user, schema: OpenAIBriefBuilder.outputSchema
        )
    }
}

// MARK: - Scenes

/// Describes a scene with Claude Haiku: its frames as images, each under its time, then its lines.
public struct ClaudeSceneDescriber: SceneDescriber {
    public var name: String { "Claude \(model) (cloud)" }
    let model: String
    let effort: AISettings.ReasoningEffort
    let messages: ClaudeMessages

    public init(apiKey: String, model: String, effort: AISettings.ReasoningEffort = .high, session: URLSession = .shared) {
        self.model = model
        self.effort = effort
        messages = ClaudeMessages(apiKey: apiKey, session: session)
    }

    public func describe(_ request: SceneRequest) async throws -> SceneNote {
        let data = try await messages.send(Self.body(for: request, model: model, effort: effort), timeout: 300)
        let output = try ClaudeMessages.output(OpenAISceneDescriber.Output.self, from: data, what: "scene description")
        return OpenAISceneDescriber.note(from: output, request: request)
    }

    static func body(for request: SceneRequest, model: String, effort: AISettings.ReasoningEffort) -> [String: Any] {
        ClaudeMessages.body(
            model: model, effort: effort, maxTokens: 16000, system: OpenAISceneDescriber.instructions,
            user: content(for: request), schema: OpenAISceneDescriber.outputSchema
        )
    }

    /// OpenAI's message, with Claude's text and image blocks.
    static func content(for request: SceneRequest) -> [[String: Any]] {
        OpenAISceneDescriber.content(for: request).map { block in
            if let text = block["text"] as? String { return ["type": "text", "text": text] }
            let url = block["image_url"] as? String ?? ""
            let data = url.split(separator: ",", maxSplits: 1).last.map(String.init) ?? ""
            return ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": data]]
        }
    }
}

// MARK: - Script review

/// Reviews the transcript with Claude Haiku, in batches: the rules, the brief and the
/// whole transcript go first and are cached, then the lines to check.
public struct ClaudeScriptReviewer: ScriptReviewer {
    public var name: String { "Claude \(model) (cloud)" }
    let model: String
    let effort: AISettings.ReasoningEffort
    let messages: ClaudeMessages
    var batchSize = 80

    public init(apiKey: String, model: String, effort: AISettings.ReasoningEffort = .medium, session: URLSession = .shared) {
        self.model = model
        self.effort = effort
        messages = ClaudeMessages(apiKey: apiKey, session: session)
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
            let data = try await messages.send(Self.body(for: request, checking: range, model: model, effort: effort))
            let output = try ClaudeMessages.output(OpenAIScriptReviewer.Output.self, from: data, what: "review")
            findings.merge(OpenAIScriptReviewer.findings(from: output, request: request, checking: range)) { first, _ in first }
            progress(range.upperBound, total)
        }
        return findings
    }

    static func body(
        for request: ScriptReviewRequest, checking range: Range<Int>, model: String, effort: AISettings.ReasoningEffort
    ) -> [String: Any] {
        ClaudeMessages.body(
            model: model, effort: effort, maxTokens: 32000, system: OpenAIScriptReviewer.instructions(for: request),
            user: OpenAIScriptReviewer.input(for: request, checking: range), schema: OpenAIScriptReviewer.outputSchema
        )
    }
}

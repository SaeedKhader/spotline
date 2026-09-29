import Foundation
import MediaAnalysis
import SubtitleCore

/// Sends a request, retrying rate limits, server errors and dropped connections with backoff.
struct HTTPClient: Sendable {
    var session: URLSession
    var attempts = 4

    func send(_ request: URLRequest) async throws -> Data {
        var delay: Duration = .seconds(2)
        for attempt in 1...attempts {
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(status) { return data }
                let retryable = status == 408 || status == 409 || status == 429 || status >= 500
                if !retryable || attempt == attempts { throw AIError.provider(Self.message(from: data, status: status)) }
            } catch let error as URLError where attempt < attempts && error.code != .cancelled {
                // A dropped connection: try again.
            }
            try await Task.sleep(for: delay)
            delay *= 2
        }
        throw AIError.provider("The request failed.")
    }

    /// The provider's error message ({"error": {"message": …}}), else the status.
    static func message(from data: Data, status: Int) -> String {
        struct Envelope: Decodable {
            struct Body: Decodable { var message: String }
            var error: Body
        }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) { return envelope.error.message }
        return "The provider answered with status \(status)."
    }
}

// MARK: - OpenAI Whisper

/// Cloud transcription with OpenAI's Whisper API (`whisper-1`, word timestamps).
/// Chunks go up as Ogg Opus, a few at a time, each retried on its own.
public struct OpenAITranscriber: Transcriber {
    public var name: String { "OpenAI Whisper (cloud)" }
    let apiKey: String
    let http: HTTPClient
    var endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    /// Chunks uploaded at the same time.
    var parallelUploads = 4

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        http = HTTPClient(session: session)
    }

    public func transcribe(
        _ audio: PreparedAudio, language: String?, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TranscribedWord] {
        let chunks = audio.chunks
        let counter = ProgressCounter(total: chunks.count, report: progress)
        let words = try await withThrowingTaskGroup(of: [TranscribedWord].self) { group in
            var next = 0
            var all: [TranscribedWord] = []
            func startNext() {
                guard next < chunks.count else { return }
                let chunk = chunks[next]
                next += 1
                group.addTask {
                    let words = try await transcribe(chunk, language: language)
                    await counter.advance()
                    return words
                }
            }
            for _ in 0..<min(parallelUploads, chunks.count) { startNext() }
            while let result = try await group.next() {
                all += result
                startNext()
            }
            return all
        }
        return words.sorted { $0.start < $1.start }
    }

    func transcribe(_ chunk: AudioChunk, language: String?) async throws -> [TranscribedWord] {
        let audio = try OpusEncoder.oggOpus(chunk.samples)
        let boundary = "spotline-\(UUID().uuidString)"
        var form = MultipartForm(boundary: boundary)
        form.add(name: "model", value: "whisper-1")
        form.add(name: "response_format", value: "verbose_json")
        form.add(name: "timestamp_granularities[]", value: "word")
        form.add(name: "timestamp_granularities[]", value: "segment")
        if let language { form.add(name: "language", value: Languages.base(language)) }
        form.add(name: "file", filename: "chunk-\(chunk.id).ogg", contentType: "audio/ogg", data: audio)
        var request = URLRequest(url: endpoint, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finish()
        let data = try await http.send(request)
        return try Self.words(from: data, chunk: chunk)
    }

    struct Response: Decodable {
        struct Word: Decodable {
            var word: String
            var start: Double
            var end: Double
        }

        struct Segment: Decodable {
            var text: String
        }

        var words: [Word]?
        var segments: [Segment]?
    }

    /// Word timestamps are relative to the chunk; Whisper's words carry no
    /// punctuation, so each takes its spelling from the punctuated segment text.
    static func words(from data: Data, chunk: AudioChunk) throws -> [TranscribedWord] {
        let response = try JSONDecoder().decode(Response.self, from: data)
        let punctuated = (response.segments ?? []).flatMap { $0.text.split(whereSeparator: \.isWhitespace).map(String.init) }
        var tokenIndex = 0
        return (response.words ?? []).map { word in
            var text = word.word.trimmingCharacters(in: .whitespaces)
            let key = letters(text)
            // Find the same word in the segment text, a few tokens ahead at most.
            for index in tokenIndex..<min(tokenIndex + 4, punctuated.count) where letters(punctuated[index]) == key {
                text = punctuated[index]
                tokenIndex = index + 1
                break
            }
            return TranscribedWord(text: text, start: chunk.mediaTime(atOffset: word.start), end: chunk.mediaTime(atOffset: max(word.end, word.start)))
        }
    }

    private static func letters(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}

/// Counts finished chunks and reports the fraction.
private actor ProgressCounter {
    let total: Int
    let report: @Sendable (Double) -> Void
    var done = 0

    init(total: Int, report: @escaping @Sendable (Double) -> Void) {
        self.total = total
        self.report = report
    }

    func advance() {
        done += 1
        report(Double(done) / Double(max(total, 1)))
    }
}

struct MultipartForm {
    let boundary: String
    private var body = Data()

    init(boundary: String) {
        self.boundary = boundary
    }

    mutating func add(name: String, value: String) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }

    mutating func add(name: String, filename: String, contentType: String, data: Data) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(contentType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    func finish() -> Data {
        body + Data("--\(boundary)--\r\n".utf8)
    }
}

// MARK: - Claude

/// Cloud translation with Claude (Anthropic's Messages API). Each batch of lines
/// goes with the lines before it, the glossary, translation memory examples,
/// the speakers and the QC limits. For languages that conjugate "you" for the
/// listener (Arabic first), Claude reads the scene to decide who each line
/// addresses, says how sure it is, and writes the other forms when unsure.
public struct ClaudeTranslator: CueTranslator {
    public var name: String { "Claude (cloud)" }
    public static let model = "claude-opus-5-5"
    let apiKey: String
    let http: HTTPClient
    var endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    /// Lines per request, and how many earlier lines go along as context.
    var batchSize = 40
    var contextLines = 6

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        http = HTTPClient(session: session)
    }

    public func translate(_ request: TranslationRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> [CueTranslation] {
        var results: [CueTranslation] = []
        var context = request.precedingContext
        for start in stride(from: 0, to: request.lines.count, by: batchSize) {
            try Task.checkCancellation()
            let lines = Array(request.lines[start..<min(start + batchSize, request.lines.count)])
            var batch = request
            batch.lines = lines
            batch.precedingContext = Array(context.suffix(contextLines))
            let translated = try await translateBatch(batch)
            results += translated
            for line in lines {
                if let text = translated.first(where: { $0.cueID == line.cueID })?.text { context.append((line.source, text)) }
            }
            progress(Double(results.count) / Double(max(request.lines.count, 1)))
        }
        return results
    }

    func translateBatch(_ request: TranslationRequest) async throws -> [CueTranslation] {
        var urlRequest = URLRequest(url: endpoint, timeoutInterval: 600)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: Self.body(for: request))
        let data = try await http.send(urlRequest)
        return try Self.translations(from: data, request: request)
    }

    static let addresseeValues = Addressee.allCases.map(\.rawValue)

    /// The Messages API request: structured output constrained to a JSON schema.
    static func body(for request: TranslationRequest) -> [String: Any] {
        let gendered = request.targetIsGendered
        var item: [String: Any] = [
            "type": "object",
            "properties": [
                "id": ["type": "string"],
                "text": ["type": "string"],
            ],
            "required": ["id", "text"],
            "additionalProperties": false,
        ]
        if gendered {
            item["properties"] = [
                "id": ["type": "string"],
                "text": ["type": "string"],
                "addressee": ["type": "string", "enum": addresseeValues],
                "confidence": ["type": "number"],
                "variants": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": ["addressee": ["type": "string", "enum": addresseeValues], "text": ["type": "string"]],
                        "required": ["addressee", "text"],
                        "additionalProperties": false,
                    ],
                ],
            ]
            item["required"] = ["id", "text", "addressee", "confidence", "variants"]
        }
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["translations": ["type": "array", "items": item]],
            "required": ["translations"],
            "additionalProperties": false,
        ]
        return [
            "model": model,
            "max_tokens": 16000,
            "fallbacks": "default",
            "output_config": ["effort": "medium", "format": ["type": "json_schema", "schema": schema]],
            "system": systemPrompt(for: request),
            "messages": [["role": "user", "content": userPrompt(for: request)]],
        ]
    }

    static func systemPrompt(for request: TranslationRequest) -> String {
        var prompt = """
            You are a professional subtitle translator. Translate film and TV subtitles from \(Languages.name(request.sourceLanguage)) \
            into \(Languages.name(request.targetLanguage)) for on-screen delivery: natural, idiomatic dialogue that reads quickly, \
            faithful to meaning, tone and register rather than word for word.

            Rules:
            - Return exactly one translation per line id you are given, in the same order.
            - Keep line breaks sensible: at most \(request.maxLines ?? 2) lines of about \(request.maxCharactersPerLine ?? 42) characters each; \
            use "\\n" for a line break.
            - Keep inline tags like <i>…</i> around the corresponding words.
            - Use the glossary's agreed translations for its terms, and follow the style of the translation memory examples.
            - Lines before the ones to translate are context only.
            """
        if request.targetIsGendered {
            prompt += """

                - \(Languages.name(request.targetLanguage)) conjugates "you", imperatives and agreeing words for the listener's gender and number. \
                For every line, decide who is being addressed by reading the scene: who spoke just before, names and vocatives, \
                later "he"/"she" references, plural or dual address, and the speakers' voices (given as speaker labels with gender guesses). \
                Set "addressee" to one of: \(addresseeValues.joined(separator: ", ")) ("unknown" when the line addresses nobody or it cannot matter), \
                and "confidence" between 0 and 1 for how sure you are.
                - When confidence is below 0.75 and the choice changes the wording, add the line as it would read for each other plausible \
                addressee to "variants" (for example male, female and groupMixed). Otherwise leave "variants" empty.
                - The speaker's own gender can also change the wording (first-person agreement); use the speaker's gender for that.
                """
        }
        return prompt
    }

    static func userPrompt(for request: TranslationRequest) -> String {
        var text = ""
        if !request.glossary.isEmpty {
            text += "Glossary (source → agreed translation):\n"
            for entry in request.glossary {
                text += "- \(entry.source) → \(entry.target)\(entry.note.isEmpty ? "" : " (\(entry.note))")\n"
            }
            text += "\n"
        }
        let examples = request.lines.compactMap(\.memoryExample)
        if !examples.isEmpty {
            text += "Translation memory examples:\n"
            for example in examples.prefix(20) { text += "- \(oneLine(example.source)) → \(oneLine(example.target))\n" }
            text += "\n"
        }
        if !request.precedingContext.isEmpty {
            text += "Previous lines (context only, already translated):\n"
            for line in request.precedingContext { text += "- \(oneLine(line.source)) → \(oneLine(line.target))\n" }
            text += "\n"
        }
        text += "Lines to translate (id, time, speaker, text):\n"
        for (index, line) in request.lines.enumerated() {
            var speaker = "speaker ?"
            if let hint = line.speaker {
                speaker = "speaker \(hint.label)"
                if hint.gender != .unknown { speaker += " (\(hint.gender.rawValue) voice, \(Int((hint.confidence * 100).rounded()))% sure)" }
            }
            let time = String(format: "%.1fs", line.start.seconds)
            text += "\(lineID(index)) | \(time) | \(speaker) | \(oneLine(line.source))\n"
        }
        return text
    }

    static func lineID(_ index: Int) -> String { "L\(index + 1)" }

    private static func oneLine(_ text: String) -> String {
        text.replacing("\n", with: " / ")
    }

    struct Response: Decodable {
        struct Block: Decodable {
            var type: String
            var text: String?
        }

        var content: [Block]
        var stop_reason: String?
    }

    struct Output: Decodable {
        struct Item: Decodable {
            struct Variant: Decodable {
                var addressee: String
                var text: String
            }

            var id: String
            var text: String
            var addressee: String?
            var confidence: Double?
            var variants: [Variant]?
        }

        var translations: [Item]
    }

    static func translations(from data: Data, request: TranslationRequest) throws -> [CueTranslation] {
        let response = try JSONDecoder().decode(Response.self, from: data)
        if response.stop_reason == "refusal" { throw AIError.provider("Claude declined to translate these lines.") }
        if response.stop_reason == "max_tokens" { throw AIError.provider("Claude's answer was cut off. Try fewer lines at once.") }
        guard let json = response.content.first(where: { $0.type == "text" })?.text else {
            throw AIError.provider("Claude sent no translation.")
        }
        let output = try JSONDecoder().decode(Output.self, from: Data(json.utf8))
        let ids = Dictionary(uniqueKeysWithValues: request.lines.enumerated().map { (lineID($0.offset), $0.element.cueID) })
        return output.translations.compactMap { item in
            guard let cueID = ids[item.id] else { return nil }
            var translation = CueTranslation(cueID: cueID, text: item.text.replacing("\\n", with: "\n"))
            if request.targetIsGendered, let raw = item.addressee, let addressee = Addressee(rawValue: raw) {
                let confidence = min(max(item.confidence ?? 0.5, 0), 1)
                if addressee != .unknown || confidence < AddresseeTag.reviewThreshold {
                    translation.addressee = AddresseeTag(addressee, confidence: (confidence * 100).rounded() / 100)
                }
                let variants = (item.variants ?? []).compactMap { variant in
                    Addressee(rawValue: variant.addressee).map { TextVariant(addressee: $0, text: variant.text.replacing("\\n", with: "\n")) }
                }.filter { $0.addressee != addressee }
                if !variants.isEmpty { translation.variants = [TextVariant(addressee: addressee, text: translation.text)] + variants }
            }
            return translation
        }
    }
}

import Foundation
import Synchronization
import MediaAnalysis
import SubtitleCore

/// Sends a request, retrying rate limits, server errors and dropped connections with backoff.
struct HTTPClient: Sendable {
    var session: URLSession
    var attempts = 4

    /// Sends `request`. With `uploadProgress`, its body goes up as an upload that
    /// reports bytes sent (from 0 again on each retry).
    func send(_ request: URLRequest, uploadProgress: (@Sendable (_ sent: Int64, _ total: Int64) -> Void)? = nil) async throws -> Data {
        var delay: Duration = .seconds(2)
        for attempt in 1...attempts {
            do {
                let (data, response): (Data, URLResponse)
                if let uploadProgress, let body = request.httpBody {
                    var upload = request
                    upload.httpBody = nil
                    (data, response) = try await session.upload(for: upload, from: body, delegate: UploadObserver(report: uploadProgress))
                } else {
                    (data, response) = try await session.data(for: request)
                }
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

    /// Passes on the bytes an upload has sent, at most once per percent.
    private final class UploadObserver: NSObject, URLSessionTaskDelegate, Sendable {
        let report: @Sendable (Int64, Int64) -> Void
        private let lastPercent = Mutex(-1)

        init(report: @escaping @Sendable (Int64, Int64) -> Void) {
            self.report = report
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
            totalBytesExpectedToSend: Int64
        ) {
            let percent = totalBytesExpectedToSend > 0 ? Int(totalBytesSent * 100 / totalBytesExpectedToSend) : 0
            let isNew = lastPercent.withLock { last in
                defer { last = percent }
                return percent != last
            }
            if isNew { report(totalBytesSent, totalBytesExpectedToSend) }
        }
    }

    /// The provider's error message ({"error": {"message": …}}, ElevenLabs'
    /// {"detail": {"message": …}}), else the status.
    static func message(from data: Data, status: Int) -> String {
        struct Body: Decodable { var message: String }
        struct Envelope: Decodable { var error: Body }
        struct Detail: Decodable { var detail: Body }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) { return envelope.error.message }
        if let detail = try? JSONDecoder().decode(Detail.self, from: data) { return detail.detail.message }
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
        _ audio: PreparedAudio, language: String?, progress: @escaping @Sendable (AIProgress) -> Void,
        found: @escaping @Sendable ([TranscribedWord]) -> Void
    ) async throws -> [TranscribedWord] {
        let chunks = audio.chunks
        progress(.parts(done: 0, total: chunks.count))
        let counter = ProgressCounter(total: chunks.count, report: progress, found: found)
        let words = try await withThrowingTaskGroup(of: [TranscribedWord].self) { group in
            var next = 0
            var all: [TranscribedWord] = []
            func startNext() {
                guard next < chunks.count else { return }
                let chunk = chunks[next]
                next += 1
                let index = next - 1
                group.addTask {
                    let words = try await transcribe(chunk, language: language)
                    await counter.finished(index, words: words)
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

// MARK: - ElevenLabs Scribe

/// Cloud transcription with ElevenLabs Scribe (word timestamps). The dialogue
/// goes up in one piece as Ogg Opus, silence between chunks kept, so the model
/// hears the whole scene and its times are media times.
public struct ElevenLabsTranscriber: Transcriber {
    public var name: String { "ElevenLabs Scribe (cloud)" }
    /// Its word times start a little late: measured with `spotline-bench` on
    /// synthesized speech with exact onsets (0.07 s) and two TV episodes (0.1 s).
    public var wordStartLead: Double { -0.05 }
    public static let model = "scribe_v2"
    public var uploadsInOnePiece: Bool { true }
    let apiKey: String
    let http: HTTPClient
    var endpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        http = HTTPClient(session: session)
    }

    public func transcribe(
        _ audio: PreparedAudio, language: String?, progress: @escaping @Sendable (AIProgress) -> Void,
        found: @escaping @Sendable ([TranscribedWord]) -> Void
    ) async throws -> [TranscribedWord] {
        progress(.encoding(0))
        let encoded = try OpusEncoder.oggOpus(Self.samples(of: audio)) { progress(.encoding($0)) }
        let boundary = "spotline-\(UUID().uuidString)"
        var form = MultipartForm(boundary: boundary)
        form.add(name: "model_id", value: Self.model)
        form.add(name: "timestamps_granularity", value: "word")
        // Sounds such as (laughter) and (music), for hearing-impaired subtitles.
        form.add(name: "tag_audio_events", value: "true")
        // Who says each word, so a cue two people speak in becomes a dialogue cue.
        form.add(name: "diarize", value: "true")
        if let language { form.add(name: "language_code", value: Languages.base(language)) }
        form.add(name: "file", filename: "dialogue.ogg", contentType: "audio/ogg", data: encoded)
        // Zero retention is asked for until ElevenLabs refuses it once (only enterprise
        // accounts may use it): the refusal comes after the whole file is up, so asking
        // every time would upload everything twice.
        let asksForZeroRetention = !Self.zeroRetentionRefused
        var request = URLRequest(url: asksForZeroRetention ? Self.withoutLogging(endpoint) : endpoint, timeoutInterval: 1800)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finish()
        let size = Int64(request.httpBody?.count ?? 0)
        progress(.uploading(sent: 0, total: size))
        // Once every byte is up, ElevenLabs works on the whole file and says nothing until it is done.
        let uploaded: @Sendable (Int64, Int64) -> Void = { sent, total in
            progress(total > 0 && sent >= total ? .waiting : .uploading(sent: sent, total: total))
        }
        let data: Data
        do {
            data = try await http.send(request, uploadProgress: uploaded)
        } catch AIError.provider(let message) where asksForZeroRetention && Self.isRetentionRefusal(message) {
            // Only enterprise accounts may turn logging off; others transcribe as usual.
            Self.zeroRetentionRefused = true
            request.url = endpoint
            progress(.uploading(sent: 0, total: size))
            data = try await http.send(request, uploadProgress: uploaded)
        }
        let words = try Self.words(from: data)
        found(words)
        return words
    }

    /// True once ElevenLabs has refused zero retention for this Mac's account (kept in the user defaults).
    static var zeroRetentionRefused: Bool {
        get { UserDefaults.standard.bool(forKey: zeroRetentionRefusedKey) }
        set { UserDefaults.standard.set(newValue, forKey: zeroRetentionRefusedKey) }
    }

    static let zeroRetentionRefusedKey = "ElevenLabsZeroRetentionRefused"

    /// The endpoint asking ElevenLabs to keep no copy of the audio or transcript (zero retention).
    static func withoutLogging(_ endpoint: URL) -> URL {
        endpoint.appending(queryItems: [URLQueryItem(name: "enable_logging", value: "false")])
    }

    /// True for ElevenLabs' refusal of zero retention, which only enterprise accounts may use.
    static func isRetentionRefusal(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return ["retention", "enable_logging", "logging", "enterprise"].contains { lowered.contains($0) }
    }

    /// The chunks on one timeline from zero, with silence where there was no speech.
    static func samples(of audio: PreparedAudio) -> [Float] {
        let rate = Int64(PreparedAudio.sampleRate)
        func offset(_ time: MediaTime) -> Int { Int(time.value * rate / time.timescale) }
        let count = max(offset(audio.duration), audio.chunks.map { offset($0.start) + $0.samples.count }.max() ?? 0)
        var samples = [Float](repeating: 0, count: count)
        for chunk in audio.chunks {
            let start = offset(chunk.start)
            samples.replaceSubrange(start..<(start + chunk.samples.count), with: chunk.samples)
        }
        return samples
    }

    struct Response: Decodable {
        struct Word: Decodable {
            var text: String
            var type: String
            var start: Double?
            var end: Double?
            var speakerID: String?
            var logprob: Double?

            enum CodingKeys: String, CodingKey {
                case text, type, start, end, logprob
                case speakerID = "speaker_id"
            }
        }

        var words: [Word]
    }

    /// Words and sound events ("(laughter)"), not spacing, with the punctuation Scribe
    /// attaches to them and how sure it was of each (its log probability, as 0 to 1).
    static func words(from data: Data) throws -> [TranscribedWord] {
        try JSONDecoder().decode(Response.self, from: data).words.compactMap { word in
            var text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard word.type == "word" || word.type == "audio_event", !text.isEmpty, let start = word.start else { return nil }
            // "[door opens]" or "door opens" becomes "(door opens)", once.
            if word.type == "audio_event" {
                text = "(" + text.trimmingCharacters(in: CharacterSet(charactersIn: "()[] ")) + ")"
            }
            let begin = MediaTime(value: Int64((start * 1000).rounded()), timescale: 1000)
            let end = MediaTime(value: Int64(((word.end ?? start) * 1000).rounded()), timescale: 1000)
            return TranscribedWord(
                text: text, start: begin, end: max(end, begin), speaker: word.speakerID,
                confidence: word.type == "word" ? word.logprob.map { min(max(exp($0), 0), 1) } : nil
            )
        }
        .sorted { $0.start < $1.start }
    }
}

/// Counts finished chunks, reports the fraction, and passes on their words in
/// time order: chunks finish out of order, so each waits for the ones before it.
private actor ProgressCounter {
    let total: Int
    let report: @Sendable (AIProgress) -> Void
    let found: @Sendable ([TranscribedWord]) -> Void
    var done = 0
    var waiting: [Int: [TranscribedWord]] = [:]
    var nextToPass = 0

    init(total: Int, report: @escaping @Sendable (AIProgress) -> Void, found: @escaping @Sendable ([TranscribedWord]) -> Void) {
        self.total = total
        self.report = report
        self.found = found
    }

    func finished(_ index: Int, words: [TranscribedWord]) {
        done += 1
        waiting[index] = words
        while let words = waiting.removeValue(forKey: nextToPass) {
            if !words.isEmpty { found(words.sorted { $0.start < $1.start }) }
            nextToPass += 1
        }
        report(.parts(done: done, total: total))
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

// MARK: - Batched translation

/// A cloud translator that sends lines in batches, with the lines before each
/// batch and the cast found so far, and asks again for lines left out or declined.
protocol BatchedCueTranslator: CueTranslator {
    /// Lines per request, and how many earlier lines go along as context.
    var batchSize: Int { get }
    var contextLines: Int { get }
    /// Translates one batch in one request.
    func translateBatch(_ request: TranslationRequest) async throws -> TranslationBatch
}

extension BatchedCueTranslator {
    public func translate(
        _ request: TranslationRequest, progress: @escaping @Sendable (AIProgress) -> Void,
        found: @escaping @Sendable (TranslationBatch) -> Void
    ) async throws -> TranslationBatch {
        var results = TranslationBatch(cast: request.cast)
        var context = request.precedingContext
        // A small first batch shows results quickly.
        for range in AppleTranslator.batches(of: request.lines.count, first: 10, size: batchSize) {
            try Task.checkCancellation()
            let lines = Array(request.lines[range])
            progress(.lines(done: results.translations.count, total: request.lines.count, inFlight: lines.map(\.cueID)))
            var batch = request
            batch.lines = lines
            batch.precedingContext = Array(context.suffix(contextLines))
            // People named in earlier batches go along, so later lines use the same names.
            batch.cast = results.cast
            let translated = try await translateLines(batch) { progress(.retrying(inFlight: $0)) }.batch
            results = results.adding(translated)
            found(translated)
            for line in lines {
                if let translation = translated.translations.first(where: { $0.cueID == line.cueID }), !translation.isLeftOut {
                    context.append((line.source, translation.text))
                }
            }
        }
        progress(.lines(done: results.translations.count, total: request.lines.count, inFlight: []))
        return results
    }

    /// Translates the lines, then asks again, in halves, for any the model left out or
    /// declined (a refusal is often about one line in the batch), down to single lines.
    /// Lines that never come back are `skipped`; the editor marks them "Not translated".
    /// `retrying` gets the cues of the lines asked for again.
    func translateLines(
        _ request: TranslationRequest, retrying: @Sendable ([Cue.ID]) -> Void = { _ in }
    ) async throws -> (batch: TranslationBatch, skipped: [TranslationRequest.Line]) {
        var result: TranslationBatch
        do {
            result = try await translateBatch(request)
        } catch AIError.declined, AIError.cutOff {
            guard request.lines.count > 1 else { return (TranslationBatch(), request.lines) }
            result = TranslationBatch()
        }
        let done = Set(result.translations.filter(\.isAnswered).map(\.cueID))
        result.translations.removeAll { !done.contains($0.cueID) }
        let missing = request.lines.filter { !done.contains($0.cueID) }
        guard !missing.isEmpty else { return (result, []) }
        guard request.lines.count > 1 else { return (result, missing) }
        var skipped: [TranslationRequest.Line] = []
        let half = (missing.count + 1) / 2
        for part in [missing[..<half], missing[half...]] where !part.isEmpty {
            try Task.checkCancellation()
            var retry = request
            retry.lines = Array(part)
            retry.cast = result.cast.isEmpty ? request.cast : { var cast = request.cast; cast.merge(result.cast); return cast }()
            retrying(retry.lines.map(\.cueID))
            let (more, left) = try await translateLines(retry, retrying: retrying)
            result = result.adding(more)
            skipped += left
        }
        // In the order they were asked for.
        let order = Dictionary(uniqueKeysWithValues: request.lines.enumerated().map { ($0.element.cueID, $0.offset) })
        result.translations.sort { (order[$0.cueID] ?? 0) < (order[$1.cueID] ?? 0) }
        return (result, skipped)
    }
}

// MARK: - Claude

/// Cloud translation with Claude (Anthropic's Messages API). Each batch of lines
/// goes with the whole episode's source (cached, so it is paid for once), the
/// lines before it with their translations, the glossary, translation memory
/// examples, the transcriber's voice labels, the cast known so far with how
/// their names are spelled, the house style and the QC limits.
///
/// Into languages that inflect for gender or number (Arabic first), Claude flags
/// every line that could be translated more than one way ("you" for a man, a
/// woman or a group; gendered verbs and adjectives; an unclear speaker), writes
/// every valid variant, recommends one from the scene and says why in a line.
/// It also names the people it recognizes, which builds the cast.
public struct ClaudeTranslator: BatchedCueTranslator {
    public var name: String { model == Self.defaultModel ? "Claude (cloud)" : "Claude \(model) (cloud)" }
    /// Opus by default; Sonnet, at half the price, and Haiku, at GPT-6 Luna's price, are settings.
    public static let defaultModel = "claude-opus-5-5"
    public static let sonnetModel = "claude-sonnet-5-5"
    public static let haikuModel = "claude-haiku-5-5"
    let model: String
    let effort: AISettings.ReasoningEffort
    let apiKey: String
    let http: HTTPClient
    var endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    /// Lines per request, and how many earlier lines go along with their translations.
    /// (The whole episode's source goes along too, cached: `TranslationRequest.script`.)
    var batchSize = 40
    var contextLines = 20

    public init(
        apiKey: String, model: String = ClaudeTranslator.defaultModel, effort: AISettings.ReasoningEffort = .medium,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.effort = effort
        http = HTTPClient(session: session)
    }

    func translateBatch(_ request: TranslationRequest) async throws -> TranslationBatch {
        var urlRequest = URLRequest(url: endpoint, timeoutInterval: 600)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: Self.body(for: request, model: model, effort: effort))
        let data = try await http.send(urlRequest)
        return try Self.translations(from: data, request: request)
    }

    static let genderValues = Gender.allCases.map(\.rawValue)
    static let personGenderValues = [Gender.male, .female, .unknown].map(\.rawValue)
    static let countValues = ListenerCount.allCases.map(\.rawValue)
    static let reasonValues = TranslationFlag.Reason.allCases.map(\.rawValue)
    /// A possibly misheard line whose likely reading the translator is at least this sure of is not flagged.
    static let sureOfSource = 0.8

    private static func object(_ properties: [String: Any]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": properties.keys.sorted(), "additionalProperties": false]
    }

    private static func array(_ items: [String: Any]) -> [String: Any] {
        ["type": "array", "items": items]
    }

    private static var string: [String: Any] { ["type": "string"] }

    private static func oneOf(_ values: [String]) -> [String: Any] {
        ["type": "string", "enum": values]
    }

    /// The Messages API request: structured output constrained to a JSON schema.
    /// The rules and the episode's script come first and are cached, since every
    /// batch of the episode sends them unchanged.
    static func body(
        for request: TranslationRequest, model: String = defaultModel, effort: AISettings.ReasoningEffort = .medium
    ) -> [String: Any] {
        var system: [[String: Any]] = [["type": "text", "text": systemPrompt(for: request)]]
        if let script = scriptText(for: request) { system.append(["type": "text", "text": script]) }
        system[system.count - 1]["cache_control"] = ["type": "ephemeral"]
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 32000,
            "output_config": ["effort": effort.rawValue, "format": ["type": "json_schema", "schema": outputSchema(for: request)]],
            "system": system,
            "messages": [["role": "user", "content": userPrompt(for: request)]],
        ]
        // Haiku has no model to fall back to: a declined batch is split and asked again instead.
        if model != haikuModel { body["fallbacks"] = "default" }
        return body
    }

    /// The JSON schema of the answer: the translations with their flags and
    /// variants (gendered wording, or a possibly misheard source), and the cast
    /// with how each name is spelled. Every field is required, as OpenAI's
    /// strict structured outputs need.
    static func outputSchema(for request: TranslationRequest) -> [String: Any] {
        var item: [String: Any] = ["id": string, "text": string]
        item["reasons"] = array(oneOf(reasonValues))
        item["confidence"] = ["type": "number"]
        item["note"] = string
        if request.leavesOutWalla { item["walla"] = ["type": "boolean"] }
        if request.leavesOutFictionalLanguages { item["fictional_language"] = ["type": "boolean"] }
        item["variants"] = array(object([
            "text": string, "speaker": string, "speaker_gender": oneOf(personGenderValues),
            "listeners": array(string), "listener_gender": oneOf(genderValues), "listener_count": oneOf(countValues),
            "source": string,
        ]))
        let person = object(["name": string, "translation": string, "gender": oneOf(personGenderValues), "voices": array(string)])
        return object(["translations": array(object(item)), "cast": array(person)])
    }

    static func systemPrompt(for request: TranslationRequest) -> String {
        let target = Languages.name(request.targetLanguage)
        var prompt = """
            You are a professional subtitle translator. Translate film and TV subtitles from \(Languages.name(request.sourceLanguage)) \
            into \(target) for on-screen delivery: natural, idiomatic dialogue that reads quickly, \
            faithful to meaning, tone and register rather than word for word.
            """
        if let work = request.work, !work.isEmpty { prompt += "\n\nYou are translating: \(work)." }
        if let notes = request.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            prompt += "\n\nNotes from the user about it:\n\(notes)"
        }
        if let brief = request.brief?.trimmingCharacters(in: .whitespacesAndNewlines), !brief.isEmpty {
            prompt += "\n\nThe episode brief, written before translating and confirmed by the user:\n\(brief)"
        }
        prompt += """


            Rules:
            - Return exactly one translation per line id you are given, in the same order.
            - Each line is shown as its own subtitle. Keep line breaks sensible: at most \(request.maxLines ?? 2) lines of about \
            \(request.maxCharactersPerLine ?? 42) characters each; write a line break as "\\n". Break where the phrase breaks: \
            never end a line on a conjunction, preposition or article. When a sentence runs over several lines, keep each \
            line's words with that line where \(target) word order allows.
            - Keep inline tags like <i>…</i> around the corresponding words.
            - Use the glossary's agreed translations for its terms, and follow the style of the translation memory examples.
            - The script and the lines before the ones to translate are context only.
            - Translate what is said. Never soften, sanitize or replace a violent, sexual or profane line with something milder \
            or different ("Stop raping" is never "stop joking"). \(registerRule(request.style.register))
            - Names: spell each person's and place's name the same way in every line, as the known people and the glossary \
            give it. Transliterate names; never translate them (a horse called Thunder keeps its name).
            \(sourceRule(request))
            - For a flagged line, "confidence" (0 to 1) is how sure you are of the recommendation, and "note" says why in \
            a few words. Leave "reasons", "note" and "variants" empty for lines that read one way only.
            - In "cast", list the people you can identify in these lines and the context: their name as the dialogue uses \
            it, "translation", how you spell it in \(target), their gender when the dialogue makes it clear, and every voice \
            label that is mostly theirs (one person often has several).
            """
        if request.leavesOutWalla {
            prompt += """

                - Walla is background crowd chatter mixed under the dialogue: voices in a crowd, market, tavern, feast or \
                battle that nobody in the scene is talking with ("Get a load of this fella!" from the crowd while the main \
                characters talk, shouts from spectators, onlookers' remarks). Subtitles leave it out. Set "walla" to true \
                for such a line and leave "text" empty. Lines marked "dB under the dialogue" were that much quieter in the \
                audio than the dialogue around them: voices in the background. From 10 dB under, a line is walla unless a \
                character in the scene answers it or the scene turns on it (a herald's call, a chant the scene is about). \
                Set "walla" to false for every other line.
                """
        }
        if request.leavesOutFictionalLanguages {
            prompt += """

                - Some characters speak a made-up language: High Valyrian or Dothraki in Game of Thrones, Klingon in Star \
                Trek, Elvish, Na'vi. The transcript only guesses at it, as nonsense words or a phonetic spelling \
                ("Zaldrīzes buzdari iksos daor", "Athchomar chomakaan"), often with words in [brackets?]. Subtitles leave \
                it out. Set "fictional_language" to true for a line that is mostly such speech and leave "text" empty. A \
                \(Languages.name(request.sourceLanguage)) line with an invented word or name in it ("Tell the khal", \
                "Dracarys!" as a known command) is not such a line: translate it. Nor is mumbled or misheard \
                \(Languages.name(request.sourceLanguage)). Set "fictional_language" to false for every other line.
                """
        }
        if TranslationStyle.endsLinesBare(request.targetLanguage) || request.style.namesInParentheses {
            var style: [String] = []
            if TranslationStyle.endsLinesBare(request.targetLanguage), request.style.dropsFinalPunctuation {
                style.append("No full stop or comma at the end of a line; keep question and exclamation marks.")
            }
            style.append("Leave out hesitations (um, uh) and keep at most one repeat of a stutter.")
            style.append("Put quoted speech, someone imitating another person, and song lyrics in quotation marks.")
            if request.style.namesInParentheses { style.append("Put names in parentheses, e.g. (دانك).") }
            prompt += "\n- House style for \(target): " + style.joined(separator: " ")
        }
        if request.targetIsGendered {
            prompt += """

                - \(target) changes "you", imperatives, verbs, adjectives and pronouns for the gender and number of the person \
                spoken to, and first-person agreement for the speaker's gender. Work out who speaks and who is spoken to \
                from the scene: who spoke just before, names and forms of address, later "he"/"she" references, plural or dual \
                address, and the known people listed with the lines. Voice labels come from automatic speaker detection and are \
                only a hint: one person is sometimes split over several labels, and two people sometimes share one. Work out \
                who is who from names and context, not from the labels alone.
                - Keep who is spoken to the same through a scene: once a listener's gender is clear (an animal called "girl" \
                or "boy" too), keep it for later lines to them. One person talking to one person is singular unless the scene \
                shows more listeners; use the dual when two people are named or addressed together. This decides which \
                variant you recommend; it does not replace the flag. These listener and gender choices are what the user \
                reviews, so flag them whenever the line itself leaves them open.
                - Flag every line whose \(target) wording changes with who is spoken to, who speaks or who is spoken about, \
                unless the line itself settles it (a name or form of address in it, "sir", "my lady", "boys"). That is not only \
                "you": imperatives ("Leave the food and go"), verbs and adjectives about the listener ("Are you ready?", \
                "Well done"), first-person agreement ("I'm tired"), and pronouns or adjectives about a third person. Flag \
                these even when the scene makes you fairly sure: the user confirms them with one click. The reasons are the \
                listener's gender or number ("listener"), gendered words about the speaker or someone else ("genderedWords"), \
                or an unclear speaker ("speaker"); put them in "reasons".
                - For a flagged line, write every valid variant in "variants", the one you recommend first; "text" is that first \
                variant's text. Only list variants whose wording differs. For each, say who it assumes speaks ("speaker", a \
                name or ""), their gender, who is spoken to ("listeners", names, empty when unknown) and their gender and number. \
                Say it in "note" with names where you know them, e.g. "Beth is talking to Morty".
                - People marked "confirmed" are facts the translator's user settled: never contradict them.
                """
        }
        return prompt
    }

    /// How far to trust the source: a subtitle file's words are right; a transcript is sometimes misheard.
    static func sourceRule(_ request: TranslationRequest) -> String {
        if request.sourceIsSubtitles {
            return """
                - The source is a subtitle file: its words and names are right. Translate them as written, and never flag \
                a line with the reason "source".
                """
        }
        return """
                - The source is an automatic transcript and is sometimes misheard. Words in [brackets?] are ones the transcriber \
                was unsure of. When a line is ungrammatical or garbled, or does not fit the scene (a reply that answers nothing, \
                a name nobody has), do not smooth it over: flag it with the reason "source", and give one variant for what you \
                think was said, with "source" set to that line in \(Languages.name(request.sourceLanguage)), and one for the line \
                as heard, with "source" set to the line as heard. Recommend the likelier one first, and say in "note" what you \
                think was said. A misheard name the script or the known people make clear ("Aryan" for Aerion, "Dawn" for \
                Dorne) is not a doubt: translate the right name and do not flag the line. Flag "source" only when you cannot \
                tell which reading is meant.
                """
    }

    static func registerRule(_ register: TranslationStyle.Register) -> String {
        switch register {
        case .faithful:
            "Keep the register: profanity stays profanity."
        case .broadcast:
            "Use the conventions of broadcast subtitles: milder, conventional wording for profanity and sexual terms, with the same meaning."
        }
    }

    /// The whole episode's source, one line each with its time and voice, nil without one.
    static func scriptText(for request: TranslationRequest) -> String? {
        guard !request.script.isEmpty else { return nil }
        var text = "The whole episode's source, for context (time, voice, line):\n"
        for line in request.script {
            let seconds = Int(line.start.seconds)
            text += String(format: "[%d:%02d] ", seconds / 60, seconds % 60) + "\(line.voice ?? "?"): \(sourceLine(line.text))\n"
        }
        return text
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
            for example in examples.prefix(20) { text += "- \(sourceLine(example.source)) → \(sourceLine(example.target))\n" }
            text += "\n"
        }
        if !request.cast.isEmpty {
            text += "Known people:\n"
            for person in request.cast {
                var facts: [String] = []
                if request.targetIsGendered {
                    facts.append(person.gender == .unknown ? "gender unknown" : person.gender.rawValue)
                    if person.isConfirmed { facts.append("confirmed") }
                    if !person.voices.isEmpty { facts.append("voice \(person.voices.joined(separator: ", "))") }
                }
                let spelling = person.translatedName.map { " → \($0)" } ?? ""
                text += "- \(person.name)\(spelling)\(facts.isEmpty ? "" : " (\(facts.joined(separator: ", ")))")\n"
            }
            text += "\n"
        }
        if !request.precedingContext.isEmpty {
            text += "Previous lines (context only, already translated):\n"
            for line in request.precedingContext { text += "- \(sourceLine(line.source)) → \(sourceLine(line.target))\n" }
            text += "\n"
        }
        let scenes = scenes(around: request)
        if !scenes.isEmpty {
            text += "The scenes these lines are in, from the brief:\n"
            for scene in scenes { text += "- \(scene.isFromVideo ? "Seen: " : "")\(scene.text)\n" }
            text += "\n"
        }
        text += "Lines to translate (id | time | voice | text):\n"
        for (index, line) in request.lines.enumerated() {
            var voice = line.voices.map { $0.map { named($0, in: request.cast) }.joined(separator: " then ") } ?? "?"
            if let name = line.speakerName { voice += " (\(name))" }
            if request.leavesOutWalla, let quieter = line.quieterBy, quieter >= Self.wallaHintDecibels {
                voice += ", \(Int(quieter)) dB under the dialogue"
            }
            let time = String(format: "%.1fs", line.start.seconds)
            text += "\(lineID(index)) | \(time) | \(voice) | \(sourceLine(marking: line.unsureWords, in: line.source))\n"
        }
        return text
    }

    static func lineID(_ index: Int) -> String { "L\(index + 1)" }

    /// A voice label with the name of the person it belongs to: "speaker_1 (Dunk)" when
    /// the user confirmed it, "speaker_1 (Dunk?)" when the cast only guesses.
    static func named(_ voice: String, in cast: [CastMember]) -> String {
        let owners = cast.filter { $0.voices.contains(voice) && !$0.name.isEmpty }
        guard let person = owners.first(where: \.isConfirmed) ?? (owners.count == 1 ? owners.first : nil) else { return voice }
        return "\(voice) (\(person.name)\(person.isConfirmed ? "" : "?"))"
    }

    /// The brief's scenes the lines fall in: of the dialogue's and of the video's, the
    /// one under way at the first line and those starting before the last line ends.
    static func scenes(around request: TranslationRequest) -> [EpisodeBrief.TimedScene] {
        guard let first = request.lines.map(\.start).min(), let last = request.lines.map(\.end).max() else { return [] }
        return [false, true].flatMap { fromVideo in
            let list = request.scenes.filter { $0.isFromVideo == fromVideo }
            let current = list.last { $0.start <= first }
            return list.filter { $0 == current || ($0.start > first && $0.start < last) }
        }
        .sorted { $0.start < $1.start }
    }

    /// Lines this far (dB) under the dialogue around them are marked for the translator as background voices.
    static let wallaHintDecibels: Float = 10

    /// A line with its breaks written "\\n", as the answer writes them. (A " / "
    /// for a break was copied into translations.)
    static func sourceLine(_ text: String) -> String {
        text.replacing("\n", with: "\\n")
    }

    /// The line with the words the transcriber was unsure of in brackets: "You'll [late?], master."
    static func sourceLine(marking unsure: [String]?, in text: String) -> String {
        var marked = text
        for word in Set(unsure ?? []) where !word.isEmpty {
            let pattern = "(?<![\\p{L}\\p{N}])(" + NSRegularExpression.escapedPattern(for: word) + ")(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            marked = regex.stringByReplacingMatches(in: marked, range: NSRange(marked.startIndex..., in: marked), withTemplate: "[$1?]")
        }
        return sourceLine(marked)
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
                var text: String
                var speaker: String?
                var speaker_gender: String?
                var listeners: [String]?
                var listener_gender: String?
                var listener_count: String?
                var source: String?
            }

            var id: String
            var text: String
            var reasons: [String]?
            var confidence: Double?
            var note: String?
            var variants: [Variant]?
            var walla: Bool?
            var fictional_language: Bool?
        }

        struct Person: Decodable {
            var name: String
            var translation: String?
            var gender: String?
            var voices: [String]?
        }

        var translations: [Item]
        var cast: [Person]?
    }

    static func translations(from data: Data, request: TranslationRequest) throws -> TranslationBatch {
        let response = try JSONDecoder().decode(Response.self, from: data)
        if response.stop_reason == "refusal" { throw AIError.declined }
        if response.stop_reason == "max_tokens" { throw AIError.cutOff }
        let texts = response.content.filter { $0.type == "text" }.compactMap(\.text)
        guard !texts.isEmpty else { throw AIError.provider("Claude sent no translation.") }
        // The answer is the last text block that reads as one.
        guard let output = texts.reversed().lazy.compactMap({ try? JSONDecoder().decode(Output.self, from: Data($0.utf8)) }).first else {
            throw AIError.provider("Claude's answer could not be read.")
        }
        return batch(from: output, request: request)
    }

    /// The answer's translations mapped back to the cues, with their flags, and the cast.
    static func batch(from output: Output, request: TranslationRequest) -> TranslationBatch {
        let ids = Dictionary(uniqueKeysWithValues: request.lines.enumerated().map { (lineID($0.offset), $0.element.cueID) })
        let translations: [CueTranslation] = output.translations.compactMap { item in
            guard let cueID = ids[item.id] else { return nil }
            if request.leavesOutWalla, item.walla == true { return .walla(cueID) }
            if request.leavesOutFictionalLanguages, item.fictional_language == true { return .fictionalLanguage(cueID) }
            let text = item.text.replacing("\\n", with: "\n")
            var translation = CueTranslation(cueID: cueID, text: text)
            translation.flag = flag(from: item, text: text, cast: request.cast, gendered: request.targetIsGendered)
            // A reading the translator is sure of (usually a misheard name) is used, not asked about.
            if let flag = translation.flag, flag.reasons == [.source], flag.confidence >= Self.sureOfSource { translation.flag = nil }
            if let chosen = translation.flag?.chosenVariant { translation.text = chosen.text }
            return translation
        }
        let cast = (output.cast ?? []).map { person in
            CastMember(
                name: person.name, gender: person.gender.flatMap(Gender.init(rawValue:)) ?? .unknown, voices: person.voices ?? [],
                translatedName: person.translation.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            )
        }
        return TranslationBatch(translations: translations, cast: cast)
    }

    /// The flag for a line, when it has reasons and at least two different wordings.
    /// The recommended text comes first, and variants the confirmed cast rules out go last.
    /// Into a language without gendered address, only a possibly misheard source is flagged.
    static func flag(from item: Output.Item, text: String, cast: [CastMember], gendered: Bool = true) -> TranslationFlag? {
        let reasons = (item.reasons ?? []).compactMap(TranslationFlag.Reason.init(rawValue:)).filter { gendered || $0 == .source }
        guard !reasons.isEmpty else { return nil }
        var variants: [TranslationVariant] = []
        for variant in item.variants ?? [] {
            let wording = variant.text.replacing("\\n", with: "\n")
            guard !wording.isEmpty, !variants.contains(where: { $0.text == wording }) else { continue }
            let speaker = variant.speaker?.trimmingCharacters(in: .whitespaces)
            variants.append(TranslationVariant(
                text: wording, speaker: speaker?.isEmpty == false ? speaker : nil,
                speakerGender: variant.speaker_gender.flatMap(Gender.init(rawValue:)) ?? .unknown,
                listeners: (variant.listeners ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                listenerGender: variant.listener_gender.flatMap(Gender.init(rawValue:)) ?? .unknown,
                listenerCount: variant.listener_count.flatMap(ListenerCount.init(rawValue:)) ?? .unknown,
                // Only a possibly misheard line's variants are about the source; others repeat it.
                assumedSource: reasons.contains(.source)
                    ? variant.source.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.replacing("\\n", with: "\n") } : nil
            ))
        }
        // The text is the recommendation: first, whatever order the variants came in.
        if let index = variants.firstIndex(where: { $0.text == text }) {
            variants.insert(variants.remove(at: index), at: 0)
        } else {
            variants.insert(TranslationVariant(text: text), at: 0)
        }
        guard variants.count > 1 else { return nil }
        let confidence = ((min(max(item.confidence ?? 0.5, 0), 1)) * 100).rounded() / 100
        var flag = TranslationFlag(reasons: reasons, variants: variants, confidence: confidence, note: item.note ?? "")
        flag.rerank(with: cast)
        return flag
    }
}

// MARK: - OpenAI

/// Cloud translation with OpenAI's GPT-6 Luna (the Responses API), far cheaper than
/// Claude. It gets Claude's prompt and answers in the same JSON schema (strict
/// structured outputs), so lines are flagged with variants and the cast builds the same way.
public struct OpenAITranslator: BatchedCueTranslator {
    public var name: String { model == Self.defaultModel ? "OpenAI GPT-6 Luna (cloud)" : "OpenAI \(model) (cloud)" }
    public static let defaultModel = "gpt-6-luna"
    let model: String
    let effort: AISettings.ReasoningEffort
    let apiKey: String
    let http: HTTPClient
    var endpoint = URL(string: "https://api.openai.com/v1/responses")!
    var batchSize = 40
    var contextLines = 20

    public init(
        apiKey: String, model: String = OpenAITranslator.defaultModel, effort: AISettings.ReasoningEffort = .medium,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.effort = effort
        http = HTTPClient(session: session)
    }

    func translateBatch(_ request: TranslationRequest) async throws -> TranslationBatch {
        var urlRequest = URLRequest(url: endpoint, timeoutInterval: 600)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: Self.body(for: request, model: model, effort: effort))
        let data = try await http.send(urlRequest)
        return try Self.translations(from: data, request: request)
    }

    /// The Responses API request. `store` is off, so OpenAI keeps no copy of the dialogue
    /// for the dashboard. The reasoning effort is a setting (Settings › AI).
    static func body(
        for request: TranslationRequest, model: String = defaultModel, effort: AISettings.ReasoningEffort = .medium
    ) -> [String: Any] {
        [
            "model": model,
            // The script last, so OpenAI's automatic prompt caching reuses rules and script for every batch.
            "instructions": [ClaudeTranslator.systemPrompt(for: request), ClaudeTranslator.scriptText(for: request)]
                .compactMap { $0 }.joined(separator: "\n\n"),
            "input": ClaudeTranslator.userPrompt(for: request),
            "max_output_tokens": 32000,
            "reasoning": ["effort": effort.rawValue],
            "store": false,
            "text": ["format": [
                "type": "json_schema", "name": "subtitle_translations", "strict": true,
                "schema": ClaudeTranslator.outputSchema(for: request),
            ]],
        ]
    }

    struct Response: Decodable {
        struct Item: Decodable {
            struct Content: Decodable {
                var type: String
                var text: String?
            }

            var type: String
            var content: [Content]?
        }

        struct Incomplete: Decodable {
            var reason: String?
        }

        var status: String?
        var output: [Item]
        var incomplete_details: Incomplete?
    }

    static func translations(from data: Data, request: TranslationRequest) throws -> TranslationBatch {
        let response = try JSONDecoder().decode(Response.self, from: data)
        let contents = response.output.filter { $0.type == "message" }.flatMap { $0.content ?? [] }
        if contents.contains(where: { $0.type == "refusal" }) { throw AIError.declined }
        if response.status == "incomplete" {
            throw response.incomplete_details?.reason == "content_filter" ? AIError.declined : AIError.cutOff
        }
        let texts = contents.filter { $0.type == "output_text" }.compactMap(\.text)
        guard !texts.isEmpty else { throw AIError.provider("OpenAI sent no translation.") }
        guard let output = texts.reversed().lazy.compactMap({ try? JSONDecoder().decode(ClaudeTranslator.Output.self, from: Data($0.utf8)) }).first else {
            throw AIError.provider("OpenAI's answer could not be read.")
        }
        return ClaudeTranslator.batch(from: output, request: request)
    }
}

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
        _ audio: PreparedAudio, language: String?, progress: @escaping @Sendable (Double) -> Void,
        found: @escaping @Sendable ([TranscribedWord]) -> Void
    ) async throws -> [TranscribedWord] {
        let chunks = audio.chunks
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
    let apiKey: String
    let http: HTTPClient
    var endpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        http = HTTPClient(session: session)
    }

    public func transcribe(
        _ audio: PreparedAudio, language: String?, progress: @escaping @Sendable (Double) -> Void,
        found: @escaping @Sendable ([TranscribedWord]) -> Void
    ) async throws -> [TranscribedWord] {
        let encoded = try OpusEncoder.oggOpus(Self.samples(of: audio))
        progress(0.1)
        let boundary = "spotline-\(UUID().uuidString)"
        var form = MultipartForm(boundary: boundary)
        form.add(name: "model_id", value: Self.model)
        form.add(name: "timestamps_granularity", value: "word")
        form.add(name: "tag_audio_events", value: "false")
        // Who says each word, so a cue two people speak in becomes a dialogue cue.
        form.add(name: "diarize", value: "true")
        if let language { form.add(name: "language_code", value: Languages.base(language)) }
        form.add(name: "file", filename: "dialogue.ogg", contentType: "audio/ogg", data: encoded)
        var request = URLRequest(url: endpoint, timeoutInterval: 1800)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finish()
        let words = try Self.words(from: await http.send(request))
        found(words)
        progress(1)
        return words
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

            enum CodingKeys: String, CodingKey {
                case text, type, start, end
                case speakerID = "speaker_id"
            }
        }

        var words: [Word]
    }

    /// Words only (not spacing or sound events), with the punctuation Scribe attaches to them.
    static func words(from data: Data) throws -> [TranscribedWord] {
        try JSONDecoder().decode(Response.self, from: data).words.compactMap { word in
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard word.type == "word", !text.isEmpty, let start = word.start else { return nil }
            let begin = MediaTime(value: Int64((start * 1000).rounded()), timescale: 1000)
            let end = MediaTime(value: Int64(((word.end ?? start) * 1000).rounded()), timescale: 1000)
            return TranscribedWord(text: text, start: begin, end: max(end, begin), speaker: word.speakerID)
        }
        .sorted { $0.start < $1.start }
    }
}

/// Counts finished chunks, reports the fraction, and passes on their words in
/// time order: chunks finish out of order, so each waits for the ones before it.
private actor ProgressCounter {
    let total: Int
    let report: @Sendable (Double) -> Void
    let found: @Sendable ([TranscribedWord]) -> Void
    var done = 0
    var waiting: [Int: [TranscribedWord]] = [:]
    var nextToPass = 0

    init(total: Int, report: @escaping @Sendable (Double) -> Void, found: @escaping @Sendable ([TranscribedWord]) -> Void) {
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
/// the transcriber's voice labels, the cast known so far and the QC limits.
///
/// Into languages that inflect for gender or number (Arabic first), Claude flags
/// every line that could be translated more than one way ("you" for a man, a
/// woman or a group; gendered verbs and adjectives; an unclear speaker), writes
/// every valid variant, recommends one from the scene and says why in a line.
/// It also names the people it recognizes, which builds the cast.
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

    public func translate(
        _ request: TranslationRequest, progress: @escaping @Sendable (Double) -> Void,
        found: @escaping @Sendable (TranslationBatch) -> Void
    ) async throws -> TranslationBatch {
        var results = TranslationBatch(cast: request.cast)
        var context = request.precedingContext
        // A small first batch shows results quickly.
        for range in AppleTranslator.batches(of: request.lines.count, first: 10, size: batchSize) {
            try Task.checkCancellation()
            let lines = Array(request.lines[range])
            var batch = request
            batch.lines = lines
            batch.precedingContext = Array(context.suffix(contextLines))
            // People named in earlier batches go along, so later lines use the same names.
            batch.cast = results.cast
            let translated = try await translateBatch(batch)
            results = results.adding(translated)
            found(translated)
            for line in lines {
                if let text = translated.translations.first(where: { $0.cueID == line.cueID })?.text { context.append((line.source, text)) }
            }
            progress(Double(results.translations.count) / Double(max(request.lines.count, 1)))
        }
        return results
    }

    func translateBatch(_ request: TranslationRequest) async throws -> TranslationBatch {
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

    static let genderValues = Gender.allCases.map(\.rawValue)
    static let personGenderValues = [Gender.male, .female, .unknown].map(\.rawValue)
    static let countValues = ListenerCount.allCases.map(\.rawValue)
    static let reasonValues = TranslationFlag.Reason.allCases.map(\.rawValue)

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
    static func body(for request: TranslationRequest) -> [String: Any] {
        var item: [String: Any] = ["id": string, "text": string]
        var output: [String: Any] = [:]
        if request.targetIsGendered {
            item["reasons"] = array(oneOf(reasonValues))
            item["confidence"] = ["type": "number"]
            item["note"] = string
            item["variants"] = array(object([
                "text": string, "speaker": string, "speaker_gender": oneOf(personGenderValues),
                "listeners": array(string), "listener_gender": oneOf(genderValues), "listener_count": oneOf(countValues),
            ]))
            output["cast"] = array(object(["name": string, "gender": oneOf(personGenderValues), "voices": array(string)]))
        }
        output["translations"] = array(object(item))
        return [
            "model": model,
            "max_tokens": 32000,
            "fallbacks": "default",
            "output_config": ["effort": "medium", "format": ["type": "json_schema", "schema": object(output)]],
            "system": systemPrompt(for: request),
            "messages": [["role": "user", "content": userPrompt(for: request)]],
        ]
    }

    static func systemPrompt(for request: TranslationRequest) -> String {
        let target = Languages.name(request.targetLanguage)
        var prompt = """
            You are a professional subtitle translator. Translate film and TV subtitles from \(Languages.name(request.sourceLanguage)) \
            into \(target) for on-screen delivery: natural, idiomatic dialogue that reads quickly, \
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

                - \(target) changes "you", imperatives, verbs, adjectives and pronouns for the gender and number of the person \
                spoken to, and first-person agreement for the speaker's gender. Work out who speaks and who is spoken to \
                from the scene: who spoke just before, names and forms of address, later "he"/"she" references, plural or dual \
                address, and the known people listed with the lines. Voice labels come from automatic speaker detection and are \
                only a hint: one person is sometimes split over several labels, and two people sometimes share one.
                - Flag every line whose \(target) wording depends on something the source leaves open: the listener's gender \
                or number ("listener"), gendered verbs, adjectives or pronouns about someone ("genderedWords"), or who says it \
                ("speaker"). Put the reasons in "reasons"; leave it empty for a line that reads one way only.
                - For a flagged line, write every valid variant in "variants", the one you recommend first; "text" is that first \
                variant's text. Only list variants whose wording differs. For each, say who it assumes speaks ("speaker", a \
                name or ""), their gender, who is spoken to ("listeners", names, empty when unknown) and their gender and number.
                - For a flagged line, "confidence" (0 to 1) is how sure you are of the recommendation, and "note" says why in \
                a few words with names where you know them, e.g. "Beth is talking to Morty". Leave "note" empty and "variants" \
                empty for lines that are not flagged.
                - People marked "confirmed" are facts the translator's user settled: never contradict them.
                - In "cast", list the people you can identify in these lines and the context: their name as the dialogue uses \
                it, their gender when the dialogue makes it clear, and the voice labels that are mostly theirs.
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
        if request.targetIsGendered, !request.cast.isEmpty {
            text += "Known people:\n"
            for person in request.cast {
                var facts = [person.gender == .unknown ? "gender unknown" : person.gender.rawValue]
                if person.isConfirmed { facts.append("confirmed") }
                if !person.voices.isEmpty { facts.append("voice \(person.voices.joined(separator: ", "))") }
                text += "- \(person.name) (\(facts.joined(separator: ", ")))\n"
            }
            text += "\n"
        }
        if !request.precedingContext.isEmpty {
            text += "Previous lines (context only, already translated):\n"
            for line in request.precedingContext { text += "- \(oneLine(line.source)) → \(oneLine(line.target))\n" }
            text += "\n"
        }
        text += "Lines to translate (id | time | voice | text):\n"
        for (index, line) in request.lines.enumerated() {
            var voice = line.voices.map { $0.joined(separator: " then ") } ?? "?"
            if let name = line.speakerName { voice += " (\(name))" }
            let time = String(format: "%.1fs", line.start.seconds)
            text += "\(lineID(index)) | \(time) | \(voice) | \(oneLine(line.source))\n"
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
                var text: String
                var speaker: String?
                var speaker_gender: String?
                var listeners: [String]?
                var listener_gender: String?
                var listener_count: String?
            }

            var id: String
            var text: String
            var reasons: [String]?
            var confidence: Double?
            var note: String?
            var variants: [Variant]?
        }

        struct Person: Decodable {
            var name: String
            var gender: String?
            var voices: [String]?
        }

        var translations: [Item]
        var cast: [Person]?
    }

    static func translations(from data: Data, request: TranslationRequest) throws -> TranslationBatch {
        let response = try JSONDecoder().decode(Response.self, from: data)
        if response.stop_reason == "refusal" { throw AIError.provider("Claude declined to translate these lines.") }
        if response.stop_reason == "max_tokens" { throw AIError.provider("Claude's answer was cut off. Try fewer lines at once.") }
        guard let json = response.content.first(where: { $0.type == "text" })?.text else {
            throw AIError.provider("Claude sent no translation.")
        }
        let output = try JSONDecoder().decode(Output.self, from: Data(json.utf8))
        let ids = Dictionary(uniqueKeysWithValues: request.lines.enumerated().map { (lineID($0.offset), $0.element.cueID) })
        let translations: [CueTranslation] = output.translations.compactMap { item in
            guard let cueID = ids[item.id] else { return nil }
            let text = item.text.replacing("\\n", with: "\n")
            var translation = CueTranslation(cueID: cueID, text: text)
            if request.targetIsGendered { translation.flag = flag(from: item, text: text, cast: request.cast) }
            if let chosen = translation.flag?.chosenVariant { translation.text = chosen.text }
            return translation
        }
        let cast = (output.cast ?? []).map { person in
            CastMember(name: person.name, gender: person.gender.flatMap(Gender.init(rawValue:)) ?? .unknown, voices: person.voices ?? [])
        }
        return TranslationBatch(translations: translations, cast: cast)
    }

    /// The flag for a line, when it has reasons and at least two different wordings.
    /// The recommended text comes first, and variants the confirmed cast rules out go last.
    static func flag(from item: Output.Item, text: String, cast: [CastMember]) -> TranslationFlag? {
        let reasons = (item.reasons ?? []).compactMap(TranslationFlag.Reason.init(rawValue:))
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
                listenerCount: variant.listener_count.flatMap(ListenerCount.init(rawValue:)) ?? .unknown
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

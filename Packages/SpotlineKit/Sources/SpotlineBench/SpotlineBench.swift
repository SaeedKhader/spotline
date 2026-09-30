import AIQuality
import AITools
import Foundation
import MediaAnalysis
import QualityControl
import SubtitleCore
import SubtitleFormats
import SubtitleTranslation

/// `spotline-bench`: runs Spotline's transcription and translation on sample
/// clips that have real subtitles, and scores the output against them.
///
/// A samples folder holds, per clip, the video and its reference subtitles
/// named by language: `scene.mkv`, `scene.en.srt`, `scene.ar.srt`. Without a
/// sidecar file, a text subtitle track in the video with that language is used.
/// An optional `glossary.csv` (or `scene.glossary.csv`) is passed to the translator.
///
/// Samples are usually copyrighted: keep them outside the repository. Model
/// results are cached in the folder's `.bench-cache`, so rule changes re-score
/// in seconds; `--fresh` runs the models again. Reports go to `reports/`.
@main
struct SpotlineBench {
    static let usage = """
        Usage: spotline-bench <samples folder> [options]
          --label NAME           name of this run (default: "run")
          --compare REPORT.json  put an earlier run beside this one
          --only NAME            only samples whose name contains NAME
          --source CODE          spoken language and reference source subtitles (default: en)
          --target CODE          translation language and reference (default: ar)
          --transcriber NAME     apple (default), whisper or scribe (keys from Settings › AI, else OPENAI_API_KEY, ELEVENLABS_API_KEY)
          --translator NAME      apple (default), claude (Opus), claude-sonnet (key from Settings › AI, else ANTHROPIC_API_KEY)
                                 or luna (OpenAI GPT-6 Luna; else OPENAI_API_KEY)
          --preset ID            QC preset: netflix (default), netflixChildren, broadcast, basic
          --skip-translation     transcription only
          --fresh                ignore cached model results
          --allow-model-download let macOS download a missing speech model
        """

    static func main() async {
        do {
            let options = try Options(Array(CommandLine.arguments.dropFirst()))
            try await Benchmark(options: options).run()
        } catch let error as Options.Error {
            FileHandle.standardError.write(Data("\(error.message)\n\n\(usage)\n".utf8))
            exit(2)
        } catch {
            FileHandle.standardError.write(Data("spotline-bench: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}

struct Options {
    struct Error: Swift.Error { var message: String }

    var folder: URL
    var label = "run"
    var compare: URL?
    var only: String?
    var source = "en"
    var target = "ar"
    var transcriber = "apple"
    var translator = "apple"
    var preset = QCPreset.standard
    var skipTranslation = false
    var fresh = false
    var allowModelDownload = false

    init(_ arguments: [String]) throws {
        var rest = arguments[...]
        var folder: URL?
        func value(_ flag: String) throws -> String {
            guard let next = rest.popFirst() else { throw Error(message: "\(flag) needs a value.") }
            return next
        }
        while let argument = rest.popFirst() {
            switch argument {
            case "--label": label = try value(argument)
            case "--compare": compare = URL(fileURLWithPath: try value(argument))
            case "--only": only = try value(argument)
            case "--source": source = try value(argument)
            case "--target": target = try value(argument)
            case "--transcriber": transcriber = try value(argument)
            case "--translator": translator = try value(argument)
            case "--preset":
                let id = try value(argument)
                guard let found = QCPreset.named(id) else { throw Error(message: "No preset \(id).") }
                preset = found
            case "--skip-translation": skipTranslation = true
            case "--fresh": fresh = true
            case "--allow-model-download": allowModelDownload = true
            case "-h", "--help": throw Error(message: "")
            default:
                guard !argument.hasPrefix("-"), folder == nil else { throw Error(message: "Unknown option \(argument).") }
                folder = URL(fileURLWithPath: (argument as NSString).expandingTildeInPath)
            }
        }
        guard let folder else { throw Error(message: "Which samples folder?") }
        self.folder = folder
    }
}

/// One clip and its references.
struct Sample {
    var name: String
    var video: URL
    var sourceReference: SubtitleTrack?
    var targetReference: SubtitleTrack?
    var glossary: Glossary?
    var notes: [String] = []

    static let videoExtensions: Set<String> = ["mkv", "mp4", "m4v", "mov", "avi", "webm", "ts", "mts"]

    static func find(in folder: URL, source: String, target: String, only: String?) throws -> [Sample] {
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let shared = folder.appending(path: "glossary.csv")
        return try files.filter { videoExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .filter { only == nil || $0.lastPathComponent.localizedCaseInsensitiveContains(only!) }
            .map { video in
                let name = video.deletingPathExtension().lastPathComponent
                var sample = Sample(name: name, video: video)
                sample.sourceReference = try reference(for: name, language: source, in: files, video: video, notes: &sample.notes)
                sample.targetReference = try reference(for: name, language: target, in: files, video: video, notes: &sample.notes)
                let own = folder.appending(path: "\(name).glossary.csv")
                for url in [shared, own] where FileManager.default.fileExists(atPath: url.path) {
                    var glossary = sample.glossary ?? Glossary()
                    glossary.merge(Glossary.entries(fromDelimited: try String(contentsOf: url, encoding: .utf8)))
                    sample.glossary = glossary
                }
                return sample
            }
    }

    /// `name.<language>.<subtitle extension>`, else the video's text track in that language.
    static func reference(for name: String, language: String, in files: [URL], video: URL, notes: inout [String]) throws -> SubtitleTrack? {
        let prefix = "\(name).\(language)."
        if let file = files.first(where: {
            $0.lastPathComponent.hasPrefix(prefix) && SubtitleFormat(fileExtension: $0.pathExtension) != nil
        }) {
            var track = try SubtitleFile.read(from: file).track
            track.languageCode = language
            return track
        }
        let embedded = (try? MediaAnalyzer.subtitleTracks(in: video)) ?? []
        let matching = embedded.filter { $0.isText && !$0.isForced && Languages.base($0.language ?? "") == Languages.base(language) }
        // Prefer plain subtitles over SDH (their descriptions are not speech).
        guard let track = matching.first(where: { !$0.isHearingImpaired }) ?? matching.first else {
            notes.append("no \(language) reference")
            return nil
        }
        notes.append("\(language) reference from the video's track \(track.streamIndex)")
        var result = try MediaAnalyzer.subtitles(in: video, streamIndex: track.streamIndex)
        result.languageCode = language
        return result
    }
}

/// Model results kept between runs, so changes to Spotline's own rules re-score quickly.
struct Cache {
    var folder: URL
    var enabled: Bool

    struct Translation: Codable {
        var text: String
        var flag: TranslationFlag?
    }

    func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard enabled, let data = try? Data(contentsOf: folder.appending(path: name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func store(_ value: some Encodable, _ name: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: folder.appending(path: name), options: .atomic)
    }
}

struct Benchmark {
    var options: Options

    var cache: Cache { Cache(folder: options.folder.appending(path: ".bench-cache"), enabled: !options.fresh) }

    func log(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    func run() async throws {
        let samples = try Sample.find(in: options.folder, source: options.source, target: options.target, only: options.only)
        guard !samples.isEmpty else { throw Options.Error(message: "No videos in \(options.folder.path).") }
        let transcriber = try makeTranscriber()
        let translator = try makeTranslator()
        let stamp = Self.stamp.string(from: Date())
        let output = options.folder.appending(path: "reports/\(stamp)-\(options.label.replacing(" ", with: "-"))")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        var report = BenchmarkReport(label: options.label, settings: [
            "transcription": transcriber.name, "translation": options.skipTranslation ? "skipped" : translator.name,
            "preset": options.preset.name, "languages": "\(options.source) to \(options.target)",
        ])
        for sample in samples {
            log("\(sample.name):")
            var result = BenchmarkReport.Sample(name: sample.name, notes: sample.notes)
            do {
                let media = try await analyze(sample)
                if let reference = sample.sourceReference {
                    let cues = try await transcribe(sample, media: media, with: transcriber)
                    try SubtitleFile.write(cues, as: .srt, frameRate: media.frameRate, to: output.appending(path: "\(sample.name).\(options.source).srt"))
                    result.transcription = Scoring.transcription(
                        hypothesis: cues, reference: reference.cues, preset: options.preset, context: media.context
                    )
                    log("  word error rate \(BenchmarkReport.percent(result.transcription!.wordErrorRate))")
                }
                if !options.skipTranslation, let source = sample.sourceReference, let target = sample.targetReference {
                    let (cues, score) = try await translate(
                        sample, source: source, reference: target, media: media, with: translator, words: cachedWords(sample, transcriber: transcriber)
                    )
                    let flagged = cues.filter { $0.flag != nil }.count
                    if flagged > 0 { result.notes.append("\(flagged) lines flagged with variants") }
                    try SubtitleFile.write(cues, as: .srt, frameRate: media.frameRate, to: output.appending(path: "\(sample.name).\(options.target).srt"))
                    result.translation = score
                    log("  chrF \(BenchmarkReport.plain(score.chrF.score))")
                }
            } catch {
                result.notes.append("failed: \(error.localizedDescription)")
                log("  failed: \(error.localizedDescription)")
            }
            report.samples.append(result)
        }

        let baseline = try options.compare.map { try JSONDecoder.report.decode(BenchmarkReport.self, from: Data(contentsOf: $0)) }
        let markdown = report.markdown(comparedTo: baseline)
        try JSONEncoder.report.encode(report).write(to: output.appending(path: "report.json"))
        try markdown.write(to: output.appending(path: "report.md"), atomically: true, encoding: .utf8)
        print(markdown)
        log("Report: \(output.appending(path: "report.md").path)")
    }

    static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()

    // MARK: Providers

    func makeTranscriber() throws -> any Transcriber {
        switch options.transcriber {
        case "apple":
            let allow = options.allowModelDownload
            return AppleSpeechTranscriber { language in
                if !allow { FileHandle.standardError.write(Data("The \(language) speech model is not installed; run again with --allow-model-download.\n".utf8)) }
                return allow
            }
        case "whisper":
            guard let key = Self.apiKey(.openAI, environment: "OPENAI_API_KEY") else { throw AIError.missingAPIKey(provider: "OpenAI") }
            return OpenAITranscriber(apiKey: key)
        case "scribe":
            guard let key = Self.apiKey(.elevenLabs, environment: "ELEVENLABS_API_KEY") else { throw AIError.missingAPIKey(provider: "ElevenLabs") }
            return ElevenLabsTranscriber(apiKey: key)
        default:
            throw Options.Error(message: "No transcriber \(options.transcriber).")
        }
    }

    func makeTranslator() throws -> any CueTranslator {
        switch options.translator {
        case "apple": return AppleTranslator()
        case "claude", "claude-sonnet":
            guard let key = Self.apiKey(.anthropic, environment: "ANTHROPIC_API_KEY") else { throw AIError.missingAPIKey(provider: "Anthropic") }
            return ClaudeTranslator(apiKey: key, model: options.translator == "claude" ? ClaudeTranslator.defaultModel : ClaudeTranslator.sonnetModel)
        case "luna":
            guard let key = Self.apiKey(.openAI, environment: "OPENAI_API_KEY") else { throw AIError.missingAPIKey(provider: "OpenAI") }
            return OpenAITranslator(apiKey: key)
        default:
            throw Options.Error(message: "No translator \(options.translator).")
        }
    }

    /// The key the app keeps in the Keychain (Settings › AI), else the environment variable.
    static func apiKey(_ provider: APIKeyStore.Provider, environment: String) -> String? {
        APIKeyStore(service: "io.github.saeedkhader.spotline.ai").key(for: provider)
            ?? ProcessInfo.processInfo.environment[environment]
    }

    static func cacheKey(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    // MARK: Media

    struct Media {
        var frameRate: FrameRate
        var shotChanges: [Int64]
        var audio: PreparedAudio

        var context: QualityControl.Context { QualityControl.Context(frameRate: frameRate, shotChanges: shotChanges) }
    }

    func analyze(_ sample: Sample) async throws -> Media {
        let rate = try MediaAnalyzer.frameRate(of: sample.video) ?? .fps23_976
        let shots: [MediaTime]
        if let cached = cache.load([MediaTime].self, "\(sample.name).shots.json") {
            shots = cached
        } else {
            log("  finding shot changes")
            do { shots = try MediaAnalyzer.shotChanges(in: sample.video) } catch MediaAnalyzer.Error.noStream { shots = [] }
            try cache.store(shots, "\(sample.name).shots.json")
        }
        log("  preparing audio")
        let audio = try MediaAnalyzer.prepareAudio(of: sample.video)
        return Media(frameRate: rate, shotChanges: shots.map { $0.nearestFrame(at: rate) }, audio: audio)
    }

    // MARK: Transcription

    /// The transcriber's words for a sample, if a run has cached them.
    func cachedWords(_ sample: Sample, transcriber: any Transcriber) -> [TranscribedWord]? {
        cache.load([TranscribedWord].self, "\(sample.name).\(Self.cacheKey(transcriber.name)).\(options.source).words.json")
    }

    /// Words from the model (cached), then cues exactly as the editor makes them.
    func transcribe(_ sample: Sample, media: Media, with transcriber: any Transcriber) async throws -> [Cue] {
        let key = "\(sample.name).\(Self.cacheKey(transcriber.name)).\(options.source).words.json"
        let words: [TranscribedWord]
        if let cached = cache.load([TranscribedWord].self, key) {
            words = cached
        } else {
            log("  transcribing with \(transcriber.name)")
            words = try await transcriber.transcribe(media.audio, language: options.source, progress: { _ in }, found: { _ in })
            try cache.store(words, key)
        }
        let pipeline = TranscriptionPipeline(
            preset: options.preset, frameRate: media.frameRate, shotChanges: media.shotChanges, wordStartLead: transcriber.wordStartLead
        )
        return pipeline.cues(from: words)
    }

    // MARK: Translation

    /// Translates the reference source cues (so translation is scored apart
    /// from transcription), with the voices the transcriber heard in each, as the editor does.
    func translate(
        _ sample: Sample, source: SubtitleTrack, reference: SubtitleTrack, media: Media, with translator: any CueTranslator,
        words: [TranscribedWord]?
    ) async throws -> ([Cue], TranslationScore) {
        // Spoken text only: SDH descriptions and speaker labels are not in a translation's reference.
        let cues = source.cues.compactMap { cue -> Cue? in
            var spoken = cue
            spoken.text = SubtitleText.visibleLines(of: cue.text).map(ScoringText.spokenText).filter { !$0.isEmpty }.joined(separator: "\n")
            return spoken.text.isEmpty ? nil : spoken
        }.sorted { $0.start < $1.start }
        let lines = cues.map { cue in
            TranslationRequest.Line(cueID: cue.id, source: cue.text, start: cue.start, end: cue.end, voices: Self.voices(in: words ?? [], during: cue))
        }
        let index = sample.glossary.map(GlossaryIndex.init)
        let glossary = (sample.glossary?.entries ?? []).filter { entry in
            cues.contains { index?.entries(inSource: $0.text).contains(entry) == true }
        }
        let request = TranslationRequest(
            lines: lines, sourceLanguage: options.source, targetLanguage: options.target,
            glossary: glossary.map { ($0.source, $0.target, $0.note) },
            maxCharactersPerLine: options.preset.maxCharactersPerLine, maxLines: options.preset.maxLines
        )

        // Cached by position: the reference cues get new IDs every run.
        let key = "\(sample.name).\(Self.cacheKey(translator.name)).\(options.source)-\(options.target).json"
        var translations: [CueTranslation]
        if let cached = cache.load([Cache.Translation].self, key), cached.count == cues.count {
            translations = zip(cues, cached).map { CueTranslation(cueID: $0.id, text: $1.text, flag: $1.flag) }
        } else {
            log("  translating with \(translator.name)")
            let found = try await translator.translate(request, progress: { _ in }, found: { _ in })
            let byID = Dictionary(found.translations.map { ($0.cueID, $0) }, uniquingKeysWith: { first, _ in first })
            translations = cues.map { byID[$0.id] ?? CueTranslation(cueID: $0.id, text: "") }
            try cache.store(translations.map { Cache.Translation(text: $0.text, flag: $0.flag) }, key)
        }
        translations = TranslationPipeline(preset: options.preset).fix(translations, request: request)

        let byID = Dictionary(translations.map { ($0.cueID, $0) }, uniquingKeysWith: { first, _ in first })
        let translated = cues.map { cue in
            var target = cue
            target.text = byID[cue.id]?.text ?? ""
            target.flag = byID[cue.id]?.flag
            return target
        }
        let references = reference.cues.sorted { $0.start < $1.start }
        var score = TranslationScore()
        for group in Scoring.groups(source: cues, reference: references) {
            func joined(_ cues: [Cue]) -> String { cues.map { SubtitleText.visibleLines(of: $0.text).joined(separator: " ") }.joined(separator: " ") }
            score = score + Scoring.translation(
                hypothesis: joined(group.source.map { translated[$0] }), reference: joined(group.reference.map { references[$0] }),
                source: joined(group.source.map { cues[$0] }), targetLanguage: options.target, glossary: sample.glossary
            )
        }
        score.rules = RuleCounts(translated, preset: options.preset, context: media.context)
        score.referenceRules = RuleCounts(reference.cues, preset: options.preset, context: media.context)
        return (translated, score)
    }
}

extension Benchmark {
    /// The speakers of the words inside a cue, in order of first word.
    static func voices(in words: [TranscribedWord], during cue: Cue) -> [String]? {
        var voices: [String] = []
        for word in words where word.start < cue.end && cue.start < word.end {
            if let speaker = word.speaker, !voices.contains(speaker) { voices.append(speaker) }
        }
        return voices.isEmpty ? nil : voices
    }
}

extension JSONEncoder {
    static var report: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var report: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

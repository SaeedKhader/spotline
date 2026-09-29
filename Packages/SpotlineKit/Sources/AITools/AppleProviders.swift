import AVFoundation
import Foundation
import MediaAnalysis
import Speech
import SubtitleCore
import Translation

/// On-device transcription with Apple's SpeechAnalyzer (macOS 26). The speech
/// model is managed by macOS: the first use of a language downloads it once,
/// after `confirmDownload` agrees. Nothing leaves the Mac.
public struct AppleSpeechTranscriber: Transcriber {
    public var name: String { "Apple Speech (on this Mac)" }
    /// Asked before macOS downloads a language's speech model; gets the language's name.
    public var confirmDownload: @Sendable (String) async -> Bool

    public init(confirmDownload: @escaping @Sendable (String) async -> Bool) {
        self.confirmDownload = confirmDownload
    }

    public func transcribe(
        _ audio: PreparedAudio, language: String?, progress: @escaping @Sendable (Double) -> Void,
        found: @escaping @Sendable ([TranscribedWord]) -> Void
    ) async throws -> [TranscribedWord] {
        let requested = Locale(identifier: language ?? Locale.current.identifier)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw AIError.languageNotSupported(language ?? requested.identifier)
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            guard await confirmDownload(Languages.name(locale.identifier)) else { throw AIError.modelDownloadDeclined }
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw AIError.provider("Apple Speech has no audio format for this language.")
        }
        let collector = Task {
            var words: [TranscribedWord] = []
            for try await result in transcriber.results where result.isFinal {
                let new = Self.words(in: result.text)
                words += new
                if !new.isEmpty { found(new) }
            }
            return words
        }
        let (inputs, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: inputs)
        let total = max(audio.chunks.reduce(0) { $0 + $1.samples.count }, 1)
        var fed = 0
        for chunk in audio.chunks {
            try Task.checkCancellation()
            let buffer = try Self.buffer(chunk.samples, format: format)
            let start = CMTime(value: chunk.start.value, timescale: CMTimeScale(clamping: chunk.start.timescale))
            continuation.yield(AnalyzerInput(buffer: buffer, bufferStartTime: start))
            fed += chunk.samples.count
            progress(Double(fed) / Double(total) * 0.9)
        }
        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let words = try await collector.value
        progress(1)
        return words.sorted { $0.start < $1.start }
    }

    /// Words (runs with a time range) of a result, with the punctuation the model wrote.
    static func words(in text: AttributedString) -> [TranscribedWord] {
        var words: [TranscribedWord] = []
        for run in text.runs {
            guard let range = run.audioTimeRange else { continue }
            let string = String(text[run.range].characters).trimmingCharacters(in: .whitespaces)
            guard !string.isEmpty else { continue }
            let start = MediaTime(value: Int64((range.start.seconds * 1000).rounded()), timescale: 1000)
            let end = MediaTime(value: Int64((range.end.seconds * 1000).rounded()), timescale: 1000)
            // Punctuation without its own time joins the previous word.
            if string.allSatisfy({ $0.isPunctuation }), let last = words.indices.last {
                words[last].text += string
            } else {
                words.append(TranscribedWord(text: string, start: start, end: max(end, start)))
            }
        }
        return words
    }

    /// 16 kHz float samples in the format the analyzer wants.
    static func buffer(_ samples: [Float], format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let source = AVAudioFormat(standardFormatWithSampleRate: Double(PreparedAudio.sampleRate), channels: 1),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count))
        else { throw AIError.provider("Could not make an audio buffer.") }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        guard format != source else { return input }
        guard let converter = AVAudioConverter(from: source, to: format),
              let output = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(samples.count) * format.sampleRate / source.sampleRate) + 1024
              )
        else { throw AIError.provider("Could not convert the audio for Apple Speech.") }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return output
    }
}

/// On-device translation with Apple's Translation framework. Languages must be
/// downloaded in System Settings first; nothing leaves the Mac. It translates
/// line by line with no scene context, so addressee tags come from the scene
/// reading (`SceneAddresseeInferrer`) and there are no variants.
public struct AppleTranslator: CueTranslator {
    public var name: String { "Apple Translation (on this Mac)" }

    public init() {}

    public func translate(
        _ request: TranslationRequest, progress: @escaping @Sendable (Double) -> Void,
        found: @escaping @Sendable ([CueTranslation]) -> Void
    ) async throws -> [CueTranslation] {
        let source = Locale.Language(identifier: Languages.base(request.sourceLanguage))
        let target = Locale.Language(identifier: Languages.base(request.targetLanguage))
        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed: break
        case .supported: throw AIError.languageNotInstalled(source: request.sourceLanguage, target: request.targetLanguage)
        default: throw AIError.languageNotSupported("\(Languages.name(request.sourceLanguage)) to \(Languages.name(request.targetLanguage))")
        }
        let session = TranslationSession(installedSource: source, target: target)
        var results: [CueTranslation] = []
        // A small first batch shows results quickly.
        let batches = Self.batches(of: request.lines.count, first: 10, size: 50).map { Array(request.lines[$0]) }
        for batch in batches {
            try Task.checkCancellation()
            // Line breaks are translated as sentence breaks; each line of a cue is kept apart.
            let requests = batch.map { line in
                TranslationSession.Request(
                    sourceText: SubtitleText.visibleLines(of: line.source).joined(separator: "\n"),
                    clientIdentifier: line.cueID.uuidString
                )
            }
            let responses = try await session.translations(from: requests)
            let before = results.count
            for response in responses {
                guard let id = response.clientIdentifier.flatMap(UUID.init(uuidString:)),
                      let line = batch.first(where: { $0.cueID == id })
                else { continue }
                results.append(CueTranslation(cueID: id, text: response.targetText, addressee: request.targetIsGendered ? line.addressee : nil))
            }
            found(Array(results[before...]))
            progress(Double(results.count) / Double(max(request.lines.count, 1)))
        }
        return results
    }

    /// Ranges of `count` lines: a small first batch, then full ones.
    static func batches(of count: Int, first: Int, size: Int) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        while start < count {
            let end = min(start + (ranges.isEmpty ? first : size), count)
            ranges.append(start..<end)
            start = end
        }
        return ranges
    }
}

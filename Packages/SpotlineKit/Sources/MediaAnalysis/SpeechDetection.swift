import AVFoundation
import CFFmpeg
import Foundation
import SoundAnalysis
import SubtitleCore

/// A stretch of audio where someone is speaking.
public struct SpeechRegion: Sendable, Codable, Equatable {
    public var start: MediaTime
    public var end: MediaTime
    /// The classifier's highest speech confidence in the region, 0 to 1.
    public var confidence: Float

    public init(start: MediaTime, end: MediaTime, confidence: Float) {
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

extension MediaAnalyzer {
    /// Where people speak, found with Apple's built-in on-device sound
    /// classifier (SoundAnalysis), in the same channels the waveform shows.
    /// `progress` returns false to cancel.
    public static func speech(
        in url: URL,
        options: Options = Options(),
        progress: (Progress<[SpeechRegion]>) -> Bool = { _ in true }
    ) throws -> [SpeechRegion] {
        let file = try MediaFile(url)
        let index = try file.audioStream(requested: options.audioStreamIndex)
        let detector = try SpeechDetector(audio: MonoAudio(stream: file.streams[Int(index)]!))
        let regions = try file.read(stream: index, options: options, progress: progress, decode: detector.decode) {
            detector.regions
        }
        // A failed classifier finds nothing; say so rather than report no speech.
        if let failure = detector.failure { throw Error.cannotOpen("the sound classifier failed: \(failure)") }
        return regions
    }
}

/// Feeds decoded audio to the sound classifier and keeps the windows it hears speech in.
final class SpeechDetector {
    /// Classifier windows: one second long, every half second.
    static let windowSeconds = 1.0
    static let threshold: Float = 0.5

    private let audio: MonoAudio
    private let analyzer: SNAudioStreamAnalyzer
    private let format: AVAudioFormat
    private let observer = Observer()
    private var framesFed: AVAudioFramePosition = 0
    /// Media time of the first sample fed to the classifier.
    private var firstSampleTime: Double?
    private var isComplete = false

    init(audio: MonoAudio) throws {
        self.audio = audio
        guard let format = AVAudioFormat(standardFormatWithSampleRate: audio.sampleRate, channels: 1) else {
            throw MediaAnalyzer.Error.cannotOpen("unsupported audio format")
        }
        self.format = format
        analyzer = SNAudioStreamAnalyzer(format: format)
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        let range = request.windowDurationConstraint
        if case .durationRange(let allowed) = range {
            let wanted = CMTime(seconds: Self.windowSeconds, preferredTimescale: 1000)
            request.windowDuration = min(max(wanted, allowed.start), allowed.end)
        }
        request.overlapFactor = 0.5
        try analyzer.add(request, withObserver: observer)
    }

    /// Regions found so far, merged and in order.
    var regions: [SpeechRegion] {
        let offset = firstSampleTime ?? 0
        return Self.merge(observer.windows.map { window in
            (window.start + offset, window.end + offset, window.confidence)
        })
    }

    /// Why the classifier stopped, if it did.
    var failure: (any Swift.Error)? { observer.failure }

    func decode(_ packet: UnsafeMutablePointer<AVPacket>?) {
        audio.decode(packet) { samples, start in feed(samples, at: start) }
        if packet == nil, !isComplete {
            isComplete = true
            analyzer.completeAnalysis()
        }
    }

    private func feed(_ samples: [Float], at start: Double) {
        // Skip encoder priming before time zero.
        let skip = start < 0 ? min(Int((-start * audio.sampleRate).rounded(.up)), samples.count) : 0
        let count = samples.count - skip
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return }
        if firstSampleTime == nil { firstSampleTime = max(start, 0) }
        buffer.frameLength = AVAudioFrameCount(count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress! + skip, count: count)
        }
        analyzer.analyze(buffer, atAudioFramePosition: framesFed)
        framesFed += AVAudioFramePosition(count)
    }

    /// Turns overlapping classifier windows into speech regions. Each window
    /// speaks for its middle half (the windows overlap by half), and regions
    /// closer than a quarter second join.
    static func merge(_ windows: [(start: Double, end: Double, confidence: Float)]) -> [SpeechRegion] {
        var regions: [(start: Double, end: Double, confidence: Float)] = []
        for window in windows.sorted(by: { $0.start < $1.start }) where window.confidence >= threshold {
            let quarter = (window.end - window.start) / 4
            let start = window.start <= 0 ? 0 : window.start + quarter
            let end = window.end - quarter
            if let last = regions.last, start <= last.end + 0.25 {
                regions[regions.count - 1].end = max(last.end, end)
                regions[regions.count - 1].confidence = max(last.confidence, window.confidence)
            } else {
                regions.append((start, end, window.confidence))
            }
        }
        return regions.map {
            SpeechRegion(start: MediaTime(seconds: $0.start, timescale: 1000), end: MediaTime(seconds: $0.end, timescale: 1000), confidence: $0.confidence)
        }
    }

    /// Collects classifier results, which arrive on the analyzer's own queue.
    private final class Observer: NSObject, SNResultsObserving, @unchecked Sendable {
        private let lock = NSLock()
        private var collected: [(start: Double, end: Double, confidence: Float)] = []
        private var error: (any Error)?

        var windows: [(start: Double, end: Double, confidence: Float)] {
            lock.withLock { collected }
        }

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            let confidence = Float(result.classification(forIdentifier: "speech")?.confidence ?? 0)
            let window = (result.timeRange.start.seconds, result.timeRange.end.seconds, confidence)
            lock.withLock { collected.append(window) }
        }

        var failure: (any Error)? {
            lock.withLock { error }
        }

        func request(_ request: SNRequest, didFailWithError error: any Error) {
            lock.withLock { self.error = error }
        }
    }
}

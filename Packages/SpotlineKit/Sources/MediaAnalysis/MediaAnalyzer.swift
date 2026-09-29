import CFFmpeg
import Foundation
import SubtitleCore

/// Reads waveform peaks and shot changes from media files. The two are
/// separate jobs that callers can run side by side: audio decodes in seconds
/// even for a feature film, while shot detection decodes every video frame.
/// Both run synchronously; call them off the main actor.
public enum MediaAnalyzer {
    public struct Options: Sendable {
        public var bucketsPerSecond = Waveform.defaultBucketsPerSecond
        /// Scene score (0 to 1) above which a frame starts a new shot. FFmpeg's
        /// `scene` filter uses the same score; 0.3 to 0.4 are common thresholds.
        public var sceneThreshold = 0.3
        /// How often `progress` receives what was found so far.
        public var partialResultInterval: Duration = .milliseconds(250)
        /// The FFmpeg index of the audio stream to draw, e.g. the one the player
        /// is playing. Nil, or an index that is not audio, picks the main audio stream.
        public var audioStreamIndex: Int?

        public init() {}
    }

    /// How far a job has got.
    public struct Progress<Partial: Sendable>: Sendable {
        /// 0 to 1.
        public var fraction: Double
        /// Media before this time has been read.
        public var analyzedUntil: MediaTime
        /// What was found so far. Set at most every `partialResultInterval`,
        /// and always with the last report.
        public var partial: Partial?

        public init(fraction: Double, analyzedUntil: MediaTime, partial: Partial?) {
            self.fraction = fraction
            self.analyzedUntil = analyzedUntil
            self.partial = partial
        }
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case cannotOpen(String)
        case noStream
        case cancelled

        public var description: String {
            switch self {
            case .cannotOpen(let reason): "Cannot read the media: \(reason)"
            case .noStream: "The media has no stream of that kind"
            case .cancelled: "Cancelled"
            }
        }
    }

    /// The waveform of one audio stream. `progress` returns false to cancel.
    public static func waveform(
        of url: URL,
        options: Options = Options(),
        progress: (Progress<AudioAnalysis>) -> Bool = { _ in true }
    ) throws -> AudioAnalysis {
        let file = try MediaFile(url)
        let index = try file.audioStream(requested: options.audioStreamIndex)
        let audio = try AudioPeaks(stream: file.streams[Int(index)]!, bucketsPerSecond: options.bucketsPerSecond)
        return try file.read(stream: index, options: options, progress: progress, decode: audio.decode) {
            AudioAnalysis(
                waveform: Waveform(bucketsPerSecond: options.bucketsPerSecond, peaks: audio.peaks, source: audio.source),
                audioStreamIndex: Int(index)
            )
        }
    }

    /// The times where new shots start, in order. `progress` returns false to cancel.
    public static func shotChanges(
        in url: URL,
        options: Options = Options(),
        progress: (Progress<[MediaTime]>) -> Bool = { _ in true }
    ) throws -> [MediaTime] {
        let file = try MediaFile(url)
        let index = av_find_best_stream(file.format, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        guard index >= 0 else { throw Error.noStream }
        let video = try ShotDetector(stream: file.streams[Int(index)]!, threshold: options.sceneThreshold)
        return try file.read(stream: index, options: options, progress: progress, decode: video.decode) {
            video.shotChanges
        }
    }

    /// Both jobs, one after the other. A file without audio or video gives
    /// an empty result for that part.
    public static func analyze(_ url: URL, options: Options = Options()) throws -> MediaAnalysis {
        let audio: AudioAnalysis?
        do { audio = try waveform(of: url, options: options) } catch Error.noStream { audio = nil }
        let shots: [MediaTime]
        do { shots = try shotChanges(in: url, options: options) } catch Error.noStream { shots = [] }
        return MediaAnalysis(waveform: audio?.waveform, shotChanges: shots, audioStreamIndex: audio?.audioStreamIndex)
    }
}

/// The waveform of one audio stream and which stream it came from.
public struct AudioAnalysis: Sendable, Codable, Equatable {
    public var waveform: Waveform
    /// The FFmpeg index of the audio stream.
    public var audioStreamIndex: Int

    public init(waveform: Waveform, audioStreamIndex: Int) {
        self.waveform = waveform
        self.audioStreamIndex = audioStreamIndex
    }
}

// MARK: - Reading

/// An open media file.
final class MediaFile {
    let format: UnsafeMutablePointer<AVFormatContext>
    let streams: UnsafeBufferPointer<UnsafeMutablePointer<AVStream>?>

    init(_ url: URL) throws {
        var format: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&format, url.path, nil, nil) == 0, let format else {
            throw MediaAnalyzer.Error.cannotOpen("unsupported or missing file")
        }
        self.format = format
        guard avformat_find_stream_info(format, nil) >= 0 else {
            var context: UnsafeMutablePointer<AVFormatContext>? = format
            avformat_close_input(&context)
            throw MediaAnalyzer.Error.cannotOpen("no stream information")
        }
        streams = UnsafeBufferPointer(start: format.pointee.streams, count: Int(format.pointee.nb_streams))
        // Decoders turn their own stream back on.
        for stream in streams { stream?.pointee.discard = AVDISCARD_ALL }
    }

    deinit {
        var context: UnsafeMutablePointer<AVFormatContext>? = format
        avformat_close_input(&context)
    }

    /// The requested audio stream when it is one, else the main audio stream.
    func audioStream(requested: Int?) throws -> Int32 {
        let valid = requested.flatMap { index in
            streams.indices.contains(index) && streams[index]?.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO
                ? Int32(index) : nil
        }
        let index = valid ?? av_find_best_stream(format, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        guard index >= 0 else { throw MediaAnalyzer.Error.noStream }
        return index
    }

    /// Feeds every packet of `stream` to `decode`, reporting progress with
    /// `result()` as the partial result at most every `partialResultInterval`.
    func read<Result: Sendable>(
        stream index: Int32,
        options: MediaAnalyzer.Options,
        progress: (MediaAnalyzer.Progress<Result>) -> Bool,
        decode: (UnsafeMutablePointer<AVPacket>?) -> Void,
        result: () -> Result
    ) throws -> Result {
        let duration = format.pointee.duration > 0 ? Double(format.pointee.duration) / Double(AV_TIME_BASE) : 0
        let timeBase = streams[Int(index)]!.pointee.time_base
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }

        let clock = ContinuousClock()
        var lastPartial = clock.now
        var lastFraction = -1.0
        var analyzedUntil = MediaTime.zero

        while av_read_frame(format, packet) >= 0 {
            defer { av_packet_unref(packet) }
            guard packet!.pointee.stream_index == index else { continue }
            decode(packet)
            let pts = packet!.pointee.pts
            guard pts != Int64.min else { continue }
            analyzedUntil = max(analyzedUntil, MediaTime(value: pts * Int64(timeBase.num), timescale: Int64(timeBase.den)))
            let fraction = duration > 0 ? min(max(analyzedUntil.seconds / duration, 0), 1) : 0
            let partialDue = clock.now - lastPartial >= options.partialResultInterval
            guard partialDue || fraction - lastFraction >= 0.01 else { continue }
            lastFraction = fraction
            if partialDue { lastPartial = clock.now }
            let report = MediaAnalyzer.Progress(fraction: fraction, analyzedUntil: analyzedUntil, partial: partialDue ? result() : nil)
            if !progress(report) { throw MediaAnalyzer.Error.cancelled }
        }
        decode(nil)
        let final = result()
        _ = progress(MediaAnalyzer.Progress(fraction: 1, analyzedUntil: analyzedUntil, partial: final))
        return final
    }
}

// MARK: - Decoding

/// A decoder for one stream that hands each decoded frame to `onFrame`.
final class StreamDecoder {
    let context: UnsafeMutablePointer<AVCodecContext>
    let timeBase: AVRational
    private var frame: UnsafeMutablePointer<AVFrame>?

    init(stream: UnsafeMutablePointer<AVStream>, configure: (UnsafeMutablePointer<AVCodecContext>) -> Void = { _ in }) throws {
        guard let parameters = stream.pointee.codecpar,
              let codec = avcodec_find_decoder(parameters.pointee.codec_id),
              let context = avcodec_alloc_context3(codec)
        else { throw MediaAnalyzer.Error.cannotOpen("no decoder") }
        self.context = context
        avcodec_parameters_to_context(context, parameters)
        context.pointee.thread_count = 0
        configure(context)
        guard avcodec_open2(context, codec, nil) == 0 else {
            var owned: UnsafeMutablePointer<AVCodecContext>? = context
            avcodec_free_context(&owned)
            throw MediaAnalyzer.Error.cannotOpen("decoder failed to open")
        }
        timeBase = stream.pointee.time_base
        frame = av_frame_alloc()
        stream.pointee.discard = AVDISCARD_DEFAULT
    }

    deinit {
        av_frame_free(&frame)
        var owned: UnsafeMutablePointer<AVCodecContext>? = context
        avcodec_free_context(&owned)
    }

    /// Sends a packet (nil to flush) and passes every frame that comes out.
    func decode(_ packet: UnsafeMutablePointer<AVPacket>?, onFrame: (UnsafeMutablePointer<AVFrame>) -> Void) {
        guard avcodec_send_packet(context, packet) >= 0 || packet == nil else { return }
        while avcodec_receive_frame(context, frame) >= 0 {
            onFrame(frame!)
            av_frame_unref(frame)
        }
    }

    /// The frame's presentation time, nil when unknown.
    func time(of frame: UnsafeMutablePointer<AVFrame>) -> MediaTime? {
        let pts = frame.pointee.best_effort_timestamp
        guard pts != Int64.min, timeBase.den > 0 else { return nil }
        return MediaTime(value: pts * Int64(timeBase.num), timescale: Int64(timeBase.den))
    }
}

/// Decodes one audio stream to mono float samples: the center channel of
/// surround mixes (where dialogue lives), else a mix of all channels.
/// Optionally resampled, e.g. to the 16 kHz speech models take.
final class MonoAudio {
    private let decoder: StreamDecoder
    private var resampler: OpaquePointer?
    private var buffer: [Float] = []
    /// Where the next samples go when frames carry no timestamp.
    private var nextSampleTime = 0.0

    let source: Waveform.Source
    let sampleRate: Double

    /// `outputSampleRate` nil keeps the stream's rate.
    init(stream: UnsafeMutablePointer<AVStream>, outputSampleRate: Int? = nil) throws {
        decoder = try StreamDecoder(stream: stream)
        var mono = AVChannelLayout()
        av_channel_layout_default(&mono, 1)
        let context = decoder.context
        let rate = context.pointee.sample_rate
        let outputRate = outputSampleRate.map(Int32.init) ?? rate
        sampleRate = Double(outputRate)
        guard swr_alloc_set_opts2(
            &resampler, &mono, AV_SAMPLE_FMT_FLT, outputRate,
            &context.pointee.ch_layout, context.pointee.sample_fmt, rate, 0, nil
        ) >= 0 else {
            throw MediaAnalyzer.Error.cannotOpen("audio resampler failed")
        }
        // In surround mixes dialogue lives in the center channel; music and
        // effects in the others would bury it in a mixdown.
        let channels = Int(context.pointee.ch_layout.nb_channels)
        let center = av_channel_layout_index_from_channel(&context.pointee.ch_layout, AV_CHAN_FRONT_CENTER)
        if channels > 2, center >= 0 {
            var matrix = [Double](repeating: 0, count: channels)
            matrix[Int(center)] = 1
            guard swr_set_matrix(resampler, matrix, Int32(channels)) >= 0 else {
                throw MediaAnalyzer.Error.cannotOpen("audio channel selection failed")
            }
            source = .centerChannel
        } else {
            source = .mix
        }
        guard swr_init(resampler) >= 0 else {
            throw MediaAnalyzer.Error.cannotOpen("audio resampler failed")
        }
    }

    deinit {
        swr_free(&resampler)
    }

    /// Decodes a packet (nil to flush), passing each frame's samples and start time in seconds.
    func decode(_ packet: UnsafeMutablePointer<AVPacket>?, onSamples: ([Float], Double) -> Void) {
        decoder.decode(packet) { frame in
            let samples = convert(frame)
            let start = decoder.time(of: frame)?.seconds ?? nextSampleTime
            nextSampleTime = start + Double(samples.count) / sampleRate
            onSamples(samples, start)
        }
        // A resampler holds back a few samples; the last ones come out when flushed.
        if packet == nil {
            let rest = convert(nil)
            if !rest.isEmpty {
                onSamples(rest, nextSampleTime)
                nextSampleTime += Double(rest.count) / sampleRate
            }
        }
    }

    /// Converts a frame's samples, or flushes the resampler when `frame` is nil.
    private func convert(_ frame: UnsafeMutablePointer<AVFrame>?) -> [Float] {
        let count = frame.map { Int($0.pointee.nb_samples) } ?? 0
        // Resampling can emit more samples than it takes in (up to the output/input rate ratio).
        let needed = Int(Double(count) * max(sampleRate / Double(decoder.context.pointee.sample_rate), 1)) + 256
        if buffer.count < needed { buffer = [Float](repeating: 0, count: needed) }
        let capacity = Int32(buffer.count)
        let converted = buffer.withUnsafeMutableBytes { bytes -> Int32 in
            var output: UnsafeMutablePointer<UInt8>? = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
            guard let frame else { return swr_convert(resampler, &output, capacity, nil, 0) }
            let input = UnsafeRawPointer(frame.pointee.extended_data)!.assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
            return swr_convert(resampler, &output, capacity, input, Int32(count))
        }
        return converted > 0 ? Array(buffer[0..<Int(converted)]) : []
    }
}

/// Keeps the loudest sample of each bucket, after filtering to the voice band
/// so rumble, bass and hiss do not hide speech.
private final class AudioPeaks {
    private let audio: MonoAudio
    private let bucketsPerSecond: Int
    private var filter: VoiceBandFilter
    private var levels: [Float] = []

    var source: Waveform.Source { audio.source }

    init(stream: UnsafeMutablePointer<AVStream>, bucketsPerSecond: Int) throws {
        audio = try MonoAudio(stream: stream)
        self.bucketsPerSecond = bucketsPerSecond
        filter = VoiceBandFilter(sampleRate: audio.sampleRate)
    }

    var peaks: [UInt8] {
        levels.map { UInt8((min(max($0, 0), 1) * 255).rounded()) }
    }

    func decode(_ packet: UnsafeMutablePointer<AVPacket>?) {
        audio.decode(packet) { samples, start in add(filter.process(samples), at: start) }
    }

    private func add(_ samples: [Float], at start: Double) {
        let perBucket = audio.sampleRate / Double(bucketsPerSecond)
        for (offset, sample) in samples.enumerated() {
            let position = start * Double(bucketsPerSecond) + Double(offset) / perBucket
            guard position >= 0 else { continue }  // encoder priming before time zero
            let bucket = Int(position)
            if bucket >= levels.count { levels.append(contentsOf: repeatElement(0, count: bucket - levels.count + 1)) }
            levels[bucket] = max(levels[bucket], abs(sample))
        }
    }
}

/// Scores each frame against the previous one the way FFmpeg's `scene`
/// filter does, on a 64×36 RGB thumbnail.
private final class ShotDetector {
    private let decoder: StreamDecoder
    private let threshold: Double
    private var scaler: UnsafeMutablePointer<SwsContext>?
    private var thumbnail: UnsafeMutablePointer<AVFrame>?
    private var previous: [UInt8]?
    private var previousDifference = 0.0
    private(set) var shotChanges: [MediaTime] = []

    static let width: Int32 = 64
    static let height: Int32 = 36

    init(stream: UnsafeMutablePointer<AVStream>, threshold: Double) throws {
        decoder = try StreamDecoder(stream: stream) { context in
            // Deblocking does not change shot boundaries and costs time.
            context.pointee.skip_loop_filter = AVDISCARD_ALL
        }
        self.threshold = threshold
        thumbnail = av_frame_alloc()
        thumbnail!.pointee.width = Self.width
        thumbnail!.pointee.height = Self.height
        thumbnail!.pointee.format = AV_PIX_FMT_RGB24.rawValue
        guard av_frame_get_buffer(thumbnail, 0) >= 0 else {
            throw MediaAnalyzer.Error.cannotOpen("frame buffer failed")
        }
    }

    deinit {
        sws_freeContext(scaler)
        av_frame_free(&thumbnail)
    }

    func decode(_ packet: UnsafeMutablePointer<AVPacket>?) {
        decoder.decode(packet) { frame in
            if let pixels = shrink(frame) { score(pixels, at: decoder.time(of: frame)) }
        }
    }

    private func shrink(_ frame: UnsafeMutablePointer<AVFrame>) -> [UInt8]? {
        scaler = sws_getCachedContext(
            scaler,
            frame.pointee.width, frame.pointee.height, AVPixelFormat(frame.pointee.format),
            Self.width, Self.height, AV_PIX_FMT_RGB24,
            Int32(SWS_AREA.rawValue), nil, nil, nil
        )
        guard scaler != nil, sws_scale_frame(scaler, thumbnail, frame) >= 0,
              let data = thumbnail!.pointee.data.0
        else { return nil }
        let stride = Int(thumbnail!.pointee.linesize.0)
        let rowBytes = Int(Self.width) * 3
        var pixels = [UInt8](repeating: 0, count: rowBytes * Int(Self.height))
        for row in 0..<Int(Self.height) {
            for column in 0..<rowBytes {
                pixels[row * rowBytes + column] = data[row * stride + column]
            }
        }
        return pixels
    }

    private func score(_ pixels: [UInt8], at time: MediaTime?) {
        defer { previous = pixels }
        guard let previous else { return }
        var sum = 0
        for index in pixels.indices { sum += abs(Int(pixels[index]) - Int(previous[index])) }
        // Mean absolute difference per channel sample, 0 to 255.
        let difference = Double(sum) / Double(pixels.count)
        let change = abs(difference - previousDifference)
        previousDifference = difference
        let score = min(max(min(difference, change) / 100, 0), 1)
        if score > threshold, let time {
            shotChanges.append(time)
        }
    }
}

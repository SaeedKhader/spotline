import CFFmpeg
import Foundation
import SubtitleCore

/// Reads a media file once, decoding its audio into waveform peaks and its
/// video into shot changes. Runs synchronously; call it off the main actor.
public enum MediaAnalyzer {
    public struct Options: Sendable {
        public var bucketsPerSecond = Waveform.defaultBucketsPerSecond
        /// Scene score (0 to 1) above which a frame starts a new shot. FFmpeg's
        /// `scene` filter uses the same score; 0.3 to 0.4 are common thresholds.
        public var sceneThreshold = 0.3

        public init() {}
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case cannotOpen(String)
        case cancelled

        public var description: String {
            switch self {
            case .cannotOpen(let reason): "Cannot read the media: \(reason)"
            case .cancelled: "Cancelled"
            }
        }
    }

    /// Analyzes `url`. `progress` receives 0 to 1 and returns false to cancel.
    public static func analyze(
        _ url: URL,
        options: Options = Options(),
        progress: (Double) -> Bool = { _ in true }
    ) throws -> MediaAnalysis {
        var format: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&format, url.path, nil, nil) == 0, let format else {
            throw Error.cannotOpen("unsupported or missing file")
        }
        defer {
            var context: UnsafeMutablePointer<AVFormatContext>? = format
            avformat_close_input(&context)
        }
        guard avformat_find_stream_info(format, nil) >= 0 else { throw Error.cannotOpen("no stream information") }

        let streams = UnsafeBufferPointer(start: format.pointee.streams, count: Int(format.pointee.nb_streams))
        for stream in streams { stream?.pointee.discard = AVDISCARD_ALL }
        let audioIndex = av_find_best_stream(format, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        let videoIndex = av_find_best_stream(format, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)

        let audio = audioIndex >= 0 ? try? AudioPeaks(stream: streams[Int(audioIndex)]!, bucketsPerSecond: options.bucketsPerSecond) : nil
        let video = videoIndex >= 0 ? try? ShotDetector(stream: streams[Int(videoIndex)]!, threshold: options.sceneThreshold) : nil
        guard audio != nil || video != nil else { throw Error.cannotOpen("no audio or video stream") }

        let duration = format.pointee.duration > 0 ? Double(format.pointee.duration) / Double(AV_TIME_BASE) : 0
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        var lastReport = -1.0

        while av_read_frame(format, packet) >= 0 {
            defer { av_packet_unref(packet) }
            let index = packet!.pointee.stream_index
            if index == audioIndex {
                audio?.decode(packet)
            } else if index == videoIndex {
                video?.decode(packet)
                if duration > 0, packet!.pointee.pts != Int64.min {
                    let timeBase = streams[Int(index)]!.pointee.time_base
                    let seconds = Double(packet!.pointee.pts) * Double(timeBase.num) / Double(timeBase.den)
                    let fraction = min(max(seconds / duration, 0), 1)
                    if fraction - lastReport >= 0.01 {
                        lastReport = fraction
                        if !progress(fraction) { throw Error.cancelled }
                    }
                }
            }
        }
        audio?.decode(nil)
        video?.decode(nil)
        _ = progress(1)

        return MediaAnalysis(
            waveform: audio.map { Waveform(bucketsPerSecond: options.bucketsPerSecond, peaks: $0.peaks) },
            shotChanges: video?.shotChanges ?? []
        )
    }
}

// MARK: - Decoding

/// A decoder for one stream that hands each decoded frame to `onFrame`.
private final class StreamDecoder {
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

/// Mixes audio to mono float and keeps the loudest sample of each bucket.
private final class AudioPeaks {
    private let decoder: StreamDecoder
    private let bucketsPerSecond: Int
    private var resampler: OpaquePointer?
    private var buffer: [Float] = []
    private var levels: [Float] = []
    /// Where the next sample goes when frames carry no timestamp.
    private var nextSampleTime = 0.0

    init(stream: UnsafeMutablePointer<AVStream>, bucketsPerSecond: Int) throws {
        decoder = try StreamDecoder(stream: stream)
        self.bucketsPerSecond = bucketsPerSecond
        var mono = AVChannelLayout()
        av_channel_layout_default(&mono, 1)
        let context = decoder.context
        let rate = context.pointee.sample_rate
        guard swr_alloc_set_opts2(
            &resampler, &mono, AV_SAMPLE_FMT_FLT, rate,
            &context.pointee.ch_layout, context.pointee.sample_fmt, rate, 0, nil
        ) >= 0, swr_init(resampler) >= 0 else {
            throw MediaAnalyzer.Error.cannotOpen("audio resampler failed")
        }
    }

    var peaks: [UInt8] {
        levels.map { UInt8((min(max($0, 0), 1) * 255).rounded()) }
    }

    func decode(_ packet: UnsafeMutablePointer<AVPacket>?) {
        decoder.decode(packet) { frame in
            add(convert(frame), at: decoder.time(of: frame)?.seconds)
        }
    }

    private func convert(_ frame: UnsafeMutablePointer<AVFrame>) -> [Float] {
        let count = Int(frame.pointee.nb_samples)
        if buffer.count < count + 64 { buffer = [Float](repeating: 0, count: count + 64) }
        let capacity = Int32(buffer.count)
        let converted = buffer.withUnsafeMutableBytes { bytes -> Int32 in
            var output: UnsafeMutablePointer<UInt8>? = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let input = UnsafeRawPointer(frame.pointee.extended_data)!.assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
            return swr_convert(resampler, &output, capacity, input, Int32(count))
        }
        return converted > 0 ? Array(buffer[0..<Int(converted)]) : []
    }

    private func add(_ samples: [Float], at startTime: Double?) {
        let rate = Double(decoder.context.pointee.sample_rate)
        let start = startTime ?? nextSampleTime
        nextSampleTime = start + Double(samples.count) / rate
        let perBucket = rate / Double(bucketsPerSecond)
        for (offset, sample) in samples.enumerated() {
            let position = start * Double(bucketsPerSecond) + Double(offset) / perBucket
            guard position >= 0 else { continue }  // encoder priming before time zero
            let bucket = Int(position)
            if bucket >= levels.count { levels.append(contentsOf: repeatElement(0, count: bucket - levels.count + 1)) }
            levels[bucket] = max(levels[bucket], abs(sample))
        }
    }

    deinit {
        swr_free(&resampler)
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

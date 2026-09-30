import CFFmpeg
import Foundation
import SubtitleCore

/// Dialogue audio ready for speech models: one channel at 16 kHz (the center
/// channel of 5.1 and 7.1 mixes, else a mono mix), split into chunks at pauses.
/// Silence between chunks is left out; each chunk knows where it starts in the
/// media, so model timestamps map back exactly. See docs/ARCHITECTURE.md, 7a.
public struct PreparedAudio: Sendable, Equatable {
    /// What speech models take.
    public static let sampleRate = 16_000

    public var source: Waveform.Source
    /// The FFmpeg index of the audio stream it was read from.
    public var audioStreamIndex: Int
    /// The length of the whole stream.
    public var duration: MediaTime
    public var chunks: [AudioChunk]

    public init(source: Waveform.Source, audioStreamIndex: Int, duration: MediaTime, chunks: [AudioChunk]) {
        self.source = source
        self.audioStreamIndex = audioStreamIndex
        self.duration = duration
        self.chunks = chunks
    }

    /// The samples between two media times (silence where no chunk covers them).
    public func samples(from start: MediaTime, to end: MediaTime) -> [Float] {
        let rate = Double(Self.sampleRate)
        let first = Int((start.seconds * rate).rounded())
        let count = max(Int((end.seconds * rate).rounded()) - first, 0)
        var result = [Float](repeating: 0, count: count)
        for chunk in chunks where chunk.end > start && chunk.start < end {
            let chunkFirst = Int((chunk.start.seconds * rate).rounded())
            for index in max(first, chunkFirst)..<min(first + count, chunkFirst + chunk.samples.count) {
                result[index - first] = chunk.samples[index - chunkFirst]
            }
        }
        return result
    }
}

/// How loud the dialogue audio is, 30 ms at a time, on the media's timeline:
/// for telling main dialogue from quieter voices behind it (`WallaFilter`).
public struct SpeechLevels: Sendable, Equatable {
    public static let frameSeconds = AudioChunker.frameSeconds
    /// dBFS per frame from time zero; silence (-140) where no chunk has audio.
    public var levels: [Float]

    public init(levels: [Float]) {
        self.levels = levels
    }

    public init(_ audio: PreparedAudio) {
        let frameSize = Int(Double(PreparedAudio.sampleRate) * Self.frameSeconds)
        var levels = [Float](repeating: Self.silence, count: Int((audio.duration.seconds / Self.frameSeconds).rounded(.up)))
        for chunk in audio.chunks {
            let first = Int((chunk.start.seconds * Double(PreparedAudio.sampleRate)).rounded()) / frameSize
            for (index, level) in AudioChunker.frameLevels(chunk.samples, sampleRate: PreparedAudio.sampleRate).enumerated() {
                let frame = first + index
                if frame >= levels.count { levels.append(contentsOf: repeatElement(Self.silence, count: frame - levels.count + 1)) }
                levels[frame] = max(levels[frame], level)
            }
        }
        self.levels = levels
    }

    static let silence: Float = -140

    /// The loudest frame between two times (at least the frame at `start`).
    public func loudest(from start: MediaTime, to end: MediaTime) -> Float {
        guard !levels.isEmpty else { return Self.silence }
        let first = min(max(Int(start.seconds / Self.frameSeconds), 0), levels.count - 1)
        let last = min(max(Int((end.seconds / Self.frameSeconds).rounded(.up)), first + 1), levels.count)
        return levels[first..<last].max() ?? Self.silence
    }
}

/// A stretch of speech, at `PreparedAudio.sampleRate`.
public struct AudioChunk: Sendable, Equatable, Identifiable {
    public var id: Int
    /// Media time of the first sample.
    public var start: MediaTime
    public var samples: [Float]

    public init(id: Int, start: MediaTime, samples: [Float]) {
        self.id = id
        self.start = start
        self.samples = samples
    }

    public var duration: MediaTime { MediaTime(value: Int64(samples.count), timescale: Int64(PreparedAudio.sampleRate)) }
    public var end: MediaTime { start + duration }

    /// The media time of a model timestamp given in seconds from the chunk's start.
    public func mediaTime(atOffset seconds: Double) -> MediaTime {
        start + MediaTime(value: Int64((seconds * 1000).rounded()), timescale: 1000)
    }
}

extension MediaAnalyzer {
    /// Reads the dialogue audio at 16 kHz and splits it into chunks of speech.
    /// `progress` returns false to cancel.
    public static func prepareAudio(
        of url: URL,
        options: Options = Options(),
        chunking: AudioChunker = AudioChunker(),
        progress: (Progress<PreparedAudio>) -> Bool = { _ in true }
    ) throws -> PreparedAudio {
        let file = try MediaFile(url)
        let index = try file.audioStream(requested: options.audioStreamIndex)
        let audio = try MonoAudio(stream: file.streams[Int(index)]!, outputSampleRate: PreparedAudio.sampleRate)
        let collector = SampleCollector(sampleRate: audio.sampleRate)
        let decode: (UnsafeMutablePointer<AVPacket>?) -> Void = { packet in
            audio.decode(packet) { samples, start in collector.add(samples, at: start) }
        }
        var chunks: [AudioChunk] = []
        // Partial results carry no chunks: chunking needs the whole stream's pauses.
        _ = try file.read(stream: index, options: options, progress: { report in
            progress(Progress(fraction: report.fraction * 0.95, analyzedUntil: report.analyzedUntil, partial: nil))
        }, decode: decode) { 0 }
        chunks = chunking.chunks(of: collector.samples, startingAt: collector.firstSampleTime)
        let duration = MediaTime(value: Int64(collector.samples.count), timescale: Int64(PreparedAudio.sampleRate))
            + collector.firstSampleTime
        let prepared = PreparedAudio(source: audio.source, audioStreamIndex: Int(index), duration: duration, chunks: chunks)
        _ = progress(Progress(fraction: 1, analyzedUntil: duration, partial: prepared))
        return prepared
    }
}

/// Collects decoded samples into one buffer, dropping encoder priming before time zero.
private final class SampleCollector {
    let sampleRate: Double
    private(set) var samples: [Float] = []
    private(set) var firstSampleTime = MediaTime.zero
    private var started = false

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    func add(_ new: [Float], at start: Double) {
        let skip = start < 0 ? min(Int((-start * sampleRate).rounded(.up)), new.count) : 0
        guard new.count > skip else { return }
        if !started {
            started = true
            firstSampleTime = MediaTime(value: Int64((max(start, 0) * sampleRate).rounded()), timescale: Int64(sampleRate))
        }
        samples.append(contentsOf: new[skip...])
    }
}

/// Voice activity detection by loudness, and chunking at pauses.
///
/// 30 ms frames count as speech when they are 12 dB above the quietest tenth
/// of the stream (its noise floor), or louder than -35 dBFS. Speech closer than `bridgeSeconds` joins;
/// chunks grow up to `targetSeconds` and end at the pause before the speech
/// that would make them longer, or at a pause of `pauseSeconds` or more.
/// Speech that runs on longer than the target is cut at its quietest frame.
public struct AudioChunker: Sendable {
    public var targetSeconds = 30.0
    public var pauseSeconds = 2.0
    public var bridgeSeconds = 0.4
    /// Kept before and after each chunk's speech.
    public var paddingSeconds = 0.2
    /// Frames are speech this far (dB) above the noise floor.
    public var thresholdAboveFloor: Float = 12
    /// ...and never quieter than this (dBFS), so digital silence does not make noise speech.
    public var absoluteThreshold: Float = -50
    /// ...and always speech from this level (dBFS) up.
    public var speechLevel: Float = -35

    public init() {}

    static let frameSeconds = 0.03

    /// Loudness per 30 ms frame in dBFS.
    static func frameLevels(_ samples: [Float], sampleRate: Int) -> [Float] {
        let size = Int(Double(sampleRate) * frameSeconds)
        return stride(from: 0, to: samples.count, by: size).map { start in
            let end = min(start + size, samples.count)
            var sum: Float = 0
            for index in start..<end { sum += samples[index] * samples[index] }
            let rms = (sum / Float(max(end - start, 1))).squareRoot()
            return 20 * log10(max(rms, 1e-7))
        }
    }

    /// Stretches of speech as frame ranges.
    func speechFrames(levels: [Float]) -> [Range<Int>] {
        guard !levels.isEmpty else { return [] }
        let sorted = levels.sorted()
        let floor = sorted[sorted.count / 10]
        // Speech is always loud enough to count, even over a steady bed with no quiet moments.
        let threshold = max(min(floor + thresholdAboveFloor, speechLevel), absoluteThreshold)
        let bridge = Int(bridgeSeconds / Self.frameSeconds)
        var spans: [Range<Int>] = []
        var start: Int?
        for (index, level) in levels.enumerated() {
            if level >= threshold {
                if start == nil { start = index }
            } else if let open = start {
                spans.append(open..<index)
                start = nil
            }
        }
        if let open = start { spans.append(open..<levels.count) }
        // Join speech separated by short breaths.
        var joined: [Range<Int>] = []
        for span in spans {
            if let last = joined.last, span.lowerBound - last.upperBound <= bridge {
                joined[joined.count - 1] = last.lowerBound..<span.upperBound
            } else {
                joined.append(span)
            }
        }
        return joined
    }

    /// Splits `samples` (at `PreparedAudio.sampleRate`, the first one at `start`) into chunks of speech.
    public func chunks(of samples: [Float], startingAt start: MediaTime) -> [AudioChunk] {
        let rate = PreparedAudio.sampleRate
        let levels = Self.frameLevels(samples, sampleRate: rate)
        let frameSize = Int(Double(rate) * Self.frameSeconds)
        let target = Int(targetSeconds / Self.frameSeconds)
        let pause = Int(pauseSeconds / Self.frameSeconds)
        let padding = Int(paddingSeconds / Self.frameSeconds)

        // Speech longer than the target is cut at its quietest frame first.
        var spans: [Range<Int>] = []
        for span in speechFrames(levels: levels) {
            var rest = span
            while rest.count > target {
                let window = (rest.lowerBound + target / 2)..<(rest.lowerBound + target)
                let cut = window.min { levels[$0] < levels[$1] } ?? window.upperBound
                spans.append(rest.lowerBound..<cut)
                rest = cut..<rest.upperBound
            }
            if !rest.isEmpty { spans.append(rest) }
        }

        var groups: [Range<Int>] = []
        for span in spans {
            if let last = groups.last, span.lowerBound - last.upperBound < pause, span.upperBound - last.lowerBound <= target {
                groups[groups.count - 1] = last.lowerBound..<span.upperBound
            } else {
                groups.append(span)
            }
        }

        return groups.enumerated().map { index, group in
            // Padding never reaches into the neighbouring chunks.
            let previousEnd = index > 0 ? groups[index - 1].upperBound : 0
            let nextStart = index + 1 < groups.count ? groups[index + 1].lowerBound : levels.count
            let first = max(group.lowerBound - padding, (previousEnd + group.lowerBound) / 2, 0) * frameSize
            let last = min(min(group.upperBound + padding, (group.upperBound + nextStart + 1) / 2) * frameSize, samples.count)
            return AudioChunk(
                id: index,
                start: start + MediaTime(value: Int64(first), timescale: Int64(rate)),
                samples: Array(samples[first..<last])
            )
        }
    }
}

// MARK: - Opus for cloud upload

/// Encodes speech as Ogg Opus for cloud providers: about 24 kbit/s at 16 kHz,
/// so two hours of dialogue is about 20 MB and one chunk stays far under upload caps.
public enum OpusEncoder {
    public enum Error: Swift.Error, CustomStringConvertible {
        case unavailable(String)

        public var description: String {
            switch self {
            case .unavailable(let reason): "Opus encoding failed: \(reason)"
            }
        }
    }

    /// `progress` gets how much has been encoded, 0 to 1, about once per percent.
    public static func oggOpus(
        _ samples: [Float], sampleRate: Int = PreparedAudio.sampleRate, bitRate: Int = 24_000, progress: ((Double) -> Void)? = nil
    ) throws -> Data {
        var format: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_alloc_output_context2(&format, nil, "ogg", nil) >= 0, let format else {
            throw Error.unavailable("no Ogg muxer")
        }
        defer { avformat_free_context(format) }
        guard let codec = avcodec_find_encoder_by_name("libopus") else { throw Error.unavailable("no libopus encoder") }
        var context = avcodec_alloc_context3(codec)
        defer { avcodec_free_context(&context) }
        guard let context else { throw Error.unavailable("no encoder context") }
        context.pointee.sample_rate = Int32(sampleRate)
        av_channel_layout_default(&context.pointee.ch_layout, 1)
        context.pointee.sample_fmt = AV_SAMPLE_FMT_FLT
        context.pointee.bit_rate = Int64(bitRate)
        context.pointee.time_base = AVRational(num: 1, den: Int32(sampleRate))
        if format.pointee.oformat.pointee.flags & AVFMT_GLOBALHEADER != 0 {
            context.pointee.flags |= Int32(AV_CODEC_FLAG_GLOBAL_HEADER)
        }
        guard avcodec_open2(context, codec, nil) >= 0 else { throw Error.unavailable("the encoder did not open") }
        guard let stream = avformat_new_stream(format, nil) else { throw Error.unavailable("no stream") }
        avcodec_parameters_from_context(stream.pointee.codecpar, context)
        stream.pointee.time_base = context.pointee.time_base
        guard avio_open_dyn_buf(&format.pointee.pb) >= 0 else { throw Error.unavailable("no output buffer") }
        var output: UnsafeMutablePointer<UInt8>?
        defer { av_free(output) }
        guard avformat_write_header(format, nil) >= 0 else {
            _ = avio_close_dyn_buf(format.pointee.pb, &output)
            throw Error.unavailable("the Ogg header could not be written")
        }

        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        func drain() {
            while avcodec_receive_packet(context, packet) >= 0 {
                av_packet_rescale_ts(packet, context.pointee.time_base, stream.pointee.time_base)
                packet!.pointee.stream_index = stream.pointee.index
                av_interleaved_write_frame(format, packet)
            }
        }
        let frameSize = Int(context.pointee.frame_size > 0 ? context.pointee.frame_size : 320)
        var frame = av_frame_alloc()
        defer { av_frame_free(&frame) }
        var offset = 0
        let step = max(samples.count / 100, frameSize)
        var nextReport = 0
        while offset < samples.count {
            if let progress, offset >= nextReport {
                progress(Double(offset) / Double(samples.count))
                nextReport = offset + step
            }
            frame!.pointee.nb_samples = Int32(frameSize)
            frame!.pointee.format = AV_SAMPLE_FMT_FLT.rawValue
            frame!.pointee.sample_rate = Int32(sampleRate)
            av_channel_layout_default(&frame!.pointee.ch_layout, 1)
            guard av_frame_get_buffer(frame, 0) >= 0 else { throw Error.unavailable("no frame buffer") }
            let data = UnsafeMutableRawPointer(frame!.pointee.data.0!).assumingMemoryBound(to: Float.self)
            let count = min(frameSize, samples.count - offset)
            for index in 0..<frameSize { data[index] = index < count ? samples[offset + index] : 0 }
            frame!.pointee.pts = Int64(offset)
            avcodec_send_frame(context, frame)
            drain()
            av_frame_unref(frame)
            offset += frameSize
        }
        avcodec_send_frame(context, nil)
        drain()
        av_write_trailer(format)
        progress?(1)
        let size = avio_close_dyn_buf(format.pointee.pb, &output)
        format.pointee.pb = nil
        guard size > 0, let output else { throw Error.unavailable("nothing was encoded") }
        return Data(bytes: output, count: Int(size))
    }
}

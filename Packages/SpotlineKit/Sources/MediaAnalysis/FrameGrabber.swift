import CFFmpeg
import CoreGraphics
import Foundation
import ImageIO
import SubtitleCore
import UniformTypeIdentifiers
import Vision

/// A frame shrunk to 16×9 RGB: enough to tell whether two frames show the same
/// camera setup (the same shot, or a shot the scene cuts back to).
public struct FrameSignature: Hashable, Sendable {
    public static let width = 16
    public static let height = 9

    /// `width × height` pixels, three bytes each.
    public var pixels: [UInt8]

    public init(pixels: [UInt8]) {
        self.pixels = pixels
    }

    /// How different two frames look, 0 (the same) to 255: the mean difference per channel.
    public func distance(to other: FrameSignature) -> Double {
        guard pixels.count == other.pixels.count, !pixels.isEmpty else { return 255 }
        var sum = 0
        for index in pixels.indices { sum += abs(Int(pixels[index]) - Int(other.pixels[index])) }
        return Double(sum) / Double(pixels.count)
    }

    /// The mean level, 0 (black) to 255.
    public var brightness: Double {
        pixels.isEmpty ? 0 : Double(pixels.reduce(0) { $0 + Int($1) }) / Double(pixels.count)
    }
}

/// A face found in a frame, in the frame's unit square with the origin at the top left.
public struct FaceBox: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// One frame read from the video for a time that was asked for.
public struct GrabbedFrame: Sendable, Equatable {
    /// Which of the times asked for this frame answers.
    public var index: Int
    /// The frame's own time: the first frame decoded at or after the time asked for.
    public var time: MediaTime
    /// The frame as a JPEG, in SDR.
    public var jpeg: Data
    public var width: Int
    public var height: Int
    public var signature: FrameSignature
    /// The faces in it, found on this Mac; empty when none were looked for.
    public var faces: [FaceBox]

    public init(index: Int, time: MediaTime, jpeg: Data, width: Int, height: Int, signature: FrameSignature, faces: [FaceBox] = []) {
        self.index = index
        self.time = time
        self.jpeg = jpeg
        self.width = width
        self.height = height
        self.signature = signature
        self.faces = faces
    }
}

extension MediaAnalyzer {
    public struct FrameOptions: Sendable {
        /// The longer side of the frames, in pixels.
        public var longEdge = 768
        /// JPEG quality, 0 to 1.
        public var quality = 0.8
        /// Whether to look for faces in each frame (Apple's Vision, on this Mac).
        public var findsFaces = true
        /// Without a keyframe index, the reader jumps ahead when the next time is this far off.
        public var jumpSeconds = 12.0

        public init() {}
    }

    /// The frames at `times`: for each, the first frame the decoder gives at or after
    /// it (frames nothing refers to are skipped, so it can be a few frames later).
    /// HDR video (PQ) is brought to SDR. Times past the end get no frame. `progress`
    /// gets the number of frames read so far and returns false to cancel.
    public static func frames(
        in url: URL,
        at times: [MediaTime],
        options: FrameOptions = FrameOptions(),
        progress: (Progress<Int>) -> Bool = { _ in true }
    ) throws -> [GrabbedFrame] {
        let file = try MediaFile(url)
        let index = av_find_best_stream(file.format, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        guard index >= 0, let stream = file.streams[Int(index)] else { throw Error.noStream }
        let reader = try FrameReader(stream: stream, options: options)
        let wanted = times.enumerated().sorted { $0.element < $1.element }
        var frames: [GrabbedFrame] = []
        var next = 0
        /// The time of the last frame decoded, nil right after a jump.
        var position: MediaTime?
        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }

        func take(_ frame: UnsafeMutablePointer<AVFrame>) {
            guard let time = reader.decoder.time(of: frame) else { return }
            position = time
            guard next < wanted.count, time >= wanted[next].element else { return }
            guard var grabbed = reader.grab(frame, at: time) else { return }
            // One frame answers every time asked for up to it.
            while next < wanted.count, time >= wanted[next].element {
                grabbed.index = wanted[next].offset
                frames.append(grabbed)
                next += 1
            }
        }

        while next < wanted.count {
            if reader.shouldJump(to: wanted[next].element, from: position, in: stream) {
                let base = stream.pointee.time_base
                let target = wanted[next].element
                let timestamp = av_rescale(target.value, Int64(base.den), target.timescale * Int64(base.num))
                if av_seek_frame(file.format, index, timestamp, AVSEEK_FLAG_BACKWARD) >= 0 {
                    avcodec_flush_buffers(reader.decoder.context)
                    position = nil
                }
            }
            let target = next
            while next == target {
                guard av_read_frame(file.format, packet) >= 0 else {
                    reader.decoder.decode(nil, onFrame: take)
                    next = wanted.count
                    break
                }
                defer { av_packet_unref(packet) }
                guard packet!.pointee.stream_index == index else { continue }
                reader.decoder.decode(packet, onFrame: take)
            }
            let report = Progress(
                fraction: Double(min(next, wanted.count)) / Double(max(wanted.count, 1)), analyzedUntil: position ?? .zero,
                partial: frames.count
            )
            if !progress(report) { throw Error.cancelled }
        }
        return frames.sorted { $0.index < $1.index }
    }
}

/// Turns decoded video frames into small SDR JPEGs with a signature and faces.
final class FrameReader {
    let decoder: StreamDecoder
    private let options: MediaAnalyzer.FrameOptions
    private var scaler: UnsafeMutablePointer<SwsContext>?
    /// What the scaler was made for: source size and format, and whether it writes 16-bit RGB.
    private var scalerKey: [Int32] = []
    private var rgb: [UInt8] = []
    private var deep: [UInt16] = []

    init(stream: UnsafeMutablePointer<AVStream>, options: MediaAnalyzer.FrameOptions) throws {
        decoder = try StreamDecoder(stream: stream) { context in
            // Frames nothing refers to are not needed to decode the rest: skipping them about halves the work.
            context.pointee.skip_frame = AVDISCARD_NONREF
        }
        self.options = options
    }

    deinit {
        sws_freeContext(scaler)
    }

    /// Whether to jump to `target` instead of decoding up to it: when a keyframe lies
    /// between here and there (from the file's index), or, without an index, when it is far off.
    func shouldJump(to target: MediaTime, from position: MediaTime?, in stream: UnsafeMutablePointer<AVStream>) -> Bool {
        guard let position else { return true }
        let base = stream.pointee.time_base
        let timestamp = av_rescale(target.value, Int64(base.den), target.timescale * Int64(base.num))
        if let entry = avformat_index_get_entry_from_timestamp(stream, timestamp, AVSEEK_FLAG_BACKWARD) {
            let keyframe = MediaTime(value: entry.pointee.timestamp * Int64(base.num), timescale: Int64(base.den))
            return keyframe > position
        }
        return target.seconds - position.seconds > options.jumpSeconds
    }

    func grab(_ frame: UnsafeMutablePointer<AVFrame>, at time: MediaTime) -> GrabbedFrame? {
        let sourceWidth = Int(frame.pointee.width), sourceHeight = Int(frame.pointee.height)
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }
        // Anamorphic video is stored narrower or wider than it is shown.
        let aspect = frame.pointee.sample_aspect_ratio
        let shape = aspect.num > 0 && aspect.den > 0 ? Double(aspect.num) / Double(aspect.den) : 1
        let shownWidth = Double(sourceWidth) * shape
        let scale = min(Double(options.longEdge) / max(shownWidth, Double(sourceHeight)), 1)
        let width = max(Int((shownWidth * scale / 2).rounded()) * 2, 2)
        let height = max(Int((Double(sourceHeight) * scale / 2).rounded()) * 2, 2)
        let isPQ = frame.pointee.color_trc == AVCOL_TRC_SMPTE2084
        guard convert(frame, width: width, height: height, deep: isPQ) else { return nil }
        if isPQ { ToneMap.toSDR(deep, into: &rgb) }

        let signature = Self.signature(of: rgb, width: width, height: height)
        guard let image = Self.image(rgb, width: width, height: height), let jpeg = Self.jpeg(image, quality: options.quality) else { return nil }
        let faces = options.findsFaces ? Self.faces(in: image) : []
        return GrabbedFrame(index: 0, time: time, jpeg: jpeg, width: width, height: height, signature: signature, faces: faces)
    }

    /// Scales the frame into `rgb` (8-bit), or into `deep` (16-bit, still PQ in BT.2020) for HDR.
    private func convert(_ frame: UnsafeMutablePointer<AVFrame>, width: Int, height: Int, deep isDeep: Bool) -> Bool {
        let key = [frame.pointee.width, frame.pointee.height, frame.pointee.format, Int32(width), Int32(height), isDeep ? 1 : 0, Int32(frame.pointee.colorspace.rawValue), Int32(frame.pointee.color_range.rawValue)]
        if key != scalerKey {
            sws_freeContext(scaler)
            scaler = sws_getContext(
                frame.pointee.width, frame.pointee.height, AVPixelFormat(frame.pointee.format),
                Int32(width), Int32(height), isDeep ? AV_PIX_FMT_RGB48LE : AV_PIX_FMT_RGB24,
                Int32(SWS_AREA.rawValue), nil, nil, nil
            )
            scalerKey = key
            guard scaler != nil else { return false }
            // FFmpeg assumes BT.601 unless told: HD is BT.709, UHD HDR is BT.2020.
            let matrix: Int32 = switch frame.pointee.colorspace {
            case AVCOL_SPC_BT2020_NCL, AVCOL_SPC_BT2020_CL: SWS_CS_BT2020
            case AVCOL_SPC_BT709: SWS_CS_ITU709
            case AVCOL_SPC_BT470BG, AVCOL_SPC_SMPTE170M: SWS_CS_ITU601
            default: frame.pointee.height >= 720 ? SWS_CS_ITU709 : SWS_CS_ITU601
            }
            let isFullRange: Int32 = frame.pointee.color_range == AVCOL_RANGE_JPEG ? 1 : 0
            sws_setColorspaceDetails(scaler, sws_getCoefficients(matrix), isFullRange, sws_getCoefficients(matrix), 1, 0, 1 << 16, 1 << 16)
        }
        guard let scaler else { return false }
        // The frame's planes and their row sizes, as the arrays C sees.
        let source = UnsafeRawPointer(frame).advanced(by: MemoryLayout<AVFrame>.offset(of: \.data)!)
            .assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
        let strides = UnsafeRawPointer(frame).advanced(by: MemoryLayout<AVFrame>.offset(of: \.linesize)!)
            .assumingMemoryBound(to: Int32.self)
        if isDeep {
            if deep.count != width * height * 3 { deep = [UInt16](repeating: 0, count: width * height * 3) }
            if rgb.count != width * height * 3 { rgb = [UInt8](repeating: 0, count: width * height * 3) }
            return deep.withUnsafeMutableBytes { bytes in
                var planes: [UnsafeMutablePointer<UInt8>?] = [bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), nil, nil, nil]
                var rows: [Int32] = [Int32(width * 6), 0, 0, 0]
                return sws_scale(scaler, source, strides, 0, frame.pointee.height, &planes, &rows) > 0
            }
        }
        if rgb.count != width * height * 3 { rgb = [UInt8](repeating: 0, count: width * height * 3) }
        return rgb.withUnsafeMutableBytes { bytes in
            var planes: [UnsafeMutablePointer<UInt8>?] = [bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), nil, nil, nil]
            var rows: [Int32] = [Int32(width * 3), 0, 0, 0]
            return sws_scale(scaler, source, strides, 0, frame.pointee.height, &planes, &rows) > 0
        }
    }

    /// The mean colour of each cell of a 16×9 grid over the frame.
    static func signature(of rgb: [UInt8], width: Int, height: Int) -> FrameSignature {
        let columns = FrameSignature.width, rows = FrameSignature.height
        var sums = [Int](repeating: 0, count: columns * rows * 3)
        var counts = [Int](repeating: 0, count: columns * rows)
        rgb.withUnsafeBufferPointer { pixels in
            for y in 0..<height {
                let row = y * rows / height
                for x in 0..<width {
                    let cell = row * columns + x * columns / width
                    let offset = (y * width + x) * 3
                    sums[cell * 3] += Int(pixels[offset])
                    sums[cell * 3 + 1] += Int(pixels[offset + 1])
                    sums[cell * 3 + 2] += Int(pixels[offset + 2])
                    counts[cell] += 1
                }
            }
        }
        return FrameSignature(pixels: sums.indices.map { UInt8(sums[$0] / max(counts[$0 / 3], 1)) })
    }

    static func image(_ rgb: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(rgb) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil,
            shouldInterpolate: true, intent: .defaultIntent
        )
    }

    static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// The faces Vision finds, largest first.
    static func faces(in image: CGImage) -> [FaceBox] {
        let request = VNDetectFaceRectanglesRequest()
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return [] }
        return (request.results ?? [])
            // Vision's origin is at the bottom left.
            .map { FaceBox(x: $0.boundingBox.minX, y: 1 - $0.boundingBox.maxY, width: $0.boundingBox.width, height: $0.boundingBox.height) }
            .sorted { $0.width * $0.height > $1.width * $1.height }
    }
}

/// HDR (PQ in BT.2020, 16 bits a channel) to SDR (sRGB, 8 bits): untouched up to most
/// of SDR white, highlights rolled off above it, so faces keep their brightness.
enum ToneMap {
    /// PQ code value (12 bits) to light relative to SDR white (203 nits).
    private static let light: [Float] = (0..<4096).map { code in
        let signal = pow(Double(code) / 4095, 1 / 78.84375)
        let nits = 10000 * pow(max(signal - 0.8359375, 0) / (18.8515625 - 18.6875 * signal), 1 / 0.1593017578125)
        return Float(nits / 203)
    }

    /// Linear light (0 to 1, in 4096 steps) to sRGB.
    private static let encoded: [UInt8] = (0..<4096).map { step in
        let linear = Double(step) / 4095
        let value = linear <= 0.0031308 ? 12.92 * linear : 1.055 * pow(linear, 1 / 2.4) - 0.055
        return UInt8((min(max(value, 0), 1) * 255).rounded())
    }

    static let knee: Float = 0.7

    static func toSDR(_ deep: [UInt16], into rgb: inout [UInt8]) {
        deep.withUnsafeBufferPointer { source in
            rgb.withUnsafeMutableBufferPointer { target in
                for pixel in 0..<(source.count / 3) {
                    let r = light[Int(source[pixel * 3] >> 4)], g = light[Int(source[pixel * 3 + 1] >> 4)], b = light[Int(source[pixel * 3 + 2] >> 4)]
                    // BT.2020 to BT.709 primaries.
                    target[pixel * 3] = encode(1.6605 * r - 0.5876 * g - 0.0728 * b)
                    target[pixel * 3 + 1] = encode(-0.1246 * r + 1.1329 * g - 0.0083 * b)
                    target[pixel * 3 + 2] = encode(-0.0182 * r - 0.1006 * g + 1.1187 * b)
                }
            }
        }
    }

    private static func encode(_ value: Float) -> UInt8 {
        let rolled = value <= knee ? max(value, 0) : knee + (1 - knee) * (1 - exp(-(value - knee) / (1 - knee)))
        return encoded[Int(rolled * 4095)]
    }
}

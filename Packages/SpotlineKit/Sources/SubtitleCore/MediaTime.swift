/// An exact point in media time, stored as a reduced rational number of seconds.
///
/// Never use `Double` seconds for editing: 23.976 and 29.97 fps frame boundaries
/// are not representable exactly and rounding drifts over a feature-length timeline.
public struct MediaTime: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let value: Int64
    public let timescale: Int64

    public init(value: Int64, timescale: Int64) {
        precondition(timescale > 0, "Timescale must be positive")
        let divisor = greatestCommonDivisor(abs(value), timescale)
        self.value = value / divisor
        self.timescale = timescale / divisor
    }

    /// The start of `frame` at `rate`.
    public init(frame: Int64, rate: FrameRate) {
        self.init(value: frame * Int64(rate.denominator), timescale: Int64(rate.numerator))
    }

    /// Converts from floating-point seconds, e.g. times read from SRT or mpv.
    public init(seconds: Double, timescale: Int64 = 600_000) {
        self.init(value: Int64((seconds * Double(timescale)).rounded()), timescale: timescale)
    }

    public static let zero = MediaTime(value: 0, timescale: 1)

    public var seconds: Double { Double(value) / Double(timescale) }

    /// The frame that contains this time at `rate`.
    public func frame(at rate: FrameRate) -> Int64 {
        floorDivide(value * Int64(rate.numerator), timescale * Int64(rate.denominator))
    }

    /// The first frame that starts at or after this time: for a cue's start,
    /// the first frame showing it; for its (exclusive) end, the first frame without it.
    public func firstFrame(at rate: FrameRate) -> Int64 {
        let frame = frame(at: rate)
        return MediaTime(frame: frame, rate: rate) < self ? frame + 1 : frame
    }

    /// The frame whose start is closest to this time at `rate`.
    ///
    /// Use this for timestamps read from media: containers round frame times
    /// (MKV to the millisecond), so a frame's timestamp can land just before
    /// the exact frame boundary.
    public func nearestFrame(at rate: FrameRate) -> Int64 {
        let numerator = Int64(rate.numerator), denominator = Int64(rate.denominator)
        return floorDivide(2 * value * numerator + timescale * denominator, 2 * timescale * denominator)
    }

    /// The middle of `frame` at `rate`. Seeking here lands on `frame` even when
    /// the media's timestamps are rounded.
    public init(midpointOfFrame frame: Int64, rate: FrameRate) {
        self.init(value: (2 * frame + 1) * Int64(rate.denominator), timescale: 2 * Int64(rate.numerator))
    }

    /// This time moved back to the start of the frame that contains it.
    public func snapped(to rate: FrameRate) -> MediaTime {
        MediaTime(frame: frame(at: rate), rate: rate)
    }

    public var description: String { "\(value)/\(timescale)s" }

    public static func < (lhs: MediaTime, rhs: MediaTime) -> Bool {
        lhs.value * rhs.timescale < rhs.value * lhs.timescale
    }

    public static func + (lhs: MediaTime, rhs: MediaTime) -> MediaTime {
        MediaTime(value: lhs.value * rhs.timescale + rhs.value * lhs.timescale, timescale: lhs.timescale * rhs.timescale)
    }

    public static func - (lhs: MediaTime, rhs: MediaTime) -> MediaTime {
        MediaTime(value: lhs.value * rhs.timescale - rhs.value * lhs.timescale, timescale: lhs.timescale * rhs.timescale)
    }

    private enum CodingKeys: String, CodingKey { case value, timescale }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let timescale = try container.decode(Int64.self, forKey: .timescale)
        guard timescale > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .timescale, in: container, debugDescription: "Timescale must be positive"
            )
        }
        self.init(value: try container.decode(Int64.self, forKey: .value), timescale: timescale)
    }
}

private func greatestCommonDivisor(_ a: Int64, _ b: Int64) -> Int64 {
    var (a, b) = (a, b)
    while b != 0 { (a, b) = (b, a % b) }
    return a
}

private func floorDivide(_ a: Int64, _ b: Int64) -> Int64 {
    let quotient = a / b
    return (a % b != 0 && (a < 0) != (b < 0)) ? quotient - 1 : quotient
}

import Foundation

/// A video frame rate expressed as an exact ratio, e.g. 24000/1001 for 23.976 fps.
public struct FrameRate: Hashable, Sendable, Codable, CustomStringConvertible {
    /// Frames counted over `denominator` seconds.
    public let numerator: Int
    public let denominator: Int
    /// SMPTE drop-frame counting. Only valid for 29.97 and 59.94 fps.
    public let isDropFrame: Bool

    public init(numerator: Int, denominator: Int = 1, isDropFrame: Bool = false) {
        precondition(numerator > 0 && denominator > 0, "Frame rate must be positive")
        let base = Int((Double(numerator) / Double(denominator)).rounded())
        precondition(
            !isDropFrame || (denominator == 1001 && base % 30 == 0),
            "Drop-frame timecode only applies to 29.97 and 59.94 fps"
        )
        self.numerator = numerator
        self.denominator = denominator
        self.isDropFrame = isDropFrame
    }

    public var framesPerSecond: Double { Double(numerator) / Double(denominator) }

    /// Nominal whole-number rate used for timecode labels (24 for 23.976, 30 for 29.97).
    public var timecodeBase: Int { Int(framesPerSecond.rounded()) }

    /// Frame labels skipped at the start of each minute, except every tenth minute.
    public var droppedFramesPerMinute: Int { isDropFrame ? timecodeBase / 15 : 0 }

    public var description: String {
        var fps = String(format: "%.3f", framesPerSecond)
        while fps.hasSuffix("0") { fps.removeLast() }
        if fps.hasSuffix(".") { fps.removeLast() }
        return isDropFrame ? "\(fps) fps DF" : "\(fps) fps"
    }
}

extension FrameRate {
    public static let fps23_976 = FrameRate(numerator: 24000, denominator: 1001)
    public static let fps24 = FrameRate(numerator: 24)
    public static let fps25 = FrameRate(numerator: 25)
    public static let fps29_97 = FrameRate(numerator: 30000, denominator: 1001)
    public static let fps29_97DropFrame = FrameRate(numerator: 30000, denominator: 1001, isDropFrame: true)
    public static let fps30 = FrameRate(numerator: 30)
    public static let fps50 = FrameRate(numerator: 50)
    public static let fps59_94 = FrameRate(numerator: 60000, denominator: 1001)
    public static let fps59_94DropFrame = FrameRate(numerator: 60000, denominator: 1001, isDropFrame: true)
    public static let fps60 = FrameRate(numerator: 60)

    public static let common: [FrameRate] = [
        .fps23_976, .fps24, .fps25, .fps29_97, .fps29_97DropFrame,
        .fps30, .fps50, .fps59_94, .fps59_94DropFrame, .fps60,
    ]
}

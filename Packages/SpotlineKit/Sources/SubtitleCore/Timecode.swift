/// A SMPTE timecode label (HH:MM:SS:FF) for a frame at a given frame rate.
///
/// Drop-frame labels use `;` before the frame field and skip frame numbers
/// 00 and 01 (00-03 at 59.94) at the start of every minute except each tenth.
public struct Timecode: Hashable, Sendable, CustomStringConvertible {
    public let hours: Int
    public let minutes: Int
    public let seconds: Int
    public let frames: Int
    public let rate: FrameRate

    public var isDropFrame: Bool { rate.isDropFrame }

    /// The label for zero-based `frameNumber`.
    public init(frameNumber: Int64, rate: FrameRate) {
        precondition(frameNumber >= 0, "Negative timecodes are not supported")
        let base = Int64(rate.timecodeBase)
        var frame = frameNumber
        if rate.isDropFrame {
            let dropped = Int64(rate.droppedFramesPerMinute)
            let framesPerMinute = base * 60 - dropped
            let framesPerTenMinutes = base * 600 - dropped * 9
            let tens = frame / framesPerTenMinutes
            let remainder = frame % framesPerTenMinutes
            frame += dropped * 9 * tens
            if remainder > dropped {
                frame += dropped * ((remainder - dropped) / framesPerMinute)
            }
        }
        let totalSeconds = frame / base
        self.frames = Int(frame % base)
        self.seconds = Int(totalSeconds % 60)
        self.minutes = Int(totalSeconds / 60 % 60)
        self.hours = Int(totalSeconds / 3600)
        self.rate = rate
    }

    /// The label for the frame containing `time`.
    public init(time: MediaTime, rate: FrameRate) {
        self.init(frameNumber: time.frame(at: rate), rate: rate)
    }

    /// Returns nil for out-of-range fields and for labels drop-frame counting skips.
    public init?(hours: Int, minutes: Int, seconds: Int, frames: Int, rate: FrameRate) {
        guard hours >= 0,
              (0..<60).contains(minutes),
              (0..<60).contains(seconds),
              (0..<rate.timecodeBase).contains(frames)
        else { return nil }
        if rate.isDropFrame, seconds == 0, minutes % 10 != 0, frames < rate.droppedFramesPerMinute {
            return nil
        }
        self.hours = hours
        self.minutes = minutes
        self.seconds = seconds
        self.frames = frames
        self.rate = rate
    }

    /// Parses `HH:MM:SS:FF`, accepting `:`, `;`, `.` or `,` as separators.
    public init?(_ string: String, rate: FrameRate) {
        let fields = string.split(whereSeparator: { ":;.,".contains($0) })
        guard fields.count == 4,
              let hours = Int(fields[0]), let minutes = Int(fields[1]),
              let seconds = Int(fields[2]), let frames = Int(fields[3])
        else { return nil }
        self.init(hours: hours, minutes: minutes, seconds: seconds, frames: frames, rate: rate)
    }

    /// Zero-based frame number this label refers to.
    public var frameNumber: Int64 {
        let base = Int64(rate.timecodeBase)
        let totalMinutes = Int64(hours) * 60 + Int64(minutes)
        var frame = (totalMinutes * 60 + Int64(seconds)) * base + Int64(frames)
        if rate.isDropFrame {
            frame -= Int64(rate.droppedFramesPerMinute) * (totalMinutes - totalMinutes / 10)
        }
        return frame
    }

    public var time: MediaTime { MediaTime(frame: frameNumber, rate: rate) }

    public var description: String {
        let separator = isDropFrame ? ";" : ":"
        return "\(twoDigits(hours)):\(twoDigits(minutes)):\(twoDigits(seconds))\(separator)\(twoDigits(frames))"
    }
}

private func twoDigits(_ value: Int) -> String {
    value < 10 ? "0\(value)" : "\(value)"
}

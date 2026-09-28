import Foundation
import SubtitleCore

/// What Spotline reads from a media file once: the audio waveform and the shot changes.
public struct MediaAnalysis: Sendable, Codable, Equatable {
    public var waveform: Waveform?
    /// Times of the first frame of each new shot, in order.
    public var shotChanges: [MediaTime]

    public init(waveform: Waveform?, shotChanges: [MediaTime]) {
        self.waveform = waveform
        self.shotChanges = shotChanges
    }
}

/// Audio peaks for drawing: the loudest sample of each fixed-length bucket, mixed to mono.
public struct Waveform: Sendable, Codable, Equatable {
    public static let defaultBucketsPerSecond = 100

    public let bucketsPerSecond: Int
    /// Peak amplitude per bucket, 0 (silence) to 255 (full scale).
    public var peaks: [UInt8]

    public init(bucketsPerSecond: Int = defaultBucketsPerSecond, peaks: [UInt8] = []) {
        precondition(bucketsPerSecond > 0)
        self.bucketsPerSecond = bucketsPerSecond
        self.peaks = peaks
    }

    /// The loudest peak between two times in seconds, 0 to 1. Display only.
    public func peak(from start: Double, to end: Double) -> Float {
        let first = max(Int((start * Double(bucketsPerSecond)).rounded(.down)), 0)
        let last = min(Int((end * Double(bucketsPerSecond)).rounded(.up)), peaks.count)
        guard first < last else { return 0 }
        return Float(peaks[first..<last].max() ?? 0) / 255
    }

    private enum CodingKeys: String, CodingKey { case bucketsPerSecond, peaks }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bucketsPerSecond = try container.decode(Int.self, forKey: .bucketsPerSecond)
        peaks = [UInt8](try container.decode(Data.self, forKey: .peaks))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bucketsPerSecond, forKey: .bucketsPerSecond)
        try container.encode(Data(peaks), forKey: .peaks)
    }
}

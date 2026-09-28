import AppKit
import SubtitleCore

/// A synchronous stand-in for a real player: media of a fixed length and rate
/// with no decoding. Every request takes effect immediately.
@MainActor
public final class SimulatedPlaybackEngine: PlaybackEngine {
    public private(set) var status = PlaybackStatus()
    public var onStatusChange: (@MainActor (PlaybackStatus) -> Void)?

    public let frameRate: FrameRate
    public let frameCount: Int64

    public init(frameRate: FrameRate = .fps23_976, frameCount: Int64 = 1_000) {
        self.frameRate = frameRate
        self.frameCount = frameCount
    }

    public func load(_ url: URL) {
        update(PlaybackStatus(
            mediaURL: url,
            duration: MediaTime(frame: frameCount, rate: frameRate),
            frameRate: frameRate
        ))
    }

    public func setPaused(_ paused: Bool) {
        guard status.hasMedia else { return }
        var next = status
        next.isPaused = paused
        update(next)
    }

    public func seek(toFrame frame: Int64, rate: FrameRate) {
        guard status.hasMedia else { return }
        let time = MediaTime(midpointOfFrame: frame, rate: rate)
        show(frame: time.frame(at: frameRate), paused: status.isPaused)
    }

    public func step(by frames: Int) {
        guard status.hasMedia else { return }
        show(frame: status.position.nearestFrame(at: frameRate) + Int64(frames), paused: true)
    }

    public func videoView() -> NSView? { nil }

    /// Switches audio tracks, as a person can in a real player.
    public func selectAudioStream(_ index: Int?) {
        guard status.hasMedia else { return }
        var next = status
        next.audioStreamIndex = index
        update(next)
    }

    private func show(frame: Int64, paused: Bool) {
        let clamped = min(max(frame, 0), frameCount - 1)
        var next = status
        next.position = MediaTime(frame: clamped, rate: frameRate)
        next.isPaused = paused
        next.isAtEnd = clamped == frameCount - 1
        update(next)
    }

    private func update(_ next: PlaybackStatus) {
        status = next
        onStatusChange?(next)
    }
}

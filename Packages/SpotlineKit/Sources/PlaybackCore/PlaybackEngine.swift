import AppKit
import SubtitleCore

/// What the player is showing, published to the editor on the main actor.
public struct PlaybackStatus: Equatable, Sendable {
    /// The open media file, nil when nothing is loaded.
    public var mediaURL: URL?
    public var isPaused: Bool
    /// Timestamp of the frame on screen.
    public var position: MediaTime
    public var duration: MediaTime?
    /// The video's frame rate, nil until the media reports one.
    public var frameRate: FrameRate?
    /// True while paused on the last frame after playback reached the end.
    public var isAtEnd: Bool
    /// FFmpeg's index of the audio stream being played, nil when none or unknown.
    public var audioStreamIndex: Int?

    public init(
        mediaURL: URL? = nil,
        isPaused: Bool = true,
        position: MediaTime = .zero,
        duration: MediaTime? = nil,
        frameRate: FrameRate? = nil,
        isAtEnd: Bool = false,
        audioStreamIndex: Int? = nil
    ) {
        self.mediaURL = mediaURL
        self.isPaused = isPaused
        self.position = position
        self.duration = duration
        self.frameRate = frameRate
        self.isAtEnd = isAtEnd
        self.audioStreamIndex = audioStreamIndex
    }

    public var hasMedia: Bool { mediaURL != nil }
}

/// A video player the editor drives. `MPVPlayer` is the real one;
/// `SimulatedPlaybackEngine` stands in for it in unit tests.
///
/// Requests are asynchronous: the engine reports their effect through
/// `onStatusChange`, which is the only source of truth for playback state.
@MainActor
public protocol PlaybackEngine: AnyObject {
    var status: PlaybackStatus { get }
    var onStatusChange: (@MainActor (PlaybackStatus) -> Void)? { get set }

    /// Opens `url` paused on its first frame.
    func load(_ url: URL)
    func setPaused(_ paused: Bool)
    /// Shows `frame` exactly, counted at `rate` from the start of the media.
    func seek(toFrame frame: Int64, rate: FrameRate)
    /// Pauses and shows the next or previous frame.
    func step(by frames: Int)

    /// The view that shows the video. Engines return the same view every time,
    /// or nil when they draw nothing.
    func videoView() -> NSView?
}

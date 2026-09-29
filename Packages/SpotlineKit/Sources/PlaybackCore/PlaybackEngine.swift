import AppKit
import SubtitleCore

/// An audio track of the open media.
public struct AudioTrack: Identifiable, Hashable, Sendable {
    /// The player's track ID, used to select it.
    public let id: Int
    /// FFmpeg's stream index, which media analysis reads.
    public var streamIndex: Int?
    /// BCP 47 or ISO 639 language code from the file, e.g. "eng" or "ar".
    public var language: String?
    public var title: String?
    public var channelCount: Int?

    public init(id: Int, streamIndex: Int? = nil, language: String? = nil, title: String? = nil, channelCount: Int? = nil) {
        self.id = id
        self.streamIndex = streamIndex
        self.language = language
        self.title = title
        self.channelCount = channelCount
    }

    /// E.g. "English · Original · 5.1", or "Track 2" when the file says nothing.
    public var displayName: String {
        var parts: [String] = []
        if let language, let name = Locale.current.localizedString(forLanguageCode: language) { parts.append(name) }
        else if let language { parts.append(language) }
        if let title, !title.isEmpty, !parts.contains(title) { parts.append(title) }
        if let channels = channelCount { parts.append(Self.channelLabel(channels)) }
        return parts.isEmpty ? "Track \(id)" : parts.joined(separator: " · ")
    }

    private static func channelLabel(_ count: Int) -> String {
        switch count {
        case 1: "Mono"
        case 2: "Stereo"
        case 6: "5.1"
        case 8: "7.1"
        default: "\(count) ch"
        }
    }
}

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
    /// Every audio track of the open media, in file order.
    public var audioTracks: [AudioTrack]
    /// The audio track being played, nil when audio is off.
    public var selectedAudioTrackID: Int?
    /// Playback speed while playing: 1 is normal, 2 double, negative plays backward.
    public var rate: Double = 1

    public init(
        mediaURL: URL? = nil,
        isPaused: Bool = true,
        position: MediaTime = .zero,
        duration: MediaTime? = nil,
        frameRate: FrameRate? = nil,
        isAtEnd: Bool = false,
        audioStreamIndex: Int? = nil,
        audioTracks: [AudioTrack] = [],
        selectedAudioTrackID: Int? = nil
    ) {
        self.mediaURL = mediaURL
        self.isPaused = isPaused
        self.position = position
        self.duration = duration
        self.frameRate = frameRate
        self.isAtEnd = isAtEnd
        self.audioStreamIndex = audioStreamIndex
        self.audioTracks = audioTracks
        self.selectedAudioTrackID = selectedAudioTrackID
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
    /// Plays at `rate` times normal speed; negative rates play backward.
    func play(rate: Double)
    /// Shows `frame` exactly, counted at `rate` from the start of the media.
    func seek(toFrame frame: Int64, rate: FrameRate)
    /// Pauses and shows the next or previous frame.
    func step(by frames: Int)
    /// Plays the audio track with this ID from `status.audioTracks`.
    func selectAudioTrack(id: Int)

    /// The view that shows the video. Engines return the same view every time,
    /// or nil when they draw nothing.
    func videoView() -> NSView?
}

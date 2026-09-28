import AppKit
import EditorCommands
import MPVPlayer
import Observation
import PlaybackCore
import SubtitleCore
import UniformTypeIdentifiers

/// The editor's observable state and the single place commands are executed.
///
/// Playback state comes only from the engine's status updates: commands send
/// requests, and the timecode shows the frame the engine reports on screen.
@MainActor
@Observable
public final class EditorState {
    public let launchOptions: LaunchOptions
    @ObservationIgnored public let playback: any PlaybackEngine
    public private(set) var status: PlaybackStatus
    public var frameRate: FrameRate
    public var track: SubtitleTrack
    /// Asks the user for a media file. Tests replace it.
    @ObservationIgnored public var chooseMedia: @MainActor () -> URL? = EditorState.presentOpenPanel

    public init(
        launchOptions: LaunchOptions = .current,
        playback: any PlaybackEngine,
        frameRate: FrameRate = .fps23_976,
        track: SubtitleTrack = SubtitleTrack()
    ) {
        self.launchOptions = launchOptions
        self.playback = playback
        self.status = playback.status
        self.frameRate = frameRate
        self.track = track
        playback.onStatusChange = { [weak self] status in self?.playbackDidChange(status) }
        if let url = launchOptions.mediaURL { open(url) }
    }

    /// An editor playing through libmpv, configured for UI tests when launched with `-UITestMode`.
    public convenience init(launchOptions: LaunchOptions = .current) {
        let testMode = launchOptions.isUITestMode
        let player: MPVPlayer
        do {
            player = try MPVPlayer(configuration: .init(playsAudio: !testMode, usesHardwareDecoding: !testMode))
        } catch {
            fatalError("libmpv failed to start: \(error)")
        }
        self.init(launchOptions: launchOptions, playback: player)
    }

    public var hasMedia: Bool { status.hasMedia }
    public var isPlaying: Bool { hasMedia && !status.isPaused }
    public var currentFrame: Int64 { status.position.nearestFrame(at: frameRate) }
    public var currentTime: MediaTime { MediaTime(frame: currentFrame, rate: frameRate) }
    public var timecode: Timecode { Timecode(frameNumber: max(currentFrame, 0), rate: frameRate) }

    /// Opens a media file, replacing the current one.
    public func open(_ url: URL) {
        playback.load(url)
    }

    public func canPerform(_ command: EditorCommand) -> Bool {
        switch command.id {
        case EditorCommand.openMedia.id:
            true
        case EditorCommand.togglePlay.id, EditorCommand.stepForward.id:
            hasMedia
        case EditorCommand.stepBackward.id, EditorCommand.goToStart.id:
            hasMedia && currentFrame > 0
        default:
            false
        }
    }

    /// Runs `command`. Returns false when it is unknown or not currently possible.
    @discardableResult
    public func perform(_ command: EditorCommand) -> Bool {
        guard canPerform(command) else { return false }
        switch command.id {
        case EditorCommand.openMedia.id:
            if let url = chooseMedia() { open(url) }
        case EditorCommand.togglePlay.id:
            playback.setPaused(isPlaying)
        case EditorCommand.stepForward.id:
            playback.step(by: 1)
        case EditorCommand.stepBackward.id:
            playback.step(by: -1)
        case EditorCommand.goToStart.id:
            playback.setPaused(true)
            playback.seek(toFrame: 0, rate: frameRate)
        default:
            return false
        }
        return true
    }

    private func playbackDidChange(_ status: PlaybackStatus) {
        if let rate = status.frameRate, rate != self.status.frameRate {
            frameRate = rate
        }
        self.status = status
    }

    private static func presentOpenPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.title = EditorCommand.openMedia.title
        panel.allowedContentTypes = [.movie, .audiovisualContent, .audio]
            + ["mkv", "webm", "mxf", "ts", "m2ts"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}

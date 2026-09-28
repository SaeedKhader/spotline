import EditorCommands
import Observation
import SubtitleCore

/// The editor's observable state and the single place commands are executed.
///
/// Playback is simulated until the mpv player lands (M1): stepping moves a
/// frame counter so the command path, timecode display and UI tests are real.
@MainActor
@Observable
public final class EditorState {
    public let launchOptions: LaunchOptions
    public var frameRate: FrameRate
    public var track: SubtitleTrack
    public private(set) var currentFrame: Int64 = 0
    public private(set) var isPlaying = false

    public init(
        launchOptions: LaunchOptions = .current,
        frameRate: FrameRate = .fps23_976,
        track: SubtitleTrack = SubtitleTrack()
    ) {
        self.launchOptions = launchOptions
        self.frameRate = frameRate
        self.track = track
    }

    public var currentTime: MediaTime { MediaTime(frame: currentFrame, rate: frameRate) }
    public var timecode: Timecode { Timecode(frameNumber: currentFrame, rate: frameRate) }

    public func canPerform(_ command: EditorCommand) -> Bool {
        switch command.id {
        case EditorCommand.stepBackward.id, EditorCommand.goToStart.id:
            currentFrame > 0
        case EditorCommand.togglePlay.id, EditorCommand.stepForward.id:
            true
        default:
            false
        }
    }

    /// Runs `command`. Returns false when it is unknown or not currently possible.
    @discardableResult
    public func perform(_ command: EditorCommand) -> Bool {
        guard canPerform(command) else { return false }
        switch command.id {
        case EditorCommand.togglePlay.id:
            isPlaying.toggle()
        case EditorCommand.stepForward.id:
            isPlaying = false
            currentFrame += 1
        case EditorCommand.stepBackward.id:
            isPlaying = false
            currentFrame -= 1
        case EditorCommand.goToStart.id:
            isPlaying = false
            currentFrame = 0
        default:
            return false
        }
        return true
    }
}

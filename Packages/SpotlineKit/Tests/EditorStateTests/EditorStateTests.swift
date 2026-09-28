import EditorCommands
import Foundation
import PlaybackCore
import SubtitleCore
import Testing
@testable import EditorUI

@MainActor
struct EditorStateTests {
    let media = URL(fileURLWithPath: "/tmp/clip.mov")

    func makeEditor(frameRate: FrameRate = .fps23_976, openMedia: Bool = true) -> EditorState {
        let editor = EditorState(
            launchOptions: LaunchOptions(isUITestMode: true),
            playback: SimulatedPlaybackEngine(frameRate: frameRate)
        )
        if openMedia { editor.open(media) }
        return editor
    }

    @Test func steppingForwardAdvancesTimecode() {
        let editor = makeEditor()
        for _ in 0..<10 { editor.perform(.stepForward) }
        #expect(editor.currentFrame == 10)
        #expect(editor.timecode.description == "00:00:00:10")
    }

    @Test func steppingBackwardStopsAtStart() {
        let editor = makeEditor()
        editor.perform(.stepForward)
        #expect(editor.perform(.stepBackward))
        #expect(!editor.perform(.stepBackward))
        #expect(editor.currentFrame == 0)
    }

    @Test func stepPausesPlayback() {
        let editor = makeEditor()
        editor.perform(.togglePlay)
        #expect(editor.isPlaying)
        editor.perform(.stepForward)
        #expect(!editor.isPlaying)
    }

    @Test func goToStartPausesOnFrameZero() {
        let editor = makeEditor()
        for _ in 0..<5 { editor.perform(.stepForward) }
        editor.perform(.togglePlay)
        #expect(editor.perform(.goToStart))
        #expect(editor.currentFrame == 0)
        #expect(!editor.isPlaying)
    }

    @Test func playbackCommandsNeedMedia() {
        let editor = makeEditor(openMedia: false)
        #expect(editor.canPerform(.openMedia))
        for command in [EditorCommand.togglePlay, .stepForward, .stepBackward, .goToStart] {
            #expect(!editor.perform(command), "\(command.id)")
        }
    }

    @Test func openMediaLoadsTheChosenFile() {
        let editor = makeEditor(openMedia: false)
        editor.chooseMedia = { media }
        #expect(editor.perform(.openMedia))
        #expect(editor.status.mediaURL == media)
    }

    @Test func frameRateFollowsTheMedia() {
        let editor = makeEditor(frameRate: .fps25)
        #expect(editor.frameRate == .fps25)
        #expect(editor.status.frameRate == .fps25)
    }

    @Test func unknownCommandsAreRejected() {
        let editor = makeEditor()
        let unknown = EditorCommand(id: "test.unknown", title: "Unknown", category: .editing)
        #expect(!editor.perform(unknown))
    }
}

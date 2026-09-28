import EditorCommands
import Testing
@testable import EditorUI

@MainActor
struct EditorStateTests {
    @Test func steppingForwardAdvancesTimecode() {
        let editor = EditorState(launchOptions: LaunchOptions(isUITestMode: true))
        for _ in 0..<10 { editor.perform(.stepForward) }
        #expect(editor.currentFrame == 10)
        #expect(editor.timecode.description == "00:00:00:10")
    }

    @Test func steppingBackwardStopsAtStart() {
        let editor = EditorState(launchOptions: LaunchOptions(isUITestMode: true))
        editor.perform(.stepForward)
        #expect(editor.perform(.stepBackward))
        #expect(!editor.perform(.stepBackward))
        #expect(editor.currentFrame == 0)
    }

    @Test func stepPausesPlayback() {
        let editor = EditorState(launchOptions: LaunchOptions(isUITestMode: true))
        editor.perform(.togglePlay)
        #expect(editor.isPlaying)
        editor.perform(.stepForward)
        #expect(!editor.isPlaying)
    }

    @Test func unknownCommandsAreRejected() {
        let editor = EditorState(launchOptions: LaunchOptions(isUITestMode: true))
        let unknown = EditorCommand(id: "test.unknown", title: "Unknown", category: .editing)
        #expect(!editor.perform(unknown))
    }
}

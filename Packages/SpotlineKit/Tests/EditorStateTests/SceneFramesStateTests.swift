import EditorCommands
import Foundation
import MediaAnalysis
import PlaybackCore
import SubtitleCore
import Testing
@testable import EditorUI

@MainActor
struct SceneFramesStateTests {
    let rate = FrameRate.fps25
    let media = URL(fileURLWithPath: "/tmp/episode.mkv")

    nonisolated static func time(_ seconds: Double) -> MediaTime { MediaTime(seconds: seconds) }

    /// Four one-second lines, two seconds apart.
    static let cues = (0..<4).map { Cue(start: time(Double($0) * 2), end: time(Double($0) * 2 + 1), text: "Line \($0 + 1)", voices: ["speaker_\($0 % 2)"]) }

    /// A frame for every time asked for: the two speakers' setups in turn, the first with two faces.
    nonisolated static func grabbed(_ times: [MediaTime]) -> [GrabbedFrame] {
        times.enumerated().map { index, time in
            let level: UInt8 = index.isMultiple(of: 2) ? 40 : 160
            let faces = (0..<(index == 0 ? 2 : 1)).map { _ in FaceBox(x: 0.4, y: 0.3, width: 0.1, height: 0.2) }
            return GrabbedFrame(
                index: index, time: time, jpeg: Data([0xFF, 0xD8, UInt8(index)]), width: 768, height: 432,
                signature: FrameSignature(pixels: [UInt8](repeating: level, count: FrameSignature.width * FrameSignature.height * 3)), faces: faces
            )
        }
    }

    func makeEditor(cues: [Cue] = cues) -> EditorState {
        let editor = EditorState(
            launchOptions: LaunchOptions(isUITestMode: true), playback: SimulatedPlaybackEngine(frameRate: rate), track: SubtitleTrack(cues: cues)
        )
        editor.analyzeWaveform = { _, _, _ in throw CancellationError() }
        editor.analyzeSpeech = { _, _, _ in [] }
        editor.analyzeShotChanges = { _, _ in [] }
        editor.listEmbeddedSubtitles = { _ in [] }
        editor.grabFrames = { _, times, _ in Self.grabbed(times) }
        editor.reportError = { title, error in Issue.record("\(title) \(error)") }
        return editor
    }

    func settle(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
    }

    @Test func needsMediaAndLines() async {
        let editor = makeEditor()
        #expect(!editor.canPerform(.showSceneFrames), "No media yet")
        editor.open(media)
        await settle { editor.hasMedia }
        #expect(editor.canPerform(.showSceneFrames))
        #expect(!editor.canPerform(.exportSceneFrames), "Nothing picked yet")

        let empty = makeEditor(cues: [])
        empty.open(media)
        await settle { empty.hasMedia }
        #expect(!empty.canPerform(.showSceneFrames), "No lines to pick frames for")
    }

    @Test func picksTheFramesOnceAndShowsThem() async {
        let editor = makeEditor()
        editor.open(media)
        await settle { editor.hasMedia }
        #expect(editor.perform(.showSceneFrames))
        #expect(editor.isSceneFramesSheetShown)
        #expect(editor.sceneFramesJob != nil)
        #expect(!editor.canPerform(.pickSceneFramesAgain), "Already picking")
        await settle { editor.sceneFrames != nil }

        let scenes = try! #require(editor.sceneFrames)
        #expect(editor.sceneFramesJob == nil)
        #expect(scenes.count == 1)
        #expect(scenes[0].lines == 0...3)
        #expect(scenes[0].picks.count == 2, "One frame for each speaker's setup")
        #expect(scenes[0].picks.map(\.isWidest) == [true, false])
        #expect(scenes[0].picks.map(\.lines) == [[0, 2], [1, 3]])
        #expect(editor.sceneFrameCues(scenes[0].lines).map(\.text) == ["Line 1", "Line 2", "Line 3", "Line 4"])

        // Opening it again reads nothing; Pick Again does.
        editor.dismissSceneFrames()
        editor.grabFrames = { _, _, _ in
            Issue.record("Read the frames again")
            return []
        }
        #expect(editor.perform(.showSceneFrames))
        #expect(editor.sceneFramesJob == nil)
        editor.grabFrames = { _, times, _ in Array(Self.grabbed(times).prefix(2)) }
        #expect(editor.perform(.pickSceneFramesAgain))
        await settle { editor.sceneFramesJob == nil }
        #expect(editor.sceneFrames?.first?.frameCount == 2)
    }

    @Test func aFrameShowsInTheVideo() async {
        let editor = makeEditor()
        editor.open(media)
        await settle { editor.hasMedia }
        editor.perform(.showSceneFrames)
        await settle { editor.sceneFrames != nil }
        let pick = try! #require(editor.sceneFrames?.first?.picks.last)
        editor.showSceneFrame(at: pick.frame.time)
        #expect(!editor.isSceneFramesSheetShown)
        await settle { editor.currentFrame == pick.frame.time.nearestFrame(at: rate) }
        #expect(editor.currentFrame == pick.frame.time.nearestFrame(at: rate))
    }

    @Test func exportsTheFramesAndAListOfScenes() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SceneFramesStateTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let editor = makeEditor()
        editor.chooseSceneFramesFolder = { folder }
        editor.open(media)
        await settle { editor.hasMedia }
        editor.perform(.showSceneFrames)
        await settle { editor.sceneFrames != nil }
        #expect(editor.perform(.exportSceneFrames))

        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names == ["scene-01-frame-1.jpg", "scene-01-frame-2.jpg", "scenes.json"])
        let listed = try JSONDecoder().decode([SceneFramesExport.Scene].self, from: Data(contentsOf: folder.appending(path: "scenes.json")))
        #expect(listed.count == 1)
        #expect(listed[0].frames.map(\.file) == ["scene-01-frame-1.jpg", "scene-01-frame-2.jpg"])
        #expect(listed[0].frames.map(\.faces) == [2, 1])
        #expect(listed[0].frames.map(\.isWidest) == [true, false])
        #expect(listed[0].lines.map(\.text) == ["Line 1", "Line 2", "Line 3", "Line 4"])
        #expect(listed[0].lines.map(\.voice) == ["speaker_0", "speaker_1", "speaker_0", "speaker_1"])
        #expect(listed[0].start == "00:00:00:00")
    }

    @Test func aFailureIsReportedAndClosesTheSheet() async {
        let editor = makeEditor()
        var reported: [String] = []
        editor.reportError = { title, _ in reported.append(title) }
        editor.grabFrames = { _, _, _ in throw MediaAnalyzer.Error.noStream }
        editor.open(media)
        await settle { editor.hasMedia }
        editor.perform(.showSceneFrames)
        await settle { !reported.isEmpty }
        #expect(reported == ["The scene frames could not be picked."])
        #expect(!editor.isSceneFramesSheetShown)
        #expect(editor.sceneFrames == nil)
    }

    @Test func otherMediaForgetsTheFrames() async {
        let editor = makeEditor()
        editor.open(media)
        await settle { editor.hasMedia }
        editor.perform(.showSceneFrames)
        await settle { editor.sceneFrames != nil }
        editor.open(URL(fileURLWithPath: "/tmp/other.mkv"))
        #expect(editor.sceneFrames == nil)
        #expect(!editor.isSceneFramesSheetShown)
    }

    @Test func agentsCannotOpenTheExportDialog() {
        #expect(EditorState.commandsAgentsCannotRun.contains(EditorCommand.exportSceneFrames.id))
    }
}

import AITools
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

    /// Waits for work off the main actor; a loaded machine takes a while.
    func settle(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
        for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
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

    @Test func picksTheFramesOnceAndShowsThem() async throws {
        let editor = makeEditor()
        editor.open(media)
        await settle { editor.hasMedia }
        #expect(editor.perform(.showSceneFrames))
        #expect(editor.isSceneFramesSheetShown)
        #expect(editor.sceneFramesJob != nil)
        #expect(!editor.canPerform(.pickSceneFramesAgain), "Already picking")
        await settle { editor.sceneFrames != nil }

        let scenes = try #require(editor.sceneFrames)
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

    @Test func aFrameShowsInTheVideo() async throws {
        let editor = makeEditor()
        editor.open(media)
        await settle { editor.hasMedia }
        editor.perform(.showSceneFrames)
        await settle { editor.sceneFrames != nil }
        let pick = try #require(editor.sceneFrames?.first?.picks.last)
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

/// Describing the scenes from their frames, into the episode brief.
@MainActor
struct SceneSheetStateTests {
    let frames = SceneFramesStateTests()

    /// An editor with media, four lines, a brief naming speaker_0 Rick, and the scripted describer.
    func makeEditor(describer: (any SceneDescriber)? = ScriptedSceneDescriber()) async -> EditorState {
        let editor = frames.makeEditor()
        editor.aiProviders = AIProviderFactory(
            transcriber: { _ in ScriptedTranscriber.fixture }, translator: { _ in ScriptedTranslator() },
            briefBuilder: { _ in ScriptedBriefBuilder() }, sceneDescriber: { _ in describer }
        )
        editor.open(frames.media)
        await frames.settle { editor.hasMedia }
        editor.edit("Brief") { track in
            track.brief = EpisodeBrief(people: [EpisodeBrief.Person(voices: ["speaker_0"], name: "Rick", gender: .male)], targetLanguage: "ar")
        }
        return editor
    }

    func finish(_ editor: EditorState) async {
        for _ in 0..<300 where editor.aiTask != nil { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func needsABrief() async {
        let editor = await makeEditor()
        #expect(editor.canPerform(.describeScenes))
        editor.edit("No brief") { track in track.brief = nil }
        #expect(!editor.canPerform(.describeScenes))
    }

    @Test func picksTheFramesDescribesTheScenesAndOpensTheBrief() async throws {
        let editor = await makeEditor()
        #expect(editor.sceneFrames == nil)
        #expect(editor.perform(.describeScenes))
        #expect(editor.aiTask?.stages == ["Picking frames", "Describing scenes"])
        #expect(!editor.canPerform(.describeScenes), "Already running")
        await finish(editor)

        #expect(editor.sceneFrames?.count == 1, "The frames were picked on the way")
        #expect(editor.track.brief?.seen == "0:00 Two people talk in a room (2 frames, 4 lines). In view: Rick (a man in a lab coat).")
        #expect(editor.isBriefSheetShown)
        #expect(editor.track.brief?.isConfirmed == false)
        // The translator gets it once the brief is confirmed.
        #expect(editor.translatorNotesWithBrief == nil)
        editor.confirmEpisodeBrief(try #require(editor.track.brief))
        #expect(editor.translatorNotesWithBrief?.contains("What the video shows") == true)
        // One undoable edit.
        editor.perform(.undo)
        editor.perform(.undo)
        #expect(editor.track.brief?.seen.isEmpty == true)
    }

    @Test func theRequestNamesWhoSpeaksFromTheBrief() async throws {
        let editor = await makeEditor()
        editor.perform(.showSceneFrames)
        await frames.settle { editor.sceneFrames != nil }
        let requests = editor.sceneRequests(for: try #require(editor.sceneFrames), brief: try #require(editor.track.brief))
        #expect(requests.count == 1)
        #expect(requests[0].frames.map(\.isWidest) == [true, false])
        #expect(requests[0].lines.map(\.name) == ["Rick", nil, "Rick", nil])
        #expect(requests[0].lines.map(\.voices) == [["speaker_0"], ["speaker_1"], ["speaker_0"], ["speaker_1"]])
        #expect(requests[0].people == [SceneRequest.Person(name: "Rick", gender: .male)])
    }

    @Test func fromTheDialogWhatWasEditedThereIsKept() async throws {
        let editor = await makeEditor()
        var draft = try #require(editor.track.brief)
        draft.people[0].name = "Rick Sanchez"
        editor.isBriefSheetShown = true
        editor.describeScenes(keeping: draft)
        #expect(!editor.isBriefSheetShown)
        await finish(editor)
        #expect(editor.track.brief?.people[0].name == "Rick Sanchez")
        #expect(editor.track.brief?.seen.contains("In view: Rick Sanchez") == true)
        #expect(editor.isBriefSheetShown)
    }

    @Test func withoutAllowingFramesNothingIsSent() async {
        let editor = await makeEditor()
        var reported: [String] = []
        editor.reportError = { _, error in reported.append(error.localizedDescription) }
        editor.aiProviders.sceneDescriber = { settings in
            guard settings.sendsVideoFrames else { throw AIError.videoFramesNotAllowed }
            return ScriptedSceneDescriber()
        }
        #expect(editor.perform(.describeScenes))
        #expect(editor.aiTask == nil)
        #expect(reported.first?.contains("Send video frames") == true)
        #expect(editor.track.brief?.seen.isEmpty == true)
    }

    @Test func afterTheBriefIsBuiltTheScenesAreDescribedWhenFramesMayBeSent() async {
        let editor = await makeEditor()
        editor.aiSettings.sendsVideoFrames = true
        editor.buildEpisodeBrief(automatically: false)
        for _ in 0..<300 where editor.track.brief?.seen.isEmpty != false { try? await Task.sleep(for: .milliseconds(10)) }
        await finish(editor)
        #expect(editor.track.brief?.seen.contains("In view: Rick") == true)
        #expect(editor.isBriefSheetShown)

        // Off: the brief opens as before, and what the video showed stays.
        editor.dismissEpisodeBrief()
        editor.aiSettings.sendsVideoFrames = false
        editor.buildEpisodeBrief(automatically: false)
        for _ in 0..<300 where !editor.isBriefSheetShown { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(editor.track.brief?.seen.contains("In view: Rick") == true)
    }

    @Test func theFramesAreReadWhileTheBriefIsBuiltAndOnlyOnce() async {
        let editor = await makeEditor()
        let reads = Reads()
        editor.grabFrames = { _, times, _ in
            reads.add()
            return SceneFramesStateTests.grabbed(times)
        }
        // Off: building the brief reads no frames.
        editor.buildEpisodeBrief(automatically: false)
        #expect(editor.sceneFramesJob == nil)
        for _ in 0..<300 where !editor.isBriefSheetShown { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(reads.count == 0)

        editor.dismissEpisodeBrief()
        editor.aiSettings.sendsVideoFrames = true
        editor.buildEpisodeBrief(automatically: false)
        #expect(editor.sceneFramesJob != nil, "Reading starts with the brief, not after it")
        for _ in 0..<300 where !editor.isBriefSheetShown { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(editor.track.brief?.seen.contains("In view: Rick") == true)
        #expect(reads.count == 1, "Describing waits for the frames being read instead of reading them again")
    }

    @Test func theDialogCanTurnOnSendingFramesAndDescribe() async throws {
        let editor = await makeEditor()
        #expect(!editor.aiSettings.sendsVideoFrames)
        editor.describeScenes(keeping: try #require(editor.track.brief), allowingFrames: true)
        #expect(editor.aiSettings.sendsVideoFrames)
        await finish(editor)
        #expect(editor.track.brief?.seen.contains("In view: Rick") == true)
    }

    final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0
        var count: Int { lock.withLock { reads } }
        func add() { lock.withLock { reads += 1 } }
    }

    @Test func settingIsOffByDefaultAndSaved() throws {
        #expect(!AISettings().sendsVideoFrames)
        let suite = "SceneSheetStateTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = AISettings()
        settings.sendsVideoFrames = true
        settings.save(to: defaults)
        #expect(AISettings.load(from: defaults).sendsVideoFrames)
    }
}

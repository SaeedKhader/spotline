import AITools
import EditorCommands
import Foundation
import MediaAnalysis
import PlaybackCore
import SubtitleCore
import Testing
@testable import EditorUI

/// A new window's start screen: the video, its subtitle, then Translate or Just Edit.
@MainActor
struct StartScreenStateTests {
    /// A folder with a video and the files a user would have beside it.
    final class Folder {
        let url = FileManager.default.temporaryDirectory.appending(path: "StartScreenStateTests-\(UUID().uuidString)")
        init(_ names: [String]) throws {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for name in names {
                let text = name.hasSuffix(".srt") ? "1\n00:00:01,000 --> 00:00:02,000\nHello there.\n\n2\n00:00:03,000 --> 00:00:04,000\nHow are you?\n" : "video"
                try text.write(to: url.appending(path: name), atomically: true, encoding: .utf8)
            }
        }
        func file(_ name: String) -> URL { url.appending(path: name).resolvingSymlinksInPath() }
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    func makeEditor(embedded: [EmbeddedSubtitleTrack] = []) -> EditorState {
        let editor = EditorState(
            launchOptions: LaunchOptions(isUITestMode: true, showsStartScreen: true), playback: SimulatedPlaybackEngine(frameRate: .fps25),
            track: SubtitleTrack()
        )
        editor.analyzeWaveform = { _, _, _ in throw CancellationError() }
        editor.analyzeSpeech = { _, _, _ in [] }
        editor.analyzeShotChanges = { _, _ in [] }
        editor.listEmbeddedSubtitles = { _ in embedded }
        editor.readEmbeddedSubtitles = { _, _, _ in
            SubtitleTrack(languageCode: "en", cues: [Cue(start: MediaTime(seconds: 1), end: MediaTime(seconds: 2), text: "Embedded line")])
        }
        editor.aiProviders = .scripted(buildsBrief: true)
        editor.prepareAudio = { _, _, progress in
            progress(1)
            return PreparedAudio(source: .mix, audioStreamIndex: 0, duration: MediaTime(value: 10, timescale: 1), chunks: [])
        }
        editor.locateMissingMedia = { _ in nil }
        editor.reportError = { title, error in Issue.record("\(title) \(error)") }
        return editor
    }

    func settle(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func aNewWindowStartsOnTheStartScreenUnlessItOpensFiles() {
        #expect(makeEditor().startPhase == .chooseVideo)
        #expect(EditorState(launchOptions: LaunchOptions(isUITestMode: true), playback: SimulatedPlaybackEngine()).startPhase == nil, "UI tests skip it")
        let withProject = EditorState(
            launchOptions: LaunchOptions(projectURL: URL(fileURLWithPath: "/tmp/x.spotline"), showsStartScreen: true), playback: SimulatedPlaybackEngine()
        )
        #expect(withProject.startPhase == nil)
        // A project put in the window ends it.
        let editor = makeEditor()
        editor.loadProject(ProjectFile(), from: nil)
        #expect(editor.startPhase == nil)
    }

    @Test func findsTheSubtitleFilesBesideTheVideo() throws {
        let folder = try Folder(["Episode 1.mkv", "Episode 1.en.srt", "Episode 1.srt", "Episode 10.srt", "Episode 1.txt", "Other.srt"])
        let found = EditorState.subtitleFiles(beside: folder.file("Episode 1.mkv"))
        #expect(found.map(\.lastPathComponent) == ["Episode 1.srt", "Episode 1.en.srt"])
    }

    @Test func aVideoWithASubtitleBesideItRecommendsIt() async throws {
        let folder = try Folder(["Episode 1.mkv", "Episode 1.srt"])
        let editor = makeEditor()
        editor.dropOnStartScreen([folder.file("Episode 1.mkv")])
        await settle { editor.startPhase == .chooseSubtitle }
        #expect(editor.startPhase == .chooseSubtitle)
        #expect(editor.recommendedStartSubtitle == .file(folder.file("Episode 1.srt")))
        #expect(editor.startSubtitleChoices.map(\.subtitle) == [.file(folder.file("Episode 1.srt")), .transcribe])
    }

    @Test func aPlainTrackInsideTheVideoComesBeforeTheOthers() async throws {
        let tracks = [
            EmbeddedSubtitleTrack(streamIndex: 2, codec: "subrip", language: "en", isForced: true),
            EmbeddedSubtitleTrack(streamIndex: 3, codec: "subrip", language: "en", isHearingImpaired: true),
            EmbeddedSubtitleTrack(streamIndex: 4, codec: "subrip", language: "en"),
            EmbeddedSubtitleTrack(streamIndex: 5, codec: "hdmv_pgs_subtitle", language: "en", isText: false),
        ]
        let editor = makeEditor(embedded: tracks)
        editor.open(URL(fileURLWithPath: "/tmp/feature.mkv"))
        await settle { !editor.embeddedSubtitles.isEmpty }
        #expect(editor.recommendedStartSubtitle == .embedded(4))
        #expect(editor.startSubtitleChoices.map(\.subtitle) == [.embedded(2), .embedded(3), .embedded(4), .transcribe])
        #expect(!editor.isEmbeddedSubtitlesSheetShown, "The start screen asks itself")
    }

    @Test func aVideoWithNoneRecommendsNothingUntilAFileIsDropped() async throws {
        let folder = try Folder(["Episode 1.mkv", "Elsewhere.srt"])
        let editor = makeEditor()
        editor.dropOnStartScreen([folder.file("Episode 1.mkv")])
        await settle { editor.startPhase == .chooseSubtitle }
        #expect(editor.recommendedStartSubtitle == nil)
        #expect(editor.dropOnStartScreen([folder.file("Elsewhere.srt")]) == folder.file("Elsewhere.srt"))
        #expect(editor.recommendedStartSubtitle == .file(folder.file("Elsewhere.srt")))
        #expect(editor.startPhase == .chooseSubtitle)
    }

    @Test func justEditOpensTheEditorWithTheSubtitle() async throws {
        let folder = try Folder(["Episode 1.mkv", "Episode 1.srt"])
        let editor = makeEditor()
        editor.dropOnStartScreen([folder.file("Episode 1.mkv"), folder.file("Episode 1.srt")])
        await settle { editor.startPhase == .chooseSubtitle }
        editor.finishStart(with: editor.recommendedStartSubtitle, translatingTo: nil)
        #expect(editor.startPhase == nil)
        #expect(editor.page == .edit)
        #expect(editor.track.cues.map(\.text) == ["Hello there.", "How are you?"])
        #expect(editor.aiFlow == nil, "Nothing runs")
    }

    @Test func translateShowsTheTranslatePageAndStartsAtOnce() async throws {
        let folder = try Folder(["Episode 1.mkv", "Episode 1.srt"])
        let editor = makeEditor()
        editor.dropOnStartScreen([folder.file("Episode 1.mkv")])
        await settle { editor.startPhase == .chooseSubtitle }
        editor.finishStart(with: editor.recommendedStartSubtitle, translatingTo: "fr")
        #expect(editor.startPhase == nil)
        #expect(editor.page == .translate)
        #expect(editor.aiFlow?.current == .listen, "It starts by listening to the audio")
        #expect(editor.track.cues.count == 2)
    }

    @Test func anEmbeddedTrackIsReadFirst() async throws {
        let editor = makeEditor(embedded: [EmbeddedSubtitleTrack(streamIndex: 4, codec: "subrip", language: "en")])
        editor.open(URL(fileURLWithPath: "/tmp/feature.mkv"))
        await settle { editor.recommendedStartSubtitle != nil }
        editor.finishStart(with: .embedded(4), translatingTo: nil)
        await settle { editor.startPhase == nil }
        #expect(editor.track.cues.map(\.text) == ["Embedded line"])
        #expect(editor.page == .edit)
    }

    @Test func aSubtitleDroppedAloneOpensTheEditorAndAProjectItsOwnWindow() throws {
        let folder = try Folder(["Episode 1.srt"])
        let editor = makeEditor()
        editor.dropOnStartScreen([folder.file("Episode 1.srt")])
        #expect(editor.startPhase == nil)
        #expect(editor.page == .edit)
        #expect(editor.track.cues.count == 2)

        let other = makeEditor()
        var opened: [URL] = []
        other.openProjectFromStart = { opened.append($0) }
        other.dropOnStartScreen([URL(fileURLWithPath: "/tmp/Episode 1.spotline")])
        #expect(opened == [URL(fileURLWithPath: "/tmp/Episode 1.spotline")])
    }

    @Test func listeningSaysWhatItFound() async {
        let tests = AIStateTests()
        let editor = tests.makeEditor(cues: [tests.cue("Hello there. How are you?", at: 0), tests.cue("Fine, thanks.", at: 3)])
        editor.aiProviders = .scripted(buildsBrief: false)
        #expect(editor.listeningSummary == nil)
        editor.perform(.transcribe)
        await tests.finish(editor)
        #expect(editor.listeningSummary?.hasPrefix("Heard 2 of 2 cues in the audio") == true)
    }
}

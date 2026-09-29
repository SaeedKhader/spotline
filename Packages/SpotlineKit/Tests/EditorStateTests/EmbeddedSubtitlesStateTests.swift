import EditorCommands
import Foundation
import MediaAnalysis
import PlaybackCore
import SubtitleCore
import SubtitleFormats
import Testing
@testable import EditorUI

@MainActor
struct EmbeddedSubtitlesStateTests {
    let rate = FrameRate.fps23_976
    let media = URL(fileURLWithPath: "/tmp/feature.mkv")
    nonisolated static let tracks = [
        EmbeddedSubtitleTrack(streamIndex: 2, codec: "subrip", language: "eng", title: "English"),
        EmbeddedSubtitleTrack(streamIndex: 3, codec: "hdmv_pgs_subtitle", language: "eng", isText: false),
    ]
    nonisolated static let imported = SubtitleTrack(
        languageCode: "en",
        cues: [Cue(start: MediaTime(value: 1, timescale: 1), end: MediaTime(value: 2, timescale: 1), text: "Embedded")]
    )

    func makeEditor(tracks: [EmbeddedSubtitleTrack] = tracks, settings: UserDefaults? = nil) -> EditorState {
        let editor = EditorState(
            launchOptions: LaunchOptions(isUITestMode: true), playback: SimulatedPlaybackEngine(frameRate: rate),
            track: SubtitleTrack(cues: [Cue(start: .zero, end: MediaTime(value: 1, timescale: 2), text: "Mine")]),
            settings: settings
        )
        editor.analyzeWaveform = { _, _, _ in throw CancellationError() }
        editor.analyzeSpeech = { _, _, _ in [] }
        editor.analyzeShotChanges = { _, _ in [] }
        editor.listEmbeddedSubtitles = { _ in tracks }
        editor.readEmbeddedSubtitles = { _, _, _ in Self.imported }
        editor.reportError = { title, error in Issue.record("\(title) \(error)") }
        return editor
    }

    func settle(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { await Task.yield() }
    }

    @Test func offersTheTracksWhenMediaOpens() async {
        let editor = makeEditor()
        #expect(!editor.canPerform(.importEmbeddedSubtitles))
        editor.open(media)
        await settle { editor.isEmbeddedSubtitlesSheetShown }
        #expect(editor.isEmbeddedSubtitlesSheetShown)
        #expect(editor.embeddedSubtitles == [Self.tracks[0]], "Image-based tracks are left out")
        #expect(editor.canPerform(.importEmbeddedSubtitles))
    }

    @Test func mediaWithoutSubtitlesOffersNothing() async {
        let editor = makeEditor(tracks: [])
        editor.open(media)
        for _ in 0..<50 { await Task.yield() }
        #expect(!editor.isEmbeddedSubtitlesSheetShown)
        #expect(!editor.canPerform(.importEmbeddedSubtitles))
    }

    @Test func offersOncePerFileThenOnlyFromTheMenu() async throws {
        let suite = "EmbeddedSubtitlesStateTests-\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        let first = makeEditor(settings: settings)
        first.open(media)
        await settle { first.isEmbeddedSubtitlesSheetShown }
        #expect(first.isEmbeddedSubtitlesSheetShown)

        let second = makeEditor(settings: settings)
        second.open(media)
        await settle { !second.embeddedSubtitles.isEmpty }
        for _ in 0..<20 { await Task.yield() }
        #expect(!second.isEmbeddedSubtitlesSheetShown)
        #expect(second.perform(.importEmbeddedSubtitles))
        #expect(second.isEmbeddedSubtitlesSheetShown)
    }

    @Test func importReplacesTheCuesUndoably() async {
        let editor = makeEditor()
        editor.open(media)
        await settle { editor.isEmbeddedSubtitlesSheetShown }
        editor.importEmbeddedSubtitles(streamIndex: 2, savesCopy: false)
        #expect(editor.embeddedSubtitlesJob != nil)
        await settle { editor.embeddedSubtitlesJob == nil }
        #expect(editor.track.cues.map(\.text) == ["Embedded"])
        #expect(editor.track.languageCode == "en")
        #expect(!editor.isEmbeddedSubtitlesSheetShown)
        #expect(editor.hasUnsavedChanges)
        #expect(editor.subtitleFile == nil)
        editor.perform(.undo)
        #expect(editor.track.cues.map(\.text) == ["Mine"])
    }

    @Test func mediaWithOnlyImageTracksOffersNothing() async {
        let editor = makeEditor(tracks: [Self.tracks[1]])
        editor.open(media)
        for _ in 0..<50 { await Task.yield() }
        #expect(!editor.isEmbeddedSubtitlesSheetShown)
        #expect(!editor.canPerform(.importEmbeddedSubtitles))
    }

    @Test func imageTracksCannotBeImported() async {
        let editor = makeEditor()
        editor.open(media)
        await settle { editor.isEmbeddedSubtitlesSheetShown }
        editor.importEmbeddedSubtitles(streamIndex: 3, savesCopy: false)
        #expect(editor.embeddedSubtitlesJob == nil)
        #expect(editor.track.cues.map(\.text) == ["Mine"])
    }

    @Test func savingACopySuggestsAFileNextToTheMedia() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "EmbeddedSubtitles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let editor = makeEditor()
        let media = directory.appending(path: "feature.mkv")
        var suggested: SubtitleFileReference?
        editor.chooseExportDestination = { suggestion in
            suggested = suggestion
            return suggestion
        }
        editor.open(media)
        await settle { editor.isEmbeddedSubtitlesSheetShown }
        editor.importEmbeddedSubtitles(streamIndex: 2, savesCopy: true)
        await settle { editor.embeddedSubtitlesJob == nil }
        #expect(suggested == SubtitleFileReference(url: directory.appending(path: "feature.en.srt"), format: .srt))
        #expect(editor.subtitleFile == suggested)
        #expect(!editor.hasUnsavedChanges)
        let written = try String(contentsOf: directory.appending(path: "feature.en.srt"), encoding: .utf8)
        #expect(written.contains("Embedded"))
    }

    @Test func cancellingStopsTheImport() async {
        let editor = makeEditor()
        let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
        editor.readEmbeddedSubtitles = { _, _, _ in
            startedContinuation.yield()
            try await Task.sleep(for: .seconds(30))
            return Self.imported
        }
        editor.open(media)
        await settle { editor.isEmbeddedSubtitlesSheetShown }
        editor.importEmbeddedSubtitles(streamIndex: 2, savesCopy: false)
        for await _ in started { break }
        editor.dismissEmbeddedSubtitles()
        #expect(editor.embeddedSubtitlesJob == nil)
        #expect(!editor.isEmbeddedSubtitlesSheetShown)
        for _ in 0..<50 { await Task.yield() }
        #expect(editor.track.cues.map(\.text) == ["Mine"])
    }

    @Test func failuresAreReported() async {
        let editor = makeEditor()
        var reported: String?
        editor.reportError = { title, _ in reported = title }
        editor.readEmbeddedSubtitles = { _, _, _ in throw MediaAnalyzer.Error.cannotOpen("broken") }
        editor.open(media)
        await settle { editor.isEmbeddedSubtitlesSheetShown }
        editor.importEmbeddedSubtitles(streamIndex: 2, savesCopy: false)
        await settle { reported != nil }
        #expect(reported == "“English” could not be imported.")
        #expect(editor.isEmbeddedSubtitlesSheetShown, "The sheet stays open to pick another track")
    }
}

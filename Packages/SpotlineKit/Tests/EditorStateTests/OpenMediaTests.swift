import EditorCommands
import Foundation
import MediaAnalysis
import PlaybackCore
import SubtitleCore
import SubtitleFormats
import Testing
@testable import EditorUI

/// Opening new media over open media starts over.
@MainActor
struct OpenMediaTests {
    let rate = FrameRate.fps23_976
    let first = URL(fileURLWithPath: "/tmp/first.mkv")
    let second = URL(fileURLWithPath: "/tmp/second.mkv")
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "OpenMediaTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func makeEditor() -> EditorState {
        let editor = EditorState(launchOptions: LaunchOptions(), playback: SimulatedPlaybackEngine(frameRate: rate))
        editor.analyzeWaveform = { _, _, _ in AudioAnalysis(waveform: Waveform(peaks: [1, 2]), audioStreamIndex: 1) }
        editor.analyzeSpeech = { _, _, _ in [] }
        editor.analyzeShotChanges = { _, _ in [MediaTime(value: 1, timescale: 1)] }
        editor.listEmbeddedSubtitles = { _ in [EmbeddedSubtitleTrack(streamIndex: 2, codec: "subrip")] }
        editor.reportError = { title, error in Issue.record("\(title) \(error)") }
        editor.confirmReplacingSubtitles = {
            Issue.record("Asked to export")
            return .cancel
        }
        return editor
    }

    func write(_ text: String, _ name: String) throws -> URL {
        let url = directory.appending(path: name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func settle(_ editor: EditorState) async {
        for _ in 0..<200 where editor.waveformJob != nil || editor.shotChangesJob != nil || editor.speechJob != nil
            || editor.embeddedSubtitles.isEmpty {
            await Task.yield()
        }
    }

    static let srt = "1\n00:00:01,000 --> 00:00:02,000\nOne\n\n2\n00:00:03,000 --> 00:00:04,000\nTwo\n"

    @Test func subtitlesImportedBeforeAnyMediaAreKept() throws {
        let editor = makeEditor()
        editor.importSubtitles(from: try write(Self.srt, "early.srt"))
        editor.open(first)
        #expect(editor.track.cues.map(\.text) == ["One", "Two"])
        #expect(editor.subtitleFile != nil)
    }

    @Test func newMediaStartsOver() async throws {
        let editor = makeEditor()
        editor.open(first)
        await settle(editor)
        editor.importSubtitles(from: try write(Self.srt, "first.srt"))
        editor.openSourceSubtitles(from: try write(Self.srt, "first.en.srt"))
        editor.select(editor.track.cues[1].id)
        editor.perform(.toggleMilliseconds)
        #expect(editor.isTranslating)
        #expect(editor.canUndo)
        #expect(editor.audioAnalysis != nil && editor.shotChanges != nil)
        #expect(editor.isEmbeddedSubtitlesSheetShown)
        editor.dismissEmbeddedSubtitles()

        editor.confirmReplacingSubtitles = { .discard }
        editor.open(second)
        #expect(editor.status.mediaURL == second)
        #expect(editor.track.cues.isEmpty)
        #expect(editor.selectedCueID == nil)
        #expect(editor.subtitleFile == nil)
        #expect(!editor.isTranslating)
        #expect(editor.sourceFile == nil)
        #expect(!editor.canUndo && !editor.canRedo)
        #expect(!editor.hasUnsavedChanges)
        #expect(editor.issues.isEmpty)
        #expect(editor.currentFrame == 0)
        #expect(editor.showsMilliseconds, "View preferences stay")
        await settle(editor)
        #expect(editor.isEmbeddedSubtitlesSheetShown, "The new media's tracks are offered")
    }

    @Test func analysisOfTheOldMediaIsClearedAtOnce() async {
        let editor = makeEditor()
        editor.open(first)
        await settle(editor)
        let (never, _) = AsyncStream.makeStream(of: Void.self)
        editor.analyzeWaveform = { _, _, _ in
            for await _ in never {}
            throw CancellationError()
        }
        editor.analyzeShotChanges = { _, _ in
            for await _ in never {}
            throw CancellationError()
        }
        editor.open(second)
        #expect(editor.audioAnalysis == nil)
        #expect(editor.shotChanges == nil)
        #expect(editor.embeddedSubtitles.isEmpty)
    }

    @Test func unsavedChangesCanBeExportedFirst() async throws {
        let editor = makeEditor()
        editor.open(first)
        editor.perform(.addCue)
        var asked = 0
        editor.confirmReplacingSubtitles = {
            asked += 1
            return .export
        }
        let destination = SubtitleFileReference(url: directory.appending(path: "saved.srt"), format: .srt)
        editor.chooseExportDestination = { _ in destination }
        editor.open(second)
        #expect(asked == 1)
        #expect(FileManager.default.fileExists(atPath: destination.url.path))
        #expect(editor.status.mediaURL == second)
        #expect(editor.track.cues.isEmpty)
    }

    @Test func cancellingKeepsTheMediaAndTheSubtitles() {
        let editor = makeEditor()
        editor.open(first)
        editor.perform(.addCue)
        editor.confirmReplacingSubtitles = { .cancel }
        editor.open(second)
        #expect(editor.status.mediaURL == first)
        #expect(editor.track.cues.count == 1)
        #expect(editor.canUndo)
    }

    @Test func cancellingTheExportPanelCancelsTheOpen() {
        let editor = makeEditor()
        editor.open(first)
        editor.perform(.addCue)
        editor.confirmReplacingSubtitles = { .export }
        editor.chooseExportDestination = { _ in nil }
        editor.open(second)
        #expect(editor.status.mediaURL == first)
        #expect(editor.track.cues.count == 1)
    }

    @Test func discardingOpensWithoutExporting() {
        let editor = makeEditor()
        editor.open(first)
        editor.perform(.addCue)
        editor.confirmReplacingSubtitles = { .discard }
        editor.chooseExportDestination = { _ in
            Issue.record("Asked where to export")
            return nil
        }
        editor.open(second)
        #expect(editor.status.mediaURL == second)
        #expect(editor.track.cues.isEmpty)
    }

    @Test func savedSubtitlesAreClearedWithoutAsking() throws {
        let editor = makeEditor()
        editor.open(first)
        editor.importSubtitles(from: try write(Self.srt, "saved.srt"))
        editor.open(second)
        #expect(editor.track.cues.isEmpty)
    }
}

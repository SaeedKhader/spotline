import EditorCommands
import Foundation
import MediaAnalysis
import PlaybackCore
import SubtitleCore
import SubtitleFormats
import Testing
@testable import EditorUI

@MainActor
struct TimelineStateTests {
    let rate = FrameRate.fps25
    func f(_ n: Int64) -> MediaTime { MediaTime(frame: n, rate: rate) }

    /// An editor whose media "analysis" finds cuts at frames 40 and 75.
    func makeEditor() async throws -> EditorState {
        let editor = EditorState(launchOptions: LaunchOptions(isUITestMode: true), playback: SimulatedPlaybackEngine(frameRate: rate))
        let cuts = [f(40), f(75)]
        let halfway = f(50)
        editor.analyzeMedia = { _, _, progress in
            progress(MediaAnalyzer.Progress(fraction: 0.5, analyzedUntil: halfway, partial: nil))
            return MediaAnalysis(waveform: Waveform(peaks: [10, 20]), shotChanges: cuts)
        }
        editor.open(URL(fileURLWithPath: "/tmp/cuts.mov"))
        #expect(editor.analysisProgress == 0)
        for _ in 0..<100 where editor.analysis == nil { await Task.yield() }
        try #require(editor.analysis != nil)
        return editor
    }

    @Test func analysisRunsWhenMediaOpens() async throws {
        let editor = try await makeEditor()
        #expect(editor.shotChangeFrames == [40, 75])
        #expect(editor.analysisProgress == nil)
        #expect(editor.timelineContent.shotChanges == [40, 75])
        #expect(editor.timelineContent.waveform?.peaks == [10, 20])
    }

    @Test func partialResultsShowBeforeTheEnd() async throws {
        let editor = EditorState(launchOptions: LaunchOptions(isUITestMode: true), playback: SimulatedPlaybackEngine(frameRate: rate))
        let (reports, continuation) = AsyncStream<MediaAnalyzer.Progress>.makeStream()
        let finish = AsyncStream<Void>.makeStream()
        let first = MediaAnalysis(waveform: Waveform(peaks: [1]), shotChanges: [f(40)])
        let final = MediaAnalysis(waveform: Waveform(peaks: [1, 2, 3]), shotChanges: [f(40), f(75)])
        editor.analyzeMedia = { _, _, progress in
            for await report in reports { progress(report) }
            for await _ in finish.stream { break }
            return final
        }
        editor.open(URL(fileURLWithPath: "/tmp/cuts.mov"))

        continuation.yield(MediaAnalyzer.Progress(fraction: 0.5, analyzedUntil: f(50), partial: first))
        // A stale report arriving late is ignored.
        continuation.yield(MediaAnalyzer.Progress(fraction: 0.2, analyzedUntil: f(20), partial: MediaAnalysis(waveform: nil, shotChanges: [])))
        continuation.finish()
        for _ in 0..<100 where editor.analysisProgress != 0.5 { await Task.yield() }
        for _ in 0..<20 { await Task.yield() }
        #expect(editor.analysis == first)
        #expect(editor.analyzedUntil == f(50))
        #expect(editor.shotChangeFrames == [40])
        #expect(editor.canPerform(.nextShotChange), "Partial cuts are usable")

        finish.continuation.yield()
        for _ in 0..<100 where editor.analysisProgress != nil { await Task.yield() }
        #expect(editor.analysis == final)
        #expect(editor.analyzedUntil == nil)
        #expect(editor.timelineContent.analyzedUntil == nil)
    }

    @Test func switchingAudioTracksAnalyzesThatTrack() async throws {
        let engine = SimulatedPlaybackEngine(frameRate: rate)
        let editor = EditorState(launchOptions: LaunchOptions(isUITestMode: true), playback: engine)
        let requests = Requests()
        editor.analyzeMedia = { _, stream, _ in
            await requests.append(stream)
            return MediaAnalysis(waveform: Waveform(peaks: [1]), shotChanges: [], audioStreamIndex: stream ?? 1)
        }
        editor.open(URL(fileURLWithPath: "/tmp/tracks.mkv"))
        for _ in 0..<100 where editor.analysis == nil { await Task.yield() }
        #expect(editor.analysis?.audioStreamIndex == 1)

        // The player reports the track the analysis already used: nothing to redo.
        engine.selectAudioStream(1)
        for _ in 0..<50 { await Task.yield() }
        #expect(await requests.all == [nil])

        engine.selectAudioStream(2)
        for _ in 0..<100 where editor.analysis?.audioStreamIndex != 2 { await Task.yield() }
        #expect(editor.analysis?.audioStreamIndex == 2)
        #expect(await requests.all == [nil, 2])
    }

    @Test func shotChangeNavigation() async throws {
        let editor = try await makeEditor()
        #expect(!editor.canPerform(.previousShotChange))
        #expect(editor.perform(.nextShotChange))
        #expect(editor.currentFrame == 40)
        editor.perform(.nextShotChange)
        #expect(editor.currentFrame == 75)
        #expect(!editor.canPerform(.nextShotChange))
        editor.perform(.previousShotChange)
        #expect(editor.currentFrame == 40)
    }

    @Test func zoomIsClamped() async throws {
        let editor = try await makeEditor()
        let start = editor.timelineScale
        editor.perform(.zoomIn)
        #expect(editor.timelineScale == start * 1.5)
        editor.perform(.zoomOut)
        #expect(editor.timelineScale == start)
        editor.setTimelineScale(1_000_000)
        #expect(editor.timelineScale == EditorState.timelineScaleRange.upperBound)
        #expect(!editor.canPerform(.zoomIn))
    }

    @Test func snapTargetsFollowTheToggle() async throws {
        let editor = try await makeEditor()
        let cue = Cue(start: f(10), end: f(20), text: "a")
        let other = Cue(start: f(50), end: f(60), text: "b")
        let track = SubtitleTrack(cues: [cue, other])
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).srt")
        try SubtitleFormatWriter.write(track.cues, to: url)
        editor.importSubtitles(from: url)
        editor.seek(toFrame: 5)

        let targets = Set(editor.snapTargets(excluding: editor.track.cues[0].id))
        #expect(targets == [f(40), f(75), f(5), f(50), f(60)])
        #expect(editor.isOn(.toggleSnapping) == true)
        editor.perform(.toggleSnapping)
        #expect(editor.isOn(.toggleSnapping) == false)
        #expect(editor.snapTargets(excluding: nil).isEmpty)
        #expect(editor.isOn(.zoomIn) == nil)
    }

    @Test func setTimingIsOneUndoStep() async throws {
        let editor = try await makeEditor()
        editor.perform(.addCue)
        let id = try #require(editor.selectedCueID)
        let original = try #require(editor.selectedCue)
        editor.setTiming(start: f(40), end: f(60), forCue: id, actionName: "Move Cue")
        #expect(editor.selectedCue?.start == f(40))
        #expect(editor.undoManager.undoActionName == "Move Cue")
        editor.perform(.undo)
        #expect(editor.selectedCue?.start == original.start)
        // Invalid timing is ignored.
        editor.setTiming(start: f(60), end: f(40), forCue: id, actionName: "Move Cue")
        #expect(editor.selectedCue?.start == original.start)
    }
}

/// Writes SRT for tests without going through a save panel.
enum SubtitleFormatWriter {
    static func write(_ cues: [Cue], to url: URL) throws {
        try Data(SubtitleFormats.SubtitleFormat.srt.serialize(cues).utf8).write(to: url)
    }
}

private actor Requests {
    private(set) var all: [Int?] = []
    func append(_ stream: Int?) { all.append(stream) }
}

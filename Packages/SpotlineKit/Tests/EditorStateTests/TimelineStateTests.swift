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

    typealias WaveformProgress = MediaAnalyzer.Progress<AudioAnalysis>
    typealias ShotProgress = MediaAnalyzer.Progress<[MediaTime]>

    /// An editor whose media "analysis" finds cuts at frames 40 and 75.
    func makeEditor() async throws -> EditorState {
        let editor = EditorState(launchOptions: LaunchOptions(isUITestMode: true), playback: SimulatedPlaybackEngine(frameRate: rate))
        editor.analyzeSpeech = { _, _, _ in [] }
        let cuts = [f(40), f(75)]
        let halfway = f(50)
        editor.analyzeWaveform = { _, _, _ in
            AudioAnalysis(waveform: Waveform(peaks: [10, 20]), audioStreamIndex: 1)
        }
        editor.analyzeShotChanges = { _, progress in
            progress(ShotProgress(fraction: 0.5, analyzedUntil: halfway, partial: nil))
            return cuts
        }
        editor.analyzeSpeech = { _, _, _ in [] }
        editor.open(URL(fileURLWithPath: "/tmp/cuts.mov"))
        #expect(editor.waveformJob == AnalysisJob())
        #expect(editor.shotChangesJob == AnalysisJob())
        #expect(editor.speechJob == AnalysisJob())
        for _ in 0..<100 where editor.waveformJob != nil || editor.shotChangesJob != nil || editor.speechJob != nil {
            await Task.yield()
        }
        try #require(editor.shotChanges != nil && editor.audioAnalysis != nil)
        return editor
    }

    @Test func analysisRunsWhenMediaOpens() async throws {
        let editor = try await makeEditor()
        #expect(editor.shotChangeFrames == [40, 75])
        #expect(editor.analyzedUntil == nil)
        #expect(editor.timelineContent.shotChanges == [40, 75])
        #expect(editor.timelineContent.waveform?.peaks == [10, 20])
        #expect(editor.analysis?.audioStreamIndex == 1)
    }

    @Test func theWaveformDoesNotWaitForShotChanges() async throws {
        let editor = EditorState(launchOptions: LaunchOptions(isUITestMode: true), playback: SimulatedPlaybackEngine(frameRate: rate))
        editor.analyzeSpeech = { _, _, _ in [] }
        let finishShots = AsyncStream<Void>.makeStream()
        editor.analyzeWaveform = { _, _, _ in AudioAnalysis(waveform: Waveform(peaks: [1, 2]), audioStreamIndex: 1) }
        editor.analyzeShotChanges = { _, _ in
            for await _ in finishShots.stream { break }
            return []
        }
        editor.open(URL(fileURLWithPath: "/tmp/cuts.mov"))
        for _ in 0..<100 where editor.waveformJob != nil { await Task.yield() }
        #expect(editor.audioAnalysis?.waveform.peaks == [1, 2])
        #expect(editor.shotChangesJob != nil, "Shot changes are still running")
        #expect(editor.analyzedUntil == .zero)

        finishShots.continuation.yield()
        for _ in 0..<100 where editor.shotChangesJob != nil { await Task.yield() }
        #expect(editor.shotChanges == [])
    }

    @Test func partialShotChangesShowBeforeTheEnd() async throws {
        let editor = EditorState(launchOptions: LaunchOptions(isUITestMode: true), playback: SimulatedPlaybackEngine(frameRate: rate))
        editor.analyzeSpeech = { _, _, _ in [] }
        let (reports, continuation) = AsyncStream<ShotProgress>.makeStream()
        let finish = AsyncStream<Void>.makeStream()
        let final = [f(40), f(75)]
        editor.analyzeWaveform = { _, _, _ in AudioAnalysis(waveform: Waveform(peaks: [1]), audioStreamIndex: 1) }
        editor.analyzeShotChanges = { _, progress in
            for await report in reports { progress(report) }
            for await _ in finish.stream { break }
            return final
        }
        editor.open(URL(fileURLWithPath: "/tmp/cuts.mov"))

        continuation.yield(ShotProgress(fraction: 0.5, analyzedUntil: f(50), partial: [f(40)]))
        // A stale report arriving late is ignored.
        continuation.yield(ShotProgress(fraction: 0.2, analyzedUntil: f(20), partial: []))
        continuation.finish()
        for _ in 0..<100 where editor.shotChangesJob?.fraction != 0.5 { await Task.yield() }
        for _ in 0..<100 where editor.waveformJob != nil { await Task.yield() }
        for _ in 0..<20 { await Task.yield() }
        #expect(editor.shotChanges == [f(40)])
        #expect(editor.analyzedUntil == f(50))
        #expect(editor.canPerform(.nextShotChange), "Partial cuts are usable")

        finish.continuation.yield()
        for _ in 0..<100 where editor.shotChangesJob != nil { await Task.yield() }
        #expect(editor.shotChanges == final)
        #expect(editor.analyzedUntil == nil)
        #expect(editor.timelineContent.analyzedUntil == nil)
    }

    @Test func switchingAudioTracksRedoesOnlyTheWaveform() async throws {
        let engine = SimulatedPlaybackEngine(frameRate: rate)
        let editor = EditorState(launchOptions: LaunchOptions(isUITestMode: true), playback: engine)
        editor.analyzeSpeech = { _, _, _ in [] }
        let requests = Requests()
        editor.analyzeWaveform = { _, stream, _ in
            await requests.append(stream)
            return AudioAnalysis(waveform: Waveform(peaks: [1]), audioStreamIndex: stream ?? 1)
        }
        editor.analyzeShotChanges = { _, _ in
            await requests.append(-1)
            return []
        }
        editor.open(URL(fileURLWithPath: "/tmp/tracks.mkv"))
        for _ in 0..<100 where editor.waveformJob != nil || editor.shotChangesJob != nil { await Task.yield() }
        #expect(editor.audioAnalysis?.audioStreamIndex == 1)

        // The player reports the track the waveform already used: nothing to redo.
        engine.selectAudioStream(1)
        for _ in 0..<50 { await Task.yield() }
        #expect(await Set(requests.all) == [nil, -1])

        engine.selectAudioStream(2)
        for _ in 0..<100 where editor.audioAnalysis?.audioStreamIndex != 2 { await Task.yield() }
        #expect(editor.audioAnalysis?.audioStreamIndex == 2)
        let all = await requests.all
        #expect(all.count == 3 && all.last == 2, "Only the waveform ran again: \(all)")
    }

    @Test func audioTrackCommandsCycleAndRedoTheWaveform() async throws {
        let tracks = [
            AudioTrack(id: 1, streamIndex: 1, language: "eng", title: "Original", channelCount: 2),
            AudioTrack(id: 2, streamIndex: 2, language: "ara", title: "Arabic dub", channelCount: 6),
        ]
        let editor = EditorState(
            launchOptions: LaunchOptions(isUITestMode: true),
            playback: SimulatedPlaybackEngine(frameRate: rate, audioTracks: tracks)
        )
        editor.analyzeSpeech = { _, _, _ in [] }
        editor.analyzeWaveform = { _, stream, _ in AudioAnalysis(waveform: Waveform(peaks: [1]), audioStreamIndex: stream ?? 1) }
        editor.analyzeShotChanges = { _, _ in [] }
        #expect(!editor.canPerform(.nextAudioTrack))
        editor.open(URL(fileURLWithPath: "/tmp/tracks.mkv"))
        #expect(editor.selectedAudioTrack?.title == "Original")

        #expect(editor.perform(.nextAudioTrack))
        #expect(editor.selectedAudioTrack?.title == "Arabic dub")
        for _ in 0..<100 where editor.audioAnalysis?.audioStreamIndex != 2 { await Task.yield() }
        #expect(editor.audioAnalysis?.audioStreamIndex == 2)

        editor.perform(.nextAudioTrack)
        #expect(editor.selectedAudioTrack?.id == 1, "Wraps around")
        editor.selectAudioTrack(id: 99)
        #expect(editor.selectedAudioTrack?.id == 1, "Unknown tracks are ignored")
    }

    @Test func speechIsDetectedPerTrackAndCanBeHidden() async throws {
        let tracks = [AudioTrack(id: 1, streamIndex: 1), AudioTrack(id: 2, streamIndex: 2)]
        let editor = EditorState(
            launchOptions: LaunchOptions(isUITestMode: true),
            playback: SimulatedPlaybackEngine(frameRate: rate, audioTracks: tracks)
        )
        editor.analyzeSpeech = { _, _, _ in [] }
        let region = SpeechRegion(start: f(10), end: f(30), confidence: 0.9)
        editor.analyzeWaveform = { _, stream, _ in AudioAnalysis(waveform: Waveform(peaks: [1]), audioStreamIndex: stream ?? 1) }
        editor.analyzeShotChanges = { _, _ in [] }
        editor.analyzeSpeech = { _, stream, _ in stream == 2 ? [] : [region] }
        editor.open(URL(fileURLWithPath: "/tmp/tracks.mkv"))
        for _ in 0..<100 where editor.speechJob != nil || editor.speech == nil { await Task.yield() }
        #expect(editor.speech == [region])
        #expect(editor.timelineContent.speech == [region])

        editor.perform(.toggleSpeechHighlight)
        #expect(editor.isOn(.toggleSpeechHighlight) == false)
        #expect(editor.timelineContent.speech == nil)
        editor.perform(.toggleSpeechHighlight)

        editor.perform(.nextAudioTrack)
        for _ in 0..<100 where editor.speech != [] { await Task.yield() }
        #expect(editor.speech == [], "Detected again for the new track")
    }

    @Test func trackNames() {
        #expect(AudioTrack(id: 3).displayName == "Track 3")
        #expect(AudioTrack(id: 1, language: "xx-private", title: "Commentary", channelCount: 2).displayName.hasSuffix("Commentary · Stereo"))
        #expect(AudioTrack(id: 1, channelCount: 8).displayName == "7.1")
    }

    @Test func shotChangeNavigation() async throws {
        let editor = try await makeEditor()
        #expect(!editor.perform(.previousShotChange))
        #expect(editor.perform(.nextShotChange))
        #expect(editor.currentFrame == 40)
        editor.perform(.nextShotChange)
        #expect(editor.currentFrame == 75)
        #expect(!editor.perform(.nextShotChange))
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
        // Neighbouring cues are targets at the two-frame minimum gap.
        #expect(targets == [f(40), f(75), f(5), f(48), f(62)])
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

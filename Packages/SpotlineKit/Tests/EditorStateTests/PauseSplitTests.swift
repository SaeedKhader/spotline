import AITools
import EditorCommands
import Foundation
import PlaybackCore
import QualityControl
import SubtitleCore
import Testing
@testable import EditorUI

/// Splitting a cue where the speaker pauses, from the transcript's word times.
@MainActor
struct PauseSplitTests {
    let rate = FrameRate.fps25
    func f(_ n: Int64) -> MediaTime { MediaTime(frame: n, rate: rate) }

    /// Words at 0.25 s each from `start`, with a pause of `pause` frames after word `pauseAfter`.
    func words(_ text: String, from start: Int64, pauseAfter: Int, pause: Int64) -> [TranscribedWord] {
        var frame = start
        return text.split(separator: " ").enumerated().map { index, word in
            defer { frame += 6 + (index == pauseAfter ? pause : 0) }
            return TranscribedWord(text: String(word), start: f(frame), end: f(frame + 5))
        }
    }

    @Test func theLongestPauseAtASentenceEndWins() {
        let text = "I told you already. We leave at dawn, and nobody stays behind this time."
        let cue = Cue(start: f(0), end: f(120), text: text)
        let transcript = words(text, from: 0, pauseAfter: 3, pause: 12)
        let splits = PauseSplitter.splits(of: cue, words: transcript, rate: rate, shotChanges: [], gapFrames: 2)
        #expect(splits.first?.after == "already.")
        #expect(splits.first?.first == "I told you already.")
        #expect(splits.first?.secondStart == f(36), "The next word's start")
        #expect(splits.first?.firstEnd == f(34), "Up through the pause, two frames before")
    }

    @Test func withoutWordTimesOnlyPunctuationSplits() {
        let cue = Cue(start: f(0), end: f(100), text: "No times here, only commas and stops")
        let splits = PauseSplitter.splits(of: cue, words: [], rate: rate, shotChanges: [], gapFrames: 2)
        #expect(splits.map(\.after) == ["here,"])
        #expect(splits.first?.pause == nil)
    }

    @Test func aCueTooLongIsOfferedTheSplitAtThePause() {
        let text = "I told you already. We leave at dawn, and nobody stays behind this time."
        let editor = EditorState(
            launchOptions: LaunchOptions(isUITestMode: true), playback: SimulatedPlaybackEngine(frameRate: rate),
            frameRate: rate, track: SubtitleTrack(cues: [Cue(start: f(0), end: f(200), text: text)])
        )
        editor.storedTranscripts = [StoredTranscript(provider: "scripted", audioStream: nil, language: "en", words: words(text, from: 0, pauseAfter: 3, pause: 60))]
        let cue = editor.track.cues[0]
        #expect(editor.issues[cue.id]?.contains { if case .tooLong = $0.kind { true } else { false } } == true)
        let split = editor.suggestions(forCue: cue.id).first { $0.group == .cue && $0.title.hasPrefix("Split at the Pause") }
        #expect(split?.title == "Split at the Pause After “already.” (2.44 s)")
        let item = ReviewItem(cueID: cue.id, kind: .issues, start: cue.start)
        editor.select(cue.id)
        editor.decide(item, .suggestion(editor.reviewSuggestions(for: item).firstIndex { $0.title == split?.title }!))
        #expect(editor.track.cues.map(\.text) == ["I told you already.", "We leave at dawn, and nobody\nstays behind this time."])
        #expect(editor.track.cues[1].start == f(84))
        #expect(editor.issues.isEmpty)
    }

    @Test func splitCueCutsAtTheWordGapNearestThePlayhead() {
        let text = "I told you already. We leave at dawn, and nobody stays behind this time."
        let editor = EditorState(
            launchOptions: LaunchOptions(isUITestMode: true), playback: SimulatedPlaybackEngine(frameRate: rate),
            frameRate: rate, track: SubtitleTrack(cues: [Cue(start: f(0), end: f(120), text: text)])
        )
        // Word n runs from 6n to 6n + 5 frames: "dawn," (word 7) ends at frame 47.
        editor.storedTranscripts = [StoredTranscript(provider: "scripted", audioStream: nil, language: "en", words: words(text, from: 0, pauseAfter: -1, pause: 0))]
        let cue = editor.track.cues[0]
        // Frame 46, inside "dawn,": the cut moves to the gap after it.
        #expect(editor.splitCue(cue.id, at: f(46)))
        #expect(editor.track.cues.map(\.text) == ["I told you already. We leave at dawn,", "and nobody stays behind this time."])
        #expect(editor.track.cues[1].start == f(48), "The next word's start")
        #expect(editor.track.cues[0].end == f(46))
        // Without a playhead in the cue: the best pause (after the sentence).
        editor.perform(.undo)
        #expect(editor.splitCue(cue.id, at: nil))
        #expect(editor.track.cues[0].text == "I told you already.")
    }

    @Test func splitCueWithoutWordTimesWorksAsBefore() {
        let editor = EditorState(
            launchOptions: LaunchOptions(isUITestMode: true), playback: SimulatedPlaybackEngine(frameRate: rate),
            frameRate: rate, track: SubtitleTrack(cues: [Cue(start: f(0), end: f(100), text: "First line\nSecond line")])
        )
        #expect(editor.splitCue(editor.track.cues[0].id, at: nil))
        #expect(editor.track.cues.map(\.text) == ["First line", "Second line"])
        #expect(editor.track.cues[0].end == f(50))
    }

    @Test func timingFixesStayOverTheWords() {
        // Too fast; the words are said from frame 100 to 135. Starting earlier is fine; a fix
        // starting after the first word or ending before the last is not offered.
        let text = "This line has exactly forty characters.."
        let editor = EditorState(
            launchOptions: LaunchOptions(isUITestMode: true), playback: SimulatedPlaybackEngine(frameRate: rate),
            frameRate: rate, track: SubtitleTrack(cues: [Cue(start: f(100), end: f(125), text: text), Cue(start: f(400), end: f(460), text: "Next")])
        )
        editor.storedTranscripts = [StoredTranscript(provider: "scripted", audioStream: nil, language: "en", words: words(text, from: 100, pauseAfter: -1, pause: 0))]
        let span = editor.spokenSpan(of: editor.track.cues[0])
        #expect(span?.start == f(100) && span?.end == f(135))
        for option in editor.suggestions(forCue: editor.track.cues[0].id) {
            guard case .fix(let fix) = option.action, fix.purpose.changesTimingOfCue else { continue }
            #expect(fix.start <= f(100) && fix.end >= f(135), "\(option.title)")
        }
    }
}

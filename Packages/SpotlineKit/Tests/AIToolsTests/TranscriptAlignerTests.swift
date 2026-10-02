import Foundation
import SubtitleCore
import Testing
@testable import AITools

struct TranscriptAlignerTests {
    func time(_ seconds: Double) -> MediaTime { MediaTime(seconds: seconds, timescale: 1000) }

    func cue(_ text: String, _ start: Double, _ end: Double) -> Cue {
        Cue(start: time(start), end: time(end), text: text)
    }

    /// Words said one after another from `start`, 0.3 s each with 0.1 s between.
    func said(_ text: String, from start: Double, by speaker: String? = nil) -> [TranscribedWord] {
        text.split(separator: " ").enumerated().map { index, word in
            let at = start + Double(index) * 0.4
            return TranscribedWord(text: String(word), start: time(at), end: time(at + 0.3), speaker: speaker)
        }
    }

    @Test func cueWordsGetTheTimesAndVoicesOfTheWordsHeard() {
        let cues = [cue("Hello there, Dunk.", 1, 3), cue("- Where's the horse?\n- Gone.", 4, 7)]
        let words = said("Hello there Dunk", from: 1.1, by: "speaker_0") + said("Where's the horse", from: 4.2, by: "speaker_1")
            + said("Gone", from: 6, by: "speaker_0")
        let alignment = TranscriptAligner.align(cues, to: words)
        #expect(alignment.matchedShare == 1)
        #expect(alignment.cues[0].spoken?.start == time(1.1))
        #expect(alignment.cues[0].spoken?.end == time(2.2))
        #expect(TranscriptAligner.voices(of: alignment.cues[0], text: cues[0].text) == ["speaker_0"])
        // A dialogue cue: one voice a line.
        #expect(TranscriptAligner.voices(of: alignment.cues[1], text: cues[1].text) == ["speaker_1", "speaker_0"])
        #expect(alignment.sync == nil)
    }

    @Test func soundDescriptionsAndSpeakerLabelsAreNotWords() {
        #expect(TranscriptAligner.words(of: "DUNK: (sighs) I'm <i>fine</i>.\n[door closes]") == ["I'm", "fine."])
        #expect(TranscriptAligner.words(of: "- Yes.\n- No!") == ["Yes.", "No!"])
    }

    @Test func wordsTheSubtitleLeavesOutOrRewordsDoNotBreakTheRest() {
        // The subtitle condenses: "Well, you know," is left out, "cannot" is "can't".
        let cues = [cue("I can't stay here.", 1, 3), cue("We leave at dawn.", 4, 6)]
        let words = said("Well you know I cannot stay here", from: 0.5) + said("We leave at dawn", from: 4.1)
        let alignment = TranscriptAligner.align(cues, to: words)
        #expect(alignment.cues[0].heardAs.map { $0?.text } == ["I", nil, "stay", "here"])
        #expect(alignment.cues[1].matched == 4)
        // What was heard at the first cue is its own stretch: from "I" on.
        #expect(alignment.cues[0].heard.map(\.text) == ["I", "cannot", "stay", "here"])
    }

    @Test func onlyLinesWhereSomethingElseIsSaidDiffer() throws {
        let cues = [
            cue("We ride north tomorrow.", 0, 2), cue("Nobody ever told me about that.", 3, 6), cue("I'm Ser Steffon Fossoway.", 7, 9),
            cue("We ride south tonight.", 10, 12),
        ]
        let words = said("We ride north tomorrow", from: 0) + said("You should have asked the old man", from: 3)
            + said("I'm Sir Stephen Fossaway", from: 7) + said("We ride south tonight", from: 10)
        let alignment = TranscriptAligner.align(cues, to: words)
        #expect(TranscriptAligner.heardInstead(of: alignment.cues[0]) == nil)
        let instead = try #require(TranscriptAligner.heardInstead(of: alignment.cues[1]))
        #expect(instead.text == "You should have asked the old man")
        // Names the transcriber spelled its own way are the same line.
        #expect(TranscriptAligner.heardInstead(of: alignment.cues[2]) == nil)
        #expect(TranscriptAligner.soundsAlike("steffon", "stephen"))
        #expect(!TranscriptAligner.soundsAlike("horse", "sword"))
    }

    @Test func aStrayWordInAnotherVoiceIsNotASecondSpeaker() {
        let line = cue("I never asked you to come with me.", 1, 4)
        var words = said("I never asked you to come with me", from: 1, by: "speaker_0")
        words[3].speaker = "speaker_1"
        let alignment = TranscriptAligner.align([line], to: words)
        #expect(TranscriptAligner.voices(of: alignment.cues[0], text: line.text) == ["speaker_0"])
    }

    /// Forty different lines, four seconds apart, and the words as they are said.
    func episode(cueShift: Double = 0, cueSpeed: Double = 1) -> (cues: [Cue], words: [TranscribedWord]) {
        let nouns = ["horse", "sword", "tent", "shield", "river", "tower", "squire", "knight", "lance", "helm"]
        let verbs = ["found", "lost", "sold", "broke"]
        var cues: [Cue] = [], words: [TranscribedWord] = []
        for index in 0..<40 {
            let text = "They \(verbs[index % 4]) the \(nouns[index % 10]) number \(index) today"
            let start = 10 + Double(index) * 4
            words += said(text, from: start)
            cues.append(cue(text + ".", (start - cueShift) / cueSpeed, (start - cueShift + 3) / cueSpeed))
        }
        return (cues, words)
    }

    @Test func subtitlesInSyncNeedNoCorrection() {
        let (cues, words) = episode()
        #expect(TranscriptAligner.align(cues, to: words).sync == nil)
        // A few frames of lead is how subtitles are timed.
        let (leading, heard) = episode(cueShift: 0.12)
        #expect(TranscriptAligner.align(leading, to: heard).sync == nil)
    }

    @Test func lateSubtitlesAreShiftedOntoTheAudio() throws {
        // Every cue starts 1.5 s after its words.
        let (cues, words) = episode(cueShift: -1.5)
        let alignment = TranscriptAligner.align(cues, to: words)
        #expect(alignment.matchedShare == 1, "Matching goes by the words, not the times")
        let sync = try #require(alignment.sync)
        #expect(sync.speed == 1)
        // Onto the audio with the lead subtitles have: up 0.15 s before the first word.
        #expect(abs(sync.offset + 1.65) < 0.01)
        #expect(sync.summary(over: 170) == "The subtitles are 1.6 s late." || sync.summary(over: 170) == "The subtitles are 1.7 s late.")
        #expect(sync.corrected(cues[0].start, rate: .fps25) == time(9.84))
    }

    @Test func subtitlesTimedToAnotherFrameRateAreStretched() throws {
        // Timed for 25 fps, on a 23.976 fps video: every time is too early, more so later on.
        let (cues, words) = episode(cueSpeed: 25.0 / 23.976)
        let sync = try #require(TranscriptAligner.align(cues, to: words).sync)
        #expect(sync.speed == 25.0 / 23.976)
        #expect(abs(sync.offset + 0.15) < 0.05)
        #expect(abs(sync.corrected(cues[39].start, rate: .fps25).seconds - 165.85) < 0.05)
    }

    @Test func anotherVideosSubtitlesMatchLittleAndGetNoCorrection() {
        let (_, words) = episode()
        let cues = (0..<40).map { cue("Nothing like what is said at all here \($0 + 100).", Double($0) * 4, Double($0) * 4 + 3) }
        let alignment = TranscriptAligner.align(cues, to: words)
        #expect(alignment.matchedShare < 0.2)
        #expect(alignment.sync == nil)
    }

    @Test func aWholeFilmMatchesQuickly() {
        // 12,000 words, a fifth of them left out of the subtitles: anchors keep it far from word-by-word over the whole.
        var cues: [Cue] = [], words: [TranscribedWord] = []
        for index in 0..<1500 {
            let text = "line \(index) says word\(index % 97) then other\(index % 13) and more\(index % 7) words here"
            let start = Double(index) * 4
            words += said(text + " um", from: start)
            cues.append(cue(text, start, start + 3))
        }
        let started = Date()
        let alignment = TranscriptAligner.align(cues, to: words)
        #expect(alignment.matchedShare > 0.99)
        #expect(Date().timeIntervalSince(started) < 5)
    }
}

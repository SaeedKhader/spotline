import Foundation
import QualityControl
import SubtitleCore
import Testing
@testable import AITools

struct SegmentationTests {
    let rate = FrameRate.fps25

    func words(_ list: [(String, Double, Double)]) -> [TranscribedWord] {
        list.map { TranscribedWord(text: $0.0, start: MediaTime(seconds: $0.1, timescale: 1000), end: MediaTime(seconds: $0.2, timescale: 1000)) }
    }

    @Test func sentencesAndPausesMakeCues() {
        let segmenter = CueSegmenter(preset: .netflix, frameRate: rate)
        let cues = segmenter.cues(from: words([
            ("Hello", 0.2, 0.5), ("there.", 0.55, 0.9), ("How", 1.0, 1.2), ("are", 1.25, 1.4), ("you?", 1.45, 1.8),
            ("Fine,", 3.0, 3.4), ("thanks.", 3.45, 3.9),
        ]))
        // "Hello there." is too short to end a cue on its own; the pause before "Fine" does.
        #expect(cues.map(\.text) == ["Hello there. How are you?", "Fine, thanks."])
        #expect(cues[0].start == MediaTime(frame: 5, rate: rate))
        // Ends half a second (13 frames) after the last word.
        #expect(cues[0].end == MediaTime(frame: 45 + 13, rate: rate))
        #expect(cues[1].start == MediaTime(frame: 75, rate: rate))
    }

    @Test func longTextBreaksIntoTwoBalancedLines() {
        let text = "I never thought I would see you again, not after everything that happened"
        let layout = CueSegmenter.layout(text.split(separator: " ").map(String.init), maxLineLength: 42)
        let lines = layout.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.count <= 42 })
        // Prefers the break after the comma.
        #expect(lines[0].hasSuffix("again,"))
    }

    @Test func tooMuchTextStartsANewCue() {
        let segmenter = CueSegmenter(preset: .netflix, frameRate: rate)
        let many = (0..<30).map { ("word\($0)", Double($0) * 0.2, Double($0) * 0.2 + 0.15) }
        let cues = segmenter.cues(from: words(many))
        #expect(cues.count >= 2)
        for cue in cues {
            #expect(cue.text.split(separator: "\n").allSatisfy { $0.count <= 42 })
            #expect(cue.duration.seconds <= 7)
        }
        // The QC gap between cues is kept.
        for (a, b) in zip(cues, cues.dropFirst()) {
            #expect(b.start.firstFrame(at: rate) - a.end.firstFrame(at: rate) >= 2)
        }
    }

    @Test func shortCuesLastTheMinimumDuration() {
        let cues = CueSegmenter(preset: .netflix, frameRate: rate).cues(from: words([("Hey!", 1.0, 1.1)]))
        #expect(cues.first!.duration >= MediaTime(value: 5, timescale: 6))
    }

    @Test func cuesSnapToNearbyShotChanges() {
        let segmenter = CueSegmenter(preset: .netflix, frameRate: rate, shotChanges: [20, 60])
        // Speech from frame 23 to 55: starts on the cut at 20, ends 2 frames before the cut at 60.
        let cues = segmenter.cues(from: words([("Somewhere", 0.92, 1.5), ("else.", 1.55, 2.2)]))
        #expect(cues.first!.start == MediaTime(frame: 20, rate: rate))
        #expect(cues.first!.end == MediaTime(frame: 58, rate: rate))
    }

    @Test func punctuationJoinsWithoutSpaces() {
        #expect(CueSegmenter.join(["Wait", ",", "what", "?"]) == "Wait, what?")
    }
}

struct CleanupTests {
    func cue(_ text: String) -> Cue {
        Cue(start: .zero, end: MediaTime(value: 1, timescale: 1), text: text)
    }

    @Test func profanityIsMasked() {
        #expect(CleanupTool.maskProfanity.clean("What the fuck? Holy shit.", languageCode: "en") == "What the f***? Holy s***.")
        #expect(CleanupTool.maskProfanity.clean("Fucking hell", languageCode: "en") == "F****** hell")
        #expect(CleanupTool.maskProfanity.clean("A scrappy classic", languageCode: "en") == "A scrappy classic")
        #expect(CleanupTool.maskProfanity.clean("Putain de merde !", languageCode: "fr") == "P***** de m**** !")
    }

    @Test func hearingImpairedTextIsRemoved() {
        #expect(CleanupTool.removeHearingImpaired.clean("[door slams]\nJOHN: Who's there?", languageCode: "en") == "Who's there?")
        #expect(CleanupTool.removeHearingImpaired.clean("(laughs) That's funny.", languageCode: "en") == "That's funny.")
        #expect(CleanupTool.removeHearingImpaired.clean("- [gasps]\n- Run!", languageCode: "en") == "Run!")
        #expect(CleanupTool.removeHearingImpaired.clean("♪ la la la ♪", languageCode: "en") == "")
        #expect(CleanupTool.removeHearingImpaired.clean("I'm OK.", languageCode: "en") == "I'm OK.")
    }

    @Test func spacingAndPunctuationAreFixed() {
        #expect(CleanupTool.fixSpacingAndPunctuation.clean("Wait ,  what ?", languageCode: "en") == "Wait, what?")
        #expect(CleanupTool.fixSpacingAndPunctuation.clean("Hi,John.Come in...", languageCode: "en") == "Hi, John. Come in…")
        #expect(CleanupTool.fixSpacingAndPunctuation.clean("Version 3.5 is out", languageCode: "en") == "Version 3.5 is out")
        #expect(CleanupTool.fixSpacingAndPunctuation.clean("إلى أين أنت ذاهب ?", languageCode: "ar") == "إلى أين أنت ذاهب؟")
        #expect(CleanupTool.fixSpacingAndPunctuation.clean("Quoi ? Non !", languageCode: "fr") == "Quoi ? Non !")
    }

    @Test func proposalsUpdateOrRemoveCues() {
        let keep = cue("Fine.")
        let sound = cue("[thunder]")
        let label = cue("MARY: Hello.")
        let proposal = CleanupTool.removeHearingImpaired.propose(for: [keep, sound, label], languageCode: "en")
        #expect(proposal.changes.count == 2)
        #expect(proposal.change(forCue: sound.id)?.kind == .delete)
        #expect(proposal.change(forCue: label.id)?.cue.text == "Hello.")
        #expect(proposal.change(forCue: keep.id) == nil)
    }
}

struct ProposedChangeTests {
    let rate = FrameRate.fps25

    func cue(_ text: String, at second: Int64) -> Cue {
        Cue(start: MediaTime(value: second, timescale: 1), end: MediaTime(value: second + 1, timescale: 1), text: text)
    }

    @Test func applyingInsertsUpdatesAndDeletes() {
        let a = cue("One", at: 0), b = cue("Two", at: 2), c = cue("Three", at: 4)
        var track = SubtitleTrack(cues: [a, b])
        var edited = b
        edited.text = "Deux"
        let speaker = Speaker(gender: .female, confidence: 0.9)
        var inserted = c
        inserted.speakerID = speaker.id
        let set = ProposedChangeSet(title: "Test", changes: [
            ProposedChange(kind: .delete, cue: a),
            ProposedChange.update(from: b, to: edited)!,
            ProposedChange(kind: .insert, cue: inserted),
        ], newSpeakers: [speaker, Speaker()])
        set.apply(to: &track)
        #expect(track.cues.map(\.text) == ["Deux", "Three"])
        #expect(track.speakers == [speaker], "Only speakers the applied cues use are added")
    }

    @Test func applyingSomeChangesLeavesTheOthers() {
        let a = cue("One", at: 0), b = cue("Two", at: 2)
        var track = SubtitleTrack(cues: [a, b])
        var a2 = a, b2 = b
        a2.text = "Un"
        b2.text = "Deux"
        let set = ProposedChangeSet(title: "Test", changes: [.update(from: a, to: a2)!, .update(from: b, to: b2)!])
        set.apply(to: &track, only: [b.id])
        #expect(track.cues.map(\.text) == ["One", "Deux"])
        #expect(set.removing([b.id]).changes.map(\.cueID) == [a.id])
    }

    @Test func confirmedAddresseesAreKept() {
        var a = cue("You're late.", at: 0)
        a.addressee = AddresseeTag(.female, confidence: 1, source: .confirmed)
        var guess = a
        guess.addressee = AddresseeTag(.male, confidence: 0.6)
        guess.text = "Tu es en retard."
        var track = SubtitleTrack(cues: [a])
        ProposedChangeSet(title: "Test", changes: [.update(from: a, to: guess)!]).apply(to: &track)
        #expect(track.cues[0].text == "Tu es en retard.")
        #expect(track.cues[0].addressee?.addressee == .female)
    }

    @Test func textDiffMarksChangedWords() {
        let parts = TextDiff.words(from: "Where are you going?", to: "Where are you off to?")
        #expect(parts == [.same("Where are you "), .removed("going?"), .added("off to?")])
        #expect(TextDiff.words(from: "", to: "New") == [.added("New")])
        #expect(TextDiff.words(from: "Same", to: "Same") == [.same("Same")])
    }

    @Test func transcriptionOnlyFillsGaps() {
        let existing = [cue("Already here", at: 2)]
        let proposed = [cue("New", at: 0), cue("Overlaps", at: 2), cue("Later", at: 5)]
        let set = Proposals.transcription(proposed, existing: existing)
        #expect(set.changes.map(\.cue.text) == ["New", "Later"])
        #expect(set.changes.allSatisfy { $0.kind == .insert })
    }

    @Test func translationUsesTheConfirmedAddresseesVariant() {
        var target = cue("", at: 0)
        target.addressee = AddresseeTag(.male, confidence: 1, source: .confirmed)
        let translation = CueTranslation(
            cueID: target.id, text: "انتِ مشغولة", addressee: AddresseeTag(.female, confidence: 0.6),
            variants: [TextVariant(addressee: .female, text: "انتِ مشغولة"), TextVariant(addressee: .male, text: "انت مشغول")]
        )
        let set = Proposals.translation([translation], cues: [target])
        #expect(set.changes.first?.cue.text == "انت مشغول")
        #expect(set.changes.first?.cue.addressee?.source == .confirmed)
    }
}

import SubtitleCore
import Testing
@testable import QualityControl

/// One-click fixes for QC issues: each clears an issue without adding a new kind.
struct QCFixesTests {
    let rate = FrameRate.fps25
    func f(_ n: Int64) -> MediaTime { MediaTime(frame: n, rate: rate) }
    func cue(_ start: Int64, _ end: Int64, _ text: String) -> Cue {
        Cue(start: f(start), end: f(end), text: text)
    }

    func fixes(_ cues: [Cue], _ index: Int, shotChanges: [Int64] = []) -> [QCFix] {
        QualityControl.fixes(for: index, in: cues, preset: .netflix, context: .init(frameRate: rate, shotChanges: shotChanges))
    }

    @Test func aFastLineIsExtendedAsFarAsTheNextCueAllows() {
        // 40 characters at 20 c/s need 2 s (50 frames); shown for 1 s.
        let text = "This line has exactly forty characters.."
        let found = fixes([cue(0, 25, text), cue(100, 150, "Next")], 0)
        #expect(found.first?.purpose == .extendEnd)
        #expect(found.first?.end == f(50))
        #expect(!found.contains { $0.purpose == .mergeWithNext }, "The next cue is 3 s later: its speech does not run on")
        // With the next cue close, extending runs into it: start earlier instead.
        let tight = fixes([cue(0, 12, "Before"), cue(40, 65, text), cue(67, 100, "Next")], 1)
        #expect(!tight.contains { $0.purpose == .extendEnd })
        #expect(tight.first?.purpose == .startEarlier)
        #expect(tight.first?.start == f(15))
    }

    @Test func extendingStopsOnceTheLineReadsWellEvenWithTheNextCueFarAway() {
        let text = "This line has exactly forty characters.."
        // Needs 50 frames; the next cue is 20 s away.
        #expect(fixes([cue(0, 25, text), cue(500, 550, "Next")], 0).first?.end == f(50))
        // A cut far after that point does not pull the end along…
        #expect(fixes([cue(0, 25, text), cue(500, 550, "Next")], 0, shotChanges: [90]).first?.end == f(50))
        // …one just after it does, so the cue ends on the cut.
        #expect(fixes([cue(0, 25, text), cue(500, 550, "Next")], 0, shotChanges: [55]).first?.end == f(55))
    }

    @Test func withoutRoomToReadWellNothingIsOffered() {
        // 40 characters need 50 frames; between the neighbours there are 26: no timing reads well,
        // and making it just long enough is no fix for a line too fast to read.
        let text = "This line has exactly forty characters.."
        #expect(fixes([cue(0, 20, "Before"), cue(30, 40, text), cue(50, 80, "After")], 1).isEmpty)
    }

    @Test func anEndThatWouldLandJustAfterACutGoesFurtherPastIt() {
        // Needs to end at 50; a cut at 46 makes 50 "4 frames after a shot change": end 12 after it.
        let text = "This line has exactly forty characters.."
        let found = fixes([cue(0, 25, text), cue(500, 550, "Next")], 0, shotChanges: [46])
        #expect(found.first?.purpose == .extendEnd)
        #expect(found.first?.end == f(58))
    }

    @Test func showingBothEndsNeverMovesTheCueAwayFromItsTime() {
        // The next cue is far: "Show" would move the line seconds later, so it is not offered.
        let text = "This line has exactly forty characters.."
        let found = fixes([cue(0, 90, "Before"), cue(100, 110, text), cue(300, 350, "Next")], 1, shotChanges: [150])
        #expect(!found.contains { $0.purpose == .extendBoth })
    }

    @Test func anOverlapIsTrimmedOrTheNextCueMoved() {
        let found = fixes([cue(0, 60, "First line"), cue(50, 120, "Second line")], 0)
        #expect(found.map(\.purpose) == [.trimEnd, .moveNextStart])
        #expect(found[0].end == f(48), "Two frames before the next cue")
        #expect(found[1].nextStart == f(62))
    }

    @Test func aLongLineIsRebalanced() {
        let text = "This subtitle line is much too long to fit on one line"
        let found = fixes([cue(0, 100, text)], 0)
        #expect(found.first?.purpose == .rebalance)
        #expect(found.first?.text == "This subtitle line is much\ntoo long to fit on one line")
    }

    @Test func markupAndDialogueAreNotRebalanced() {
        let preset = QCPreset.netflix
        #expect(QualityControl.rebalanced("<i>This subtitle line is much too long to fit on one line</i>", preset: preset) == nil)
        #expect(QualityControl.rebalanced("- This subtitle line is far too long to fit on one line\n- Yes", preset: preset) == nil)
    }

    @Test func aCueNearACutSnapsToIt() {
        // Starts 3 frames after a shot change at frame 100.
        let found = fixes([cue(103, 200, "Hello there")], 0, shotChanges: [100])
        #expect(found.first?.purpose == .snapStart)
        #expect(found.first?.start == f(100))
    }

    @Test func mergingRebalancesTwoLinesIntoTwo() {
        // Back to back and too fast: merged, the four half lines become two.
        let found = fixes([cue(0, 28, "Before"), cue(30, 40, "I never heard\nof this knight."), cue(42, 100, "You were\nhis squire."), cue(102, 150, "After")], 1)
        let merge = found.first { $0.purpose == .mergeWithNext }
        #expect(merge?.text == "I never heard of this\nknight. You were his squire.")
        #expect(merge?.end == f(100))
    }

    @Test func twoPeoplesLinesMergeAsDialogue() {
        var first = cue(0, 30, "Where were you\nlast night?")
        first.voices = ["speaker_0"]
        var second = cue(32, 60, "At my sister's.")
        second.voices = ["speaker_1"]
        #expect(QualityControl.mergedText(first, second, preset: .netflix) == "- Where were you last night?\n- At my sister's.")
        // The same person, or nobody known: the lines join, rebalanced to fit.
        second.voices = ["speaker_0"]
        #expect(QualityControl.mergedText(first, second, preset: .netflix) == "Where were you last night? At my sister's.")
    }

    @Test func aCueEndingJustAfterACutEndsFurtherAfterIt() {
        // Ends 11 frames after a cut at 100; ending on the cut would be too short.
        let found = fixes([cue(80, 111, "As he was.")], 0, shotChanges: [100])
        #expect(found.map(\.purpose) == [.endAfterCut])
        #expect(found.first?.end == f(112))
    }

    @Test func anEmptyCueIsDeleted() {
        #expect(fixes([cue(0, 50, "")], 0).map(\.purpose) == [.delete])
    }

    @Test func aCleanCueHasNoFixes() {
        #expect(fixes([cue(0, 50, "Fine")], 0).isEmpty)
    }
}

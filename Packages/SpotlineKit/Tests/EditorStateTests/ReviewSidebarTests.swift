import AITools
import EditorCommands
import Foundation
import PlaybackCore
import SubtitleCore
import Testing
@testable import EditorUI

/// The review sidebar: its cards and filters (All, Issues, Words, Choices, AI Changes),
/// stepping through them, deciding them, and deselecting.
@MainActor
struct ReviewSidebarTests {
    let rate = FrameRate.fps25

    func f(_ n: Int64) -> MediaTime { MediaTime(frame: n, rate: rate) }

    func makeEditor(_ cues: [Cue]) -> EditorState {
        let editor = EditorState(
            launchOptions: LaunchOptions(isUITestMode: true), playback: SimulatedPlaybackEngine(frameRate: rate),
            frameRate: rate, track: SubtitleTrack(cues: cues)
        )
        editor.reportError = { title, error in Issue.record("\(title) \(error)") }
        return editor
    }

    /// Cue 1 is fine, cue 2 has no text (a QC issue), cue 3 has a word to check, cue 4 reads two ways.
    func mixedCues() -> [Cue] {
        var unsure = Cue(start: f(200), end: f(260), text: "Hello Duncan")
        unsure.unsureWords = [UnsureWord(text: "Duncan", confidence: 0.3)]
        var flagged = Cue(start: f(300), end: f(360), text: "انت مستعد؟")
        flagged.flag = TranslationFlag(reasons: [.listener], variants: [
            TranslationVariant(text: "انت مستعد؟", listenerGender: .male, listenerCount: .one),
            TranslationVariant(text: "انتِ مستعدة؟", listenerGender: .female, listenerCount: .one),
        ], confidence: 0.6, note: "")
        return [
            Cue(start: f(0), end: f(60), text: "All good here"),
            Cue(start: f(100), end: f(160), text: ""),
            unsure,
            flagged,
        ]
    }

    @Test func eachFilterCountsItsKind() {
        let editor = makeEditor(mixedCues())
        #expect(editor.reviewCount(in: .all) == 3)
        #expect(editor.reviewCount(in: .issues) == 1)
        #expect(editor.reviewCount(in: .words) == 1)
        #expect(editor.reviewCount(in: .choices) == 1)
        #expect(editor.reviewCount(in: .changes) == 0)
        #expect(editor.cueIDsToReview(in: .all) == Set(editor.track.cues.dropFirst().map(\.id)))
    }

    @Test func cardsRunInTimeOrderAndEachWordIsACard() {
        var cues = mixedCues()
        cues[2].unsureWords = ["Hello", "Duncan"]
        let editor = makeEditor(cues)
        #expect(editor.reviewItems.map(\.kind) == [.issues, .word(0), .word(1), .choice])
        #expect(editor.reviewItems.map(\.cueID) == [cues[1].id, cues[2].id, cues[2].id, cues[3].id])
    }

    @Test func filtersAreExclusiveAndReviewEverythingLeavesThem() {
        let editor = makeEditor(mixedCues())
        let cues = editor.track.cues
        #expect(editor.isReviewSidebarVisible)
        #expect(!editor.canPerform(.showAllCues))
        #expect(editor.perform(.reviewWords))
        #expect(editor.reviewScope == .words && editor.isOn(.reviewWords) == true)
        #expect(editor.reviewItems.map(\.cueID) == [cues[2].id])
        #expect(editor.selectedCueID == cues[2].id, "The first card is picked")
        #expect(editor.perform(.reviewChoices))
        #expect(editor.reviewScope == .choices)
        #expect(editor.isOn(.reviewWords) == false)
        #expect(editor.reviewItems.map(\.cueID) == [cues[3].id])
        // The same filter again lists everything.
        #expect(editor.perform(.reviewChoices))
        #expect(editor.reviewScope == .all)
        #expect(editor.perform(.reviewWords))
        #expect(editor.perform(.showAllCues))
        #expect(editor.reviewScope == .all)
        #expect(editor.reviewItems.count == 3)
    }

    @Test func showReviewHidesAndShowsTheSidebar() {
        let editor = makeEditor(mixedCues())
        #expect(editor.isOn(.toggleReviewSidebar) == true)
        #expect(editor.perform(.toggleReviewSidebar))
        #expect(!editor.isReviewSidebarVisible && editor.isOn(.toggleReviewSidebar) == false)
        // A review command brings it back.
        #expect(editor.perform(.reviewWords))
        #expect(editor.isReviewSidebarVisible)
        // With nothing to review it still shows until hidden, saying so.
        let clean = makeEditor([Cue(start: f(0), end: f(60), text: "All good here")])
        #expect(clean.isReviewSidebarVisible && clean.reviewItems.isEmpty)
    }

    @Test func nextToReviewStepsThroughEveryKindInAll() {
        let editor = makeEditor(mixedCues())
        let cues = editor.track.cues
        #expect(editor.perform(.nextIssue))
        #expect(editor.selectedCueID == cues[1].id)
        #expect(editor.perform(.nextIssue))
        #expect(editor.selectedCueID == cues[2].id)
        #expect(editor.perform(.nextIssue))
        #expect(editor.selectedCueID == cues[3].id)
        #expect(!editor.perform(.nextIssue), "Nothing after the last")
        #expect(editor.perform(.previousIssue))
        #expect(editor.selectedCueID == cues[2].id)
    }

    @Test func nextToReviewStaysInTheFilter() {
        let editor = makeEditor(mixedCues())
        editor.perform(.reviewChoices)
        editor.select(nil)
        #expect(editor.perform(.nextIssue))
        #expect(editor.selectedCueID == editor.track.cues[3].id)
        #expect(!editor.perform(.nextIssue))
    }

    @Test func nextToReviewStartsAfterTheSelectedCue() {
        let editor = makeEditor(mixedCues())
        editor.select(editor.track.cues[0].id)
        #expect(editor.currentReviewItem == nil)
        #expect(editor.perform(.nextIssue))
        #expect(editor.selectedCueID == editor.track.cues[1].id)
    }

    @Test func selectingACueMarksItsCard() {
        let editor = makeEditor(mixedCues())
        let cues = editor.track.cues
        editor.select(cues[3].id)
        #expect(editor.currentReviewItem?.kind == .choice)
        editor.select(cues[0].id)
        #expect(editor.currentReviewItem == nil)
    }

    @Test func fixingTheLastIssueLeavesTheFilter() {
        let editor = makeEditor(mixedCues())
        let empty = editor.track.cues[1]
        editor.perform(.toggleIssuesPanel)
        #expect(editor.reviewScope == .issues)
        #expect(editor.selectedCueID == empty.id)
        editor.setText("Now it says something", forCue: empty.id)
        #expect(editor.issues[empty.id] == nil)
        #expect(editor.reviewScope == .all)
    }

    @Test func decidingMovesOnAndUndoReopensTheCard() {
        var cues = mixedCues()
        cues[2].unsureWords = ["Hello", "Duncan"]
        let editor = makeEditor(cues)
        let words = ReviewItem(cueID: cues[2].id, kind: .word(0), start: cues[2].start, word: "Hello")
        editor.selectReviewItem(words)
        // Confirming a word moves to the cue's next word, then to the next card.
        editor.decide(words, .primary)
        #expect(editor.track.cues[2].unsureWords == ["Duncan"])
        #expect(editor.currentReviewItem?.kind == .word(0))
        editor.decide(editor.currentReviewItem!, .primary)
        #expect(editor.track.cues[2].unsureWords == nil)
        #expect(editor.currentReviewItem?.kind == .choice)
        // A number tries another reading: it goes in, and the card stays until confirmed.
        let choice = editor.currentReviewItem!
        editor.decide(choice, .variant(1))
        #expect(editor.track.cues[3].text == "انتِ مستعدة؟")
        #expect(editor.currentReviewItem == choice)
        #expect(editor.settledReviews.count == 2)
        editor.decide(choice, .primary)
        #expect(editor.track.cues[3].flag?.isResolved == true)
        #expect(editor.settledReviews.map(\.outcome) == ["“Hello” confirmed", "“Duncan” confirmed", "Other reading used"])
        #expect(editor.lastSettledReview?.outcome == "Other reading used")
        // Undo from the note reopens the card with the reading still in, and it leaves the settled list.
        editor.undoLastReviewDecision()
        #expect(editor.track.cues[3].text == "انتِ مستعدة؟")
        #expect(editor.currentReviewItem?.kind == .choice)
        #expect(editor.settledReviews.count == 2)
        // ⌘Z takes the reading back.
        editor.perform(.undo)
        #expect(editor.track.cues[3].flag?.isResolved == false)
        #expect(editor.track.cues[3].text == "انت مستعد؟")
    }

    @Test func returnTriesTheFirstFixThenConfirmsIt() {
        let editor = makeEditor(mixedCues())
        let empty = editor.track.cues[1]
        #expect(editor.suggestions(forCue: empty.id).map(\.title) == ["Delete the Cue"])
        let issue = ReviewItem(cueID: empty.id, kind: .issues, start: empty.start)
        editor.select(empty.id)
        // Return tries the first fix: applied, and the card stays to be seen.
        editor.decide(issue, .primary)
        #expect(editor.cue(withID: empty.id) == nil)
        #expect(editor.currentReviewItem == issue)
        #expect(editor.pickedSuggestions(of: issue) == [0])
        // The next Return confirms it.
        editor.decide(issue, .primary)
        #expect(editor.lastSettledReview?.outcome == "Delete the Cue")
        #expect(editor.currentReviewItem?.kind == .word(0), "On to the next card")
        // Undo from the note lists the card again, the fix still in; ⌘Z takes the fix back.
        editor.undoLastReviewDecision()
        #expect(editor.currentReviewItem == issue)
        #expect(editor.pickedSuggestions(of: issue) == [0])
        editor.perform(.undo)
        #expect(editor.cue(withID: empty.id) != nil)
    }

    @Test func aFastLineSuggestsNewTiming() {
        let editor = makeEditor([
            Cue(start: f(0), end: f(25), text: "This line has exactly forty characters.."),
            Cue(start: f(200), end: f(260), text: "Next"),
        ])
        let cue = editor.track.cues[0]
        #expect(editor.suggestions(forCue: cue.id).first?.title == "Extend to 00:00:02:00")
        editor.decide(ReviewItem(cueID: cue.id, kind: .issues, start: cue.start), .suggestion(0))
        #expect(editor.track.cues[0].end == f(50))
        #expect(editor.issues[cue.id] == nil)
    }

    @Test func aFixedCueShowsOnlyItsFixUntilItIsTakenBack() {
        let editor = makeEditor([
            Cue(start: f(100), end: f(125), text: "This line has exactly forty characters.."),
            Cue(start: f(300), end: f(360), text: "Next"),
        ])
        let cue = editor.track.cues[0]
        let issue = ReviewItem(cueID: cue.id, kind: .issues, start: cue.start)
        editor.select(cue.id)
        let titles = editor.reviewSuggestions(for: issue).map(\.title)
        #expect(titles.starts(with: ["Extend to 00:00:06:00", "Start at 00:00:03:00"]))
        editor.decide(issue, .suggestion(0))
        #expect(editor.track.cues[0].end == f(150))
        // The cue has no issue left: only the option in place shows.
        #expect(editor.reviewSuggestions(for: issue).map(\.title) == ["Extend to 00:00:06:00"])
        // Taking it back brings the others back; another one goes in.
        editor.decide(issue, .suggestion(0))
        #expect(editor.track.cues[0].end == f(125))
        #expect(editor.reviewSuggestions(for: issue).map(\.title) == titles)
        editor.decide(issue, .suggestion(1))
        #expect(editor.track.cues[0].start == f(75) && editor.track.cues[0].end == f(125))
        #expect(editor.pickedSuggestions(of: issue) == [0], "The only option shown now")
        // Undo takes it back again, and nothing shows as picked.
        editor.perform(.undo)
        #expect(editor.track.cues[0].start == f(100))
        #expect(editor.pickedSuggestions(of: issue).isEmpty)
    }

    @Test func triedCardsStayListedUntilConfirmedWhereverTheUserGoes() {
        let text = "This line has exactly forty characters.."
        let editor = makeEditor([
            Cue(start: f(100), end: f(125), text: text),
            Cue(start: f(300), end: f(325), text: text),
            Cue(start: f(600), end: f(660), text: "Last"),
        ])
        let cues = editor.track.cues
        let first = ReviewItem(cueID: cues[0].id, kind: .issues, start: cues[0].start)
        let second = ReviewItem(cueID: cues[1].id, kind: .issues, start: cues[1].start)
        // Trying a fix clears the issue, but the card stays listed and current.
        editor.decide(first, .suggestion(0))
        #expect(editor.issues[cues[0].id] == nil)
        #expect(editor.reviewCards.map(\.id) == [first.id, second.id])
        #expect(editor.currentReviewItem?.id == first.id)
        // Moving on to another card, and trying a fix there, leaves the first tried and listed.
        editor.decide(second, .suggestion(0))
        #expect(editor.currentReviewItem?.id == second.id)
        #expect(editor.reviewCards.map(\.id) == [first.id, second.id])
        #expect(editor.track.cues[0].end == f(150), "The first card's fix stays")
        #expect(editor.pickedSuggestions(of: first) == [0])
        // Selecting other cues does not drop it either.
        editor.select(cues[2].id)
        #expect(editor.reviewCards.count == 2)
        // Only Confirm settles it.
        editor.decide(first, .primary)
        #expect(editor.reviewCards.map(\.id) == [second.id])
        #expect(editor.lastSettledReview?.outcome == "Extend to 00:00:06:00")
    }

    @Test func aTimingAndALinesOptionCombineAndFixAllPicksBoth() {
        // Too fast and a line too long: a timing and a lines option are both needed.
        let text = "This subtitle line is much too long to fit on one line"
        let editor = makeEditor([Cue(start: f(100), end: f(125), text: text), Cue(start: f(400), end: f(460), text: "Next")])
        let cue = editor.track.cues[0]
        let issue = ReviewItem(cueID: cue.id, kind: .issues, start: cue.start)
        editor.select(cue.id)
        let options = editor.reviewSuggestions(for: issue)
        #expect(options.first?.group == .all)
        #expect(options.first?.title == "Fix All: Extend to 00:00:06:18 + Rebalance Lines")
        let timing = options.firstIndex { $0.title == "Extend to 00:00:06:18" }!
        let lines = options.firstIndex { $0.title == "Rebalance Lines" }!
        // One from each group: both apply.
        editor.decide(issue, .suggestion(timing))
        editor.decide(issue, .suggestion(lines))
        #expect(editor.pickedSuggestions(of: issue) == [timing, lines])
        #expect(editor.isPicked(0, of: issue), "Fix All shows while exactly its parts are picked")
        #expect(editor.issues[cue.id] == nil)
        #expect(editor.track.cues[0].text == "This subtitle line is much\ntoo long to fit on one line")
        // Picking a lines option again takes it back; the timing stays.
        editor.decide(issue, .suggestion(lines))
        #expect(editor.track.cues[0].text == text)
        #expect(editor.track.cues[0].end == f(168))
        // Fix All picks both at once; Confirm keeps them.
        editor.decide(issue, .suggestion(0))
        #expect(editor.pickedSuggestions(of: issue) == [timing, lines])
        editor.decide(issue, .primary)
        #expect(editor.lastSettledReview?.outcome == options[0].title)
    }

    @Test func optionsFollowTheCuesAround() {
        // Too fast between two close cues: no timing fix, only the lines or merging.
        let text = "This subtitle line is much too long to fit on one line"
        let editor = makeEditor([
            Cue(start: f(40), end: f(98), text: "Before"), Cue(start: f(100), end: f(130), text: text), Cue(start: f(135), end: f(200), text: "Next"),
        ])
        let cue = editor.track.cues[1]
        let next = editor.track.cues[2]
        let issue = ReviewItem(cueID: cue.id, kind: .issues, start: cue.start)
        editor.select(cue.id)
        #expect(editor.reviewSuggestions(for: issue).map(\.title) == ["Rebalance Lines", "Merge with the Next Cue"], "No timing reads well here")
        editor.decide(issue, .suggestion(0))
        // With the next cue gone there is room to read: the options follow.
        editor.edit("Delete Cue") { track in track.cues.removeAll { $0.id == next.id } }
        let titles = editor.reviewSuggestions(for: issue).map(\.title)
        #expect(titles.contains("Extend to 00:00:06:18"))
        #expect(editor.pickedSuggestions(of: issue).count == 1, "The rebalanced lines stay picked")
    }

    @Test func theUndoNoteUndoesOnlyItsOwnDecision() {
        let editor = makeEditor(mixedCues())
        let cues = editor.track.cues
        let choice = ReviewItem(cueID: cues[3].id, kind: .choice, start: cues[3].start)
        // Trying a reading is the edit; confirming it changes nothing more.
        editor.decide(choice, .variant(1))
        editor.decide(choice, .primary)
        let tried = editor.track
        #expect(editor.canUndoLastReviewDecision)
        // Undo from the note reopens the card as it was, with the reading still in.
        editor.undoLastReviewDecision()
        #expect(editor.track == tried)
        #expect(editor.reviewCards.contains(choice))
        #expect(editor.currentReviewItem == choice)
        // After another change, the note no longer offers Undo (it would undo that change).
        editor.decide(choice, .primary)
        editor.setText("Changed", forCue: cues[0].id)
        #expect(!editor.canUndoLastReviewDecision)
        editor.undoLastReviewDecision()
        #expect(editor.track.cues[0].text == "Changed")
    }

    @Test func typingAfterAFixIsKeptWhenAnotherIsTried() {
        let text = "This subtitle line is much too long to fit on one line"
        let editor = makeEditor([Cue(start: f(100), end: f(125), text: text), Cue(start: f(400), end: f(460), text: "Next")])
        let cue = editor.track.cues[0]
        let issue = ReviewItem(cueID: cue.id, kind: .issues, start: cue.start)
        editor.select(cue.id)
        let lines = editor.reviewSuggestions(for: issue).firstIndex { $0.title == "Rebalance Lines" }!
        editor.decide(issue, .suggestion(lines))
        editor.setText("Much too long\nto fit", forCue: cue.id)
        // A timing option now goes on top of what was typed, not the words from before.
        let timing = editor.reviewSuggestions(for: issue).firstIndex { $0.group == .timing }
        if let timing { editor.decide(issue, .suggestion(timing)) }
        #expect(editor.track.cues[0].text == "Much too long\nto fit")
    }

    @Test func mergeWithNextMakesDialogueOfTwoSpeakers() {
        var first = Cue(start: f(0), end: f(30), text: "Where were you?")
        first.speaker = "Beth"
        var second = Cue(start: f(32), end: f(60), text: "Out.")
        second.speaker = "Morty"
        let editor = makeEditor([first, second])
        editor.select(first.id)
        #expect(editor.perform(.mergeWithNext))
        #expect(editor.track.cues.map(\.text) == ["- Where were you?\n- Out."])
    }

    @Test func frameIssuesHaveTheirOwnCardAndFilter() {
        // Too fast, and one frame before the next cue (the gap is a frame issue).
        let editor = makeEditor([
            Cue(start: f(0), end: f(99), text: "This line has exactly forty characters.. and then some more."),
            Cue(start: f(100), end: f(160), text: "Next"),
        ])
        let cue = editor.track.cues[0]
        #expect(editor.reviewItems(in: .all).filter { $0.cueID == cue.id }.map(\.kind) == [.issues, .frames])
        #expect(editor.reviewCount(in: .frames) == 1)
        let frames = ReviewItem(cueID: cue.id, kind: .frames, start: cue.start)
        #expect(editor.cardIssues(frames).map(\.kind) == [.gapTooShort(frames: 1)])
        #expect(editor.reviewSuggestions(for: frames).allSatisfy { $0.clears.contains("gap") })
        let issues = ReviewItem(cueID: cue.id, kind: .issues, start: cue.start)
        #expect(editor.reviewSuggestions(for: issues).allSatisfy { !$0.clears.contains("gap") || $0.clears.count > 1 })
        #expect(editor.perform(.reviewFrames))
        #expect(editor.reviewItems.map(\.kind) == [.frames])
    }

    @Test func aReadingSpeedNoFixCanLowerCanBeIgnoredUntilItGetsFaster() {
        // Too fast, back to back with its neighbours: nothing reads slower.
        let text = "This line has exactly forty characters.."
        let editor = makeEditor([
            Cue(start: f(0), end: f(28), text: "Before"), Cue(start: f(30), end: f(40), text: text), Cue(start: f(42), end: f(80), text: "After"),
        ])
        let cue = editor.track.cues[1]
        let item = ReviewItem(cueID: cue.id, kind: .issues, start: cue.start)
        #expect(editor.canIgnoreReadingSpeed(item))
        editor.decide(item, .ignoreReadingSpeed)
        #expect(editor.issues[cue.id]?.contains { if case .readingSpeed = $0.kind { true } else { false } } == false)
        #expect(editor.lastSettledReview?.outcome == "Reading speed 100 c/s accepted")
        // Faster than accepted: flagged again. Undo takes the Ignore back.
        editor.setTiming(start: f(30), end: f(38), forCue: cue.id, actionName: "Set Out")
        #expect(editor.issues[cue.id]?.isEmpty == false)
        editor.perform(.undo)
        editor.perform(.undo)
        #expect(editor.track.cues[1].acceptedReadingSpeed == nil)
        // With a fix for it, there is no Ignore.
        let roomy = makeEditor([Cue(start: f(0), end: f(25), text: text)])
        #expect(!roomy.canIgnoreReadingSpeed(ReviewItem(cueID: roomy.track.cues[0].id, kind: .issues, start: .zero)))
    }

    @Test func returnKeepsTheTranslatorsPick() {
        let editor = makeEditor(mixedCues())
        let choice = ReviewItem(cueID: editor.track.cues[3].id, kind: .choice, start: editor.track.cues[3].start)
        editor.decide(choice, .primary)
        #expect(editor.track.cues[3].flag?.isResolved == true)
        #expect(editor.track.cues[3].text == "انت مستعد؟")
        #expect(editor.settledReviews.last?.outcome == "Reading kept")
    }

    @Test func fixingAWordInItsCardMovesOnWhenDone() {
        let editor = makeEditor(mixedCues())
        let cue = editor.track.cues[2]
        let focus = editor.reviewFocusRequest
        let word = ReviewItem(cueID: cue.id, kind: .word(0), start: cue.start, word: "Duncan")
        editor.editReviewItem(word)
        #expect(editor.reviewEditingItem == word)
        #expect(editor.selectedCueID == cue.id)
        #expect(editor.wordSelectionRequest?.word == "Duncan")
        // Typing over the word settles the card, which stays open while typing.
        editor.setText("Hello Dunk", forCue: cue.id)
        #expect(!editor.reviewItems.contains(word))
        #expect(editor.reviewEditingItem == word)
        editor.finishEditingReviewItem()
        #expect(editor.reviewEditingItem == nil)
        #expect(editor.currentReviewItem?.kind == .choice, "The next card")
        #expect(editor.reviewFocusRequest == focus + 1)
    }

    @Test func anIssueStillOpenAfterEditingStaysPicked() {
        let editor = makeEditor(mixedCues())
        let empty = editor.track.cues[1]
        let issue = ReviewItem(cueID: empty.id, kind: .issues, start: empty.start)
        editor.editReviewItem(issue)
        editor.finishEditingReviewItem()
        #expect(editor.currentReviewItem == issue)
    }

    @Test func proposedChangesOpenTheirFilterAndCloseItWhenDecided() {
        let editor = makeEditor([
            Cue(start: f(0), end: f(60), text: "Hello ,world"),
            Cue(start: f(100), end: f(160), text: "Fine."),
        ])
        var changed = editor.track.cues[0]
        changed.text = "Hello, world"
        editor.presentReview(ProposedChangeSet(title: "Fix Punctuation", changes: [
            ProposedChange(kind: .update(before: editor.track.cues[0]), cue: changed),
        ]))
        #expect(editor.reviewScope == .changes && editor.isReviewSidebarVisible)
        #expect(editor.reviewCount(in: .changes) == 1)
        #expect(editor.currentReviewItem?.kind == .change)
        editor.decide(editor.currentReviewItem!, .reject)
        #expect(editor.track.cues[0].text == "Hello ,world")
        #expect(editor.reviewScope == .all)
        #expect(!editor.canPerform(.reviewChanges))
    }

    @Test func deselectClearsTheSelection() {
        let editor = makeEditor(mixedCues())
        #expect(!editor.canPerform(.deselectCue))
        editor.select(editor.track.cues[0].id)
        #expect(editor.perform(.deselectCue))
        #expect(editor.selectedCueID == nil)
    }

    @Test func selectingWithoutSeekingLeavesThePlayhead() {
        let editor = EditorState(
            launchOptions: LaunchOptions(isUITestMode: true), playback: SimulatedPlaybackEngine(frameRate: rate, frameCount: 500),
            frameRate: rate, track: SubtitleTrack(cues: mixedCues())
        )
        editor.open(URL(fileURLWithPath: "/tmp/clip.mov"))
        #expect(editor.hasMedia)
        editor.select(editor.track.cues[2].id, seeking: false)
        #expect(editor.selectedCueID == editor.track.cues[2].id)
        #expect(editor.currentFrame == 0)
        editor.select(editor.track.cues[3].id)
        #expect(editor.currentFrame == 300)
    }
}

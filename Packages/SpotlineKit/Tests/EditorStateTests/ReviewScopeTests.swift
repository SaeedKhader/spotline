import AITools
import EditorCommands
import Foundation
import PlaybackCore
import SubtitleCore
import Testing
@testable import EditorUI

/// The cue list's review scopes (All, Issues, Words, Choices, AI Changes), stepping through
/// what there is to review, and deselecting.
@MainActor
struct ReviewScopeTests {
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

    @Test func eachScopeCountsItsKind() {
        let editor = makeEditor(mixedCues())
        #expect(editor.reviewCount(in: .all) == 4)
        #expect(editor.reviewCount(in: .issues) == 1)
        #expect(editor.reviewCount(in: .words) == 1)
        #expect(editor.reviewCount(in: .choices) == 1)
        #expect(editor.reviewCount(in: .changes) == 0)
        #expect(editor.cueIDsToReview(in: .all) == Set(editor.track.cues.dropFirst().map(\.id)))
    }

    @Test func scopesAreExclusiveAndShowAllLeavesThem() {
        let editor = makeEditor(mixedCues())
        let cues = editor.track.cues
        #expect(!editor.canPerform(.showAllCues))
        #expect(editor.perform(.reviewWords))
        #expect(editor.reviewScope == .words)
        #expect(editor.reviewListCues.map(\.id) == [cues[2].id])
        #expect(editor.perform(.reviewChoices))
        #expect(editor.reviewScope == .choices)
        #expect(!editor.isReviewingWords)
        #expect(editor.reviewListCues.map(\.id) == [cues[3].id])
        #expect(editor.perform(.showAllCues))
        #expect(editor.reviewScope == .all)
        #expect(editor.reviewListCues.count == 4)
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

    @Test func nextToReviewStaysInTheScope() {
        let editor = makeEditor(mixedCues())
        editor.perform(.reviewChoices)
        editor.select(nil)
        #expect(editor.perform(.nextIssue))
        #expect(editor.selectedCueID == editor.track.cues[3].id)
        #expect(!editor.perform(.nextIssue))
    }

    @Test func aFixedIssueStaysListedWhileItsCueIsSelected() {
        let editor = makeEditor(mixedCues())
        let empty = editor.track.cues[1]
        editor.perform(.toggleIssuesPanel)
        #expect(editor.selectedCueID == empty.id)
        editor.setText("Now it says something", forCue: empty.id)
        #expect(editor.issues[empty.id] == nil)
        #expect(editor.reviewListCues.map(\.id) == [empty.id], "The cue being fixed does not jump away")
        editor.select(editor.track.cues[0].id)
        editor.select(nil)
        #expect(editor.reviewListCues.isEmpty)
    }

    @Test func proposedChangesOpenTheirScopeAndCloseItWhenDecided() {
        let editor = makeEditor([
            Cue(start: f(0), end: f(60), text: "Hello ,world"),
            Cue(start: f(100), end: f(160), text: "Fine."),
        ])
        var changed = editor.track.cues[0]
        changed.text = "Hello, world"
        editor.presentReview(ProposedChangeSet(title: "Fix Punctuation", changes: [
            ProposedChange(kind: .update(before: editor.track.cues[0]), cue: changed),
        ]))
        #expect(editor.reviewScope == .changes)
        #expect(editor.reviewCount(in: .changes) == 1)
        #expect(editor.reviewListCues.map(\.id) == [changed.id])
        #expect(editor.perform(.acceptAllChanges))
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

import Foundation
import QualityControl
import SubtitleCore
import Testing
@testable import AITools

/// Lines from the akotsk review (Spotline's Arabic for S01E01 against the professional subtitles).
struct CueJoinerTests {
    let joiner = CueJoiner(preset: .netflix)

    func cue(_ text: String, _ start: Double, _ end: Double) -> Cue {
        Cue(start: MediaTime(seconds: start, timescale: 1000), end: MediaTime(seconds: end, timescale: 1000), text: text, sourceCueID: UUID())
    }

    func line(_ text: String, _ start: Double, _ end: Double, speaker: String? = nil, source: String? = nil) -> CueJoiner.Line {
        CueJoiner.Line(cue: cue(text, start, end), speaker: speaker, source: source)
    }

    @Test func aSentenceSplitOverTwoCuesBecomesOne() {
        let lines = [
            line("كنت لأترك سيفك، لكنه", 122.456, 124.625, speaker: "speaker_0", source: "I'd leave you your sword, but it"),
            line("لن يفعل سوى أن يصدأ في التراب.", 124.708, 126.710, speaker: "speaker_0", source: "would only rust in the ground."),
        ]
        let joined = joiner.join(lines)
        #expect(joined.count == 1)
        #expect(joined[0].text.replacing("\n", with: " ") == "كنت لأترك سيفك، لكنه لن يفعل سوى أن يصدأ في التراب.")
        #expect(joined[0].text.split(separator: "\n").count == 2)
        #expect(joined[0].id == lines[0].cue.id)
        #expect(joined[0].end == lines[1].cue.end)
        #expect(joined[0].sourceCueIDs == [lines[0].cue.sourceCueID!, lines[1].cue.sourceCueID!])
    }

    @Test func aQuickExchangeBecomesADialogueCue() {
        let joined = joiner.join([
            line("أيمكنك الاعتناء بها؟", 339.130, 340.215, speaker: "speaker_0", source: "Can you look after them?"),
            line("بإمكاني لو أردت.", 340.298, 342.592, speaker: "speaker_1", source: "I could if I wanted to."),
        ])
        #expect(joined.map(\.text) == ["- أيمكنك الاعتناء بها؟\n- بإمكاني لو أردت."])
    }

    @Test func aShortLineJoinsItsNeighbourFromTheSameSpeaker() {
        let joined = joiner.join([
            line("مرحبًا.", 327.452, 328.787, speaker: "speaker_0", source: "Hello."),
            line("هل أنت فتى الإسطبل؟", 328.870, 330.163, speaker: "speaker_0", source: "Are you the stable boy?"),
        ])
        #expect(joined.map(\.text) == ["مرحبًا. هل أنت فتى الإسطبل؟"])
    }

    @Test func twoWholeSentencesOfReadingLengthStayApart() {
        let joined = joiner.join([
            line("نصف البلدة ذهب إلى المبارزة.", 404.279, 406.031, speaker: "speaker_0", source: "Half the town's gone to the tourney."),
            line("وابني كان سيذهب لو سمحت له.", 406.114, 408.408, speaker: "speaker_0", source: "My own boy would go too, if I let him."),
        ])
        #expect(joined.count == 2)
    }

    @Test func noJoinOverALongPauseOrPastTheLimits() {
        // A second apart.
        #expect(joiner.join([line("سيدي؟", 10, 11), line("أنت!", 12, 13)]).count == 2)
        // Too long for two lines.
        let long = "وهذا يعني أن عليّ صدّ كل فارس ذي أرض ومرتزق يتنافسون"
        #expect(joiner.join([line(long, 10, 12, source: "And that means I have to fend off"), line("على التحدي. أتفهم؟", 12.1, 13)]).count == 2)
        // Longer than seven seconds together.
        #expect(joiner.join([line("لا، لا", 10, 14.5, source: "No, no"), line("لا، لا.", 14.6, 17.8)]).count == 2)
    }

    @Test func atMostThreeCuesJoin() {
        let joined = joiner.join([
            line("نعم.", 0, 0.8), line("لا.", 0.9, 1.7), line("ربما.", 1.8, 2.6), line("حسنًا.", 2.7, 3.5),
        ])
        #expect(joined.map(\.text) == ["نعم. لا. ربما.", "حسنًا."])
    }

    @Test func aFlaggedLinesVariantsCoverTheJoinedText() {
        var first = cue("أنت ضخم", 0, 1)
        first.flag = TranslationFlag(
            reasons: [.listener], variants: [TranslationVariant(text: "أنت ضخم"), TranslationVariant(text: "أنتِ ضخمة")], confidence: 0.6, note: ""
        )
        let joined = joiner.join([CueJoiner.Line(cue: first, source: "You're big"), line("بما يكفي لذلك.", 1.1, 2.2)])
        #expect(joined.count == 1)
        #expect(joined[0].flag?.variants.map(\.text) == ["أنت ضخم بما يكفي لذلك.", "أنتِ ضخمة بما يكفي لذلك."])
    }

    @Test func twoLinesWithChoicesOpenStayApart() {
        let flag = TranslationFlag(reasons: [.listener], variants: [TranslationVariant(text: "a"), TranslationVariant(text: "b")], confidence: 0.5, note: "")
        var a = cue("اسمع", 0, 1), b = cue("أنت", 1.1, 2)
        a.flag = flag
        b.flag = flag
        #expect(joiner.join([CueJoiner.Line(cue: a), CueJoiner.Line(cue: b)]).count == 2)
    }

    @Test func theProposalUpdatesTheFirstCueAndRemovesTheRest() {
        let lines = [line("كنت لأترك سيفك، لكنه", 0, 2, source: "I'd leave you your sword, but it"), line("سيصدأ.", 2.1, 3)]
        let proposal = Proposals.join(lines.map(\.cue), into: joiner.join(lines))
        #expect(proposal.changes.count == 2)
        #expect(proposal.change(forCue: lines[0].cue.id)?.cue.text == "كنت لأترك سيفك، لكنه سيصدأ.")
        #expect(proposal.change(forCue: lines[1].cue.id)?.kind == .delete)
    }
}

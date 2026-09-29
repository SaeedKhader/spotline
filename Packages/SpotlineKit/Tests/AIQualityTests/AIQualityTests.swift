import Foundation
import QualityControl
import SubtitleCore
import Testing
@testable import AIQuality

struct WordErrorRateTests {
    @Test func countsSubstitutionsDeletionsAndInsertions() {
        let alignment = WordAlignment(
            reference: "the cat sat on the mat".split(separator: " ").map(String.init),
            hypothesis: "oh the cat sit on mat".split(separator: " ").map(String.init)
        )
        #expect(alignment.substitutions == 1)
        #expect(alignment.deletions == 1)
        #expect(alignment.insertions == 1)
        #expect(alignment.matches == 4)
    }

    @Test func scoringTextIgnoresDescriptionsLabelsAndCase() {
        #expect(ScoringText.words("[door slams]\nJOHN: Don't go, Mary!") == ["don", "t", "go", "mary"])
        #expect(ScoringText.words("- (laughs) ♪ Hello ♪") == ["hello"])
        // Mixed case before a colon is speech, not a label.
        #expect(ScoringText.words("Note: this") == ["note", "this"])
    }
}

struct TranscriptionScoringTests {
    let rate = FrameRate.fps25

    func cue(_ start: Double, _ end: Double, _ text: String) -> Cue {
        Cue(start: MediaTime(seconds: start, timescale: 1000), end: MediaTime(seconds: end, timescale: 1000), text: text)
    }

    @Test func timingIsComparedOnlyWhereCuesStartOnTheSameWord() {
        let reference = [cue(1, 3, "Hello there."), cue(4, 6, "How are you\ntoday?"), cue(7, 8, "Fine.")]
        // The second and third reference cues are one cue here, and start late.
        let hypothesis = [cue(1.1, 3.2, "Hello there."), cue(4.2, 8.5, "How are you today? Fine.")]
        let score = Scoring.transcription(hypothesis: hypothesis, reference: reference, preset: .netflix, context: .init(frameRate: rate))
        #expect(score.wordErrorRate == 0)
        #expect(score.referenceBoundaries == 3)
        #expect(score.hypothesisBoundaries == 2)
        #expect(score.sharedBoundaries == 2)
        #expect(abs(score.boundaryRecall - 2.0 / 3) < 1e-9)
        #expect(score.boundaryPrecision == 1)
        #expect(score.startOffsets.values.sorted().map { ($0 * 1000).rounded() } == [100, 200])
        // "there." and "Fine." end both sides' cues.
        #expect(score.endOffsets.values.sorted().map { ($0 * 1000).rounded() } == [200, 500])
        // Only "Hello there." is the same cue in both; it has one line in both.
        #expect(score.sameCues == 1)
        #expect(score.lineBreakAgreement == 1)
    }

    @Test func rulesAreCountedWithTheQCChecks() {
        let long = cue(0, 0.5, "This line is much longer than forty-two characters, surely")
        let counts = RuleCounts([long], preset: .netflix, context: .init(frameRate: rate))
        #expect(counts.cues == 1)
        #expect(counts.linesTooLong == 1)
        #expect(counts.tooShort == 1)
        #expect(counts.readingSpeedTooFast == 1)
    }
}

struct TranslationScoringTests {
    @Test func chrFIsHundredForIdenticalTextAndLowerForDifferentText() {
        #expect(abs(ChrF.statistics(hypothesis: "مرحبا بك", reference: "مرحبا بك").score - 100) < 1e-9)
        let close = ChrF.statistics(hypothesis: "مرحبا بكم", reference: "مرحبا بك").score
        let far = ChrF.statistics(hypothesis: "وداعا", reference: "مرحبا بك").score
        #expect(close > 60 && close < 100)
        #expect(far < 10)
        // Statistics add up over lines: the corpus score is not an average of line scores.
        let sum = ChrF.statistics(hypothesis: "ab", reference: "ab") + ChrF.statistics(hypothesis: "abcdefgh", reference: "abcdefgx")
        #expect(sum.hypothesis[0] == 10)
    }

    @Test func mergedAndSplitCuesAreComparedAsGroups() {
        func cue(_ start: Double, _ end: Double, _ text: String) -> Cue {
            Cue(start: MediaTime(seconds: start, timescale: 1000), end: MediaTime(seconds: end, timescale: 1000), text: text)
        }
        let source = [cue(0, 2, "Hi."), cue(2.5, 3.5, "How are"), cue(3.6, 5, "you?"), cue(9, 10, "Bye.")]
        // The reference merges "How are" and "you?", and splits nothing else; "Bye." has no reference.
        let reference = [cue(0.1, 2.4, "مرحبا."), cue(2.5, 5, "كيف حالك؟")]
        let groups = Scoring.groups(source: source, reference: reference)
        #expect(groups.map(\.source) == [[0], [1, 2]])
        #expect(groups.map(\.reference) == [[0], [1]])
    }

    @Test func arabicAddresseeFormsAreReadFromMarkedWords() {
        #expect(ArabicAddressee.form(of: "هل أنتم بخير؟") == .plural)
        #expect(ArabicAddressee.form(of: "أين كتبكم؟") == .plural)
        #expect(ArabicAddressee.form(of: "ماذا تريدين؟") == .feminine)
        #expect(ArabicAddressee.form(of: "أنتِ محقة") == .feminine)
        #expect(ArabicAddressee.form(of: "ماذا تريد؟") == nil)
        #expect(ArabicAddressee.form(of: "كم الساعة؟") == nil)
        #expect(ArabicAddressee.form(of: "هذا تمرين") == nil)

        let agree = Scoring.translation(hypothesis: "ماذا تريدين؟", reference: "ماذا تريدين يا سارة؟", source: "What do you want?", targetLanguage: "ar")
        #expect(agree.addresseeAccuracy == 1)
        let disagree = Scoring.translation(hypothesis: "ماذا تريد؟", reference: "ماذا تريدين؟", source: "What do you want?", targetLanguage: "ar")
        #expect(disagree.addresseeAccuracy == 0)
        let unmarked = Scoring.translation(hypothesis: "مرحبا", reference: "أهلا", source: "Hi", targetLanguage: "ar")
        #expect(unmarked.addresseeAccuracy == nil)
    }
}

struct BenchmarkReportTests {
    @Test func markdownShowsBothRunsAndWhichWayEachMetricMoved() {
        var before = TranscriptionScore()
        before.referenceWords = 100
        before.substitutions = 20
        var after = before
        after.substitutions = 10
        let baseline = BenchmarkReport(label: "baseline", samples: [.init(name: "clip", transcription: before)])
        let report = BenchmarkReport(label: "fix-up", samples: [.init(name: "clip", transcription: after)])
        let markdown = report.markdown(comparedTo: baseline)
        #expect(markdown.contains("| Word error rate | 20.0% | 10.0% | −10.0% better |"))
        #expect(markdown.contains("| clip | 10.0% |"))
    }

    @Test func reportsRoundTripThroughJSON() throws {
        var score = TranscriptionScore()
        score.startOffsets = Offsets([0.1, -0.2])
        let report = BenchmarkReport(label: "run", samples: [.init(name: "clip", transcription: score, notes: ["note"])])
        let decoded = try JSONDecoder().decode(BenchmarkReport.self, from: JSONEncoder().encode(report))
        #expect(decoded.transcription == score)
        #expect(decoded.samples[0].notes == ["note"])
    }
}

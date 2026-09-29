import SubtitleCore
import Testing
@testable import QualityControl

struct QualityControlTests {
    let rate = FrameRate.fps25
    func cue(_ start: Int64, _ end: Int64, _ text: String, _ position: CuePosition = .bottom) -> Cue {
        Cue(start: MediaTime(frame: start, rate: rate), end: MediaTime(frame: end, rate: rate), text: text, position: position)
    }

    func kinds(_ cues: [Cue], _ preset: QCPreset = .basic, shotChanges: [Int64] = []) -> [[QCIssue.Kind]] {
        let issues = QualityControl.check(cues, preset: preset, context: .init(frameRate: rate, shotChanges: shotChanges))
        return cues.map { issues[$0.id]?.map(\.kind) ?? [] }
    }

    @Test func readingSpeedCountsVisibleCharacters() {
        // 10 visible characters over 1 s; tags and the line break don't count.
        #expect(cue(0, 25, "<i>Hello</i>\nthere").readingSpeed == 10)
        #expect(cue(0, 0, "x").readingSpeed == 0)
    }

    @Test func basicFlagsTextProblemsAndOverlaps() {
        let long = String(repeating: "a", count: 43)
        let cues = [
            cue(0, 50, "Fine"),
            cue(52, 60, "   "),
            cue(62, 100, "One\nTwo\nThree"),
            cue(102, 250, long),
            cue(240, 250, "Too fast for ten frames"),
            cue(300, 400, "Fine too"),
        ]
        let found = kinds(cues)
        #expect(found[0] == [])
        #expect(found[1] == [.empty])
        #expect(found[2] == [.tooManyLines(3)])
        #expect(found[3] == [.lineTooLong(line: 0, characters: 43), .overlapsNext])
        #expect(found[4] == [.readingSpeed(cues[4].readingSpeed)])
        #expect(found[5] == [])
    }

    @Test func gapsAreCountedInFramesPerPosition() {
        let cues = [
            cue(0, 50, "A"),
            cue(51, 70, "B"),  // 1 frame after A
            cue(60, 90, "Sign", .top),  // alongside B: fine
            cue(70, 90, "C"),  // right after B
            cue(92, 100, "D"),
        ]
        #expect(kinds(cues) == [[.gapTooShort(frames: 1)], [.gapTooShort(frames: 0)], [], [], []])
    }

    @Test func netflixChecksDurations() {
        // 5/6 s at 25 fps is 20.8 frames.
        let cues = [cue(0, 20, "Short"), cue(30, 51, "Long enough"), cue(60, 60 + 7 * 25 + 1, "Too long")]
        let found = kinds(cues, .netflix)
        #expect(found[0] == [.tooShort(MediaTime(frame: 20, rate: rate))])
        #expect(found[1] == [])
        #expect(found[2] == [.tooLong(MediaTime(frame: 176, rate: rate))])
    }

    @Test func netflixChecksShotChanges() {
        let shots: [Int64] = [100, 300, 500, 700]
        let cues = [
            cue(100, 150, "Starts on the cut"),
            cue(205, 298, "Ends two frames before a cut"),
            cue(305, 380, "Starts five frames after a cut"),
            cue(420, 495, "Ends five frames before a cut"),
            cue(600, 700, "Ends on a cut"),
            cue(720, 800, "Far from any cut"),
        ]
        #expect(kinds(cues, .netflix, shotChanges: shots) == [
            [], [], [.startNearShotChange(frames: 5)], [.endNearShotChange(frames: -5)], [], [],
        ])
        let basic = kinds(cues, .basic, shotChanges: shots)
        #expect(basic.allSatisfy { $0.isEmpty }, "Basic ignores shot changes")
    }

    @Test func presetsChangeTheLimits() {
        let cues = [cue(0, 50, String(repeating: "a", count: 38))]  // 38 characters, 19 c/s
        #expect(kinds(cues, .netflix) == [[]])
        #expect(kinds(cues, .netflixChildren) == [[.readingSpeed(19)]])
        #expect(kinds(cues, .broadcast) == [[.lineTooLong(line: 0, characters: 38), .readingSpeed(19)]])
    }

    @Test func messagesAreReadable() {
        let cues = [cue(0, 10, "Way too fast for this"), cue(11, 40, String(repeating: "a", count: 50))]
        let issues = QualityControl.check(cues, preset: .netflix, context: .init(frameRate: rate))
        #expect(issues[cues[0].id]?.map(\.message) == [
            "Reading speed 53 c/s (max 20)", "Shown for 0.4 s (min 0.83 s)", "1 frame before the next cue (min 2)",
        ])
        #expect(issues[cues[1].id]?.map(\.message) == ["Line 1 has 50 characters (max 42)", "Reading speed 43 c/s (max 20)"])
        #expect(issues[cues[0].id]?.first?.severity == .warning)
        #expect(QCIssue(kind: .overlapsNext, message: "").severity == .error)
    }

    @Test func findsTheNearestShotChange() {
        #expect(QualityControl.nearest(to: 5, in: []) == nil)
        #expect(QualityControl.nearest(to: 5, in: [1, 8, 20]) == 8)
        #expect(QualityControl.nearest(to: 30, in: [1, 8, 20]) == 20)
        #expect(QualityControl.nearest(to: 0, in: [1, 8, 20]) == 1)
    }

    @Test func presetsHaveUniqueIDs() {
        #expect(Set(QCPreset.all.map(\.id)).count == QCPreset.all.count)
        #expect(QCPreset.named("broadcast") == .broadcast)
    }
}

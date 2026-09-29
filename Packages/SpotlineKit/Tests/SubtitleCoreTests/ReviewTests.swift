import Testing
@testable import SubtitleCore

struct ReviewTests {
    let rate = FrameRate.fps25
    func cue(_ start: Int64, _ end: Int64, _ text: String) -> Cue {
        Cue(start: MediaTime(frame: start, rate: rate), end: MediaTime(frame: end, rate: rate), text: text)
    }

    @Test func readingSpeedCountsVisibleCharacters() {
        // 10 visible characters over 1 s; tags and the line break don't count.
        #expect(cue(0, 25, "<i>Hello</i>\nthere").readingSpeed == 10)
        #expect(cue(0, 0, "x").readingSpeed == 0)
    }

    @Test func flagsEachProblem() {
        let long = String(repeating: "a", count: 43)
        let cues = [
            cue(0, 50, "Fine"),
            cue(50, 60, "   "),
            cue(60, 100, "One\nTwo\nThree"),
            cue(100, 250, long),
            cue(240, 250, "Too fast for ten frames"),
            cue(300, 400, "Fine too"),
        ]
        let issues = Review.issues(in: cues)
        #expect(issues[cues[0].id] == nil)
        #expect(issues[cues[1].id] == [.empty])
        #expect(issues[cues[2].id] == [.tooManyLines(3)])
        #expect(issues[cues[3].id] == [.lineTooLong(line: 0, characters: 43), .overlapsNext])
        #expect(issues[cues[4].id] == [.readingSpeed(cues[4].readingSpeed)])
        #expect(issues[cues[5].id] == nil)
        #expect(issues.count == 4)
    }

    @Test func messagesAreReadable() {
        #expect(ReviewIssue.readingSpeed(23.4).message == "Reading speed 23 c/s (max 20)")
        #expect(ReviewIssue.lineTooLong(line: 1, characters: 50).message == "Line 2 has 50 characters (max 42)")
    }
}

struct TimestampTests {
    @Test func formatsAndParsesMilliseconds() {
        #expect(Timestamp.format(MediaTime(value: 133_790, timescale: 1000)) == "00:02:13,790")
        #expect(Timestamp.format(MediaTime(frame: 1, rate: .fps23_976), fractionSeparator: ".") == "00:00:00.042")
        #expect(Timestamp.parse("00:02:13,790") == MediaTime(value: 133_790, timescale: 1000))
        #expect(Timestamp.parse("02:13.79") == MediaTime(value: 13_379, timescale: 100))
        #expect(Timestamp.parse("00:02:13:19") == nil, "Frame timecodes are not timestamps")
    }
}

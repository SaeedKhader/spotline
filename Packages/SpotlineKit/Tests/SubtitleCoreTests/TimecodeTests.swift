import Testing
@testable import SubtitleCore

struct TimecodeTests {
    @Test func nonDropFrameLabel() {
        let timecode = Timecode(frameNumber: 86_400, rate: .fps24)
        #expect(timecode.description == "01:00:00:00")
        #expect(timecode.frameNumber == 86_400)
    }

    @Test func twentyThreeNineSevenSixUsesTwentyFourFrameLabels() {
        #expect(Timecode(frameNumber: 23, rate: .fps23_976).description == "00:00:00:23")
        #expect(Timecode(frameNumber: 24, rate: .fps23_976).description == "00:00:01:00")
    }

    @Test(arguments: [
        (Int64(0), "00:00:00;00"),
        (1_799, "00:00:59;29"),
        (1_800, "00:01:00;02"),
        (17_981, "00:09:59;29"),
        (17_982, "00:10:00;00"),
        (107_892, "01:00:00;00"),
    ])
    func dropFrameLabels(frame: Int64, label: String) {
        let timecode = Timecode(frameNumber: frame, rate: .fps29_97DropFrame)
        #expect(timecode.description == label)
        #expect(timecode.frameNumber == frame)
    }

    @Test(arguments: [FrameRate.fps29_97DropFrame, .fps59_94DropFrame, .fps23_976, .fps25])
    func everyFrameRoundTripsThroughItsLabel(rate: FrameRate) throws {
        for frame in Int64(0)..<40_000 {
            let label = Timecode(frameNumber: frame, rate: rate)
            #expect(label.frameNumber == frame)
            let parsed = try #require(Timecode(label.description, rate: rate))
            #expect(parsed == label)
        }
    }

    @Test func dropFrameRejectsSkippedLabels() {
        #expect(Timecode("00:01:00;00", rate: .fps29_97DropFrame) == nil)
        #expect(Timecode("00:01:00;01", rate: .fps29_97DropFrame) == nil)
        #expect(Timecode("00:01:00;02", rate: .fps29_97DropFrame) != nil)
        #expect(Timecode("00:10:00;00", rate: .fps29_97DropFrame) != nil)
    }

    @Test func parsingAcceptsCommonSeparatorsAndRejectsOutOfRangeFields() throws {
        let parsed = try #require(Timecode("01:02:03:04", rate: .fps25))
        let expectedFrame: Int64 = ((62 * 60) + 3) * 25 + 4
        #expect(parsed.frameNumber == expectedFrame)
        #expect(Timecode("01.02.03.04", rate: .fps25) == Timecode("01:02:03:04", rate: .fps25))
        #expect(Timecode("00:00:00:25", rate: .fps25) == nil)
        #expect(Timecode("00:60:00:00", rate: .fps25) == nil)
        #expect(Timecode("00:00:00", rate: .fps25) == nil)
    }
}

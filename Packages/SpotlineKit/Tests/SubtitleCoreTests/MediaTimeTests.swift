import Testing
@testable import SubtitleCore

struct MediaTimeTests {
    @Test func equalRatiosAreEqual() {
        #expect(MediaTime(value: 2, timescale: 4) == MediaTime(value: 1, timescale: 2))
        #expect(MediaTime(value: 0, timescale: 90_000) == .zero)
    }

    @Test(arguments: FrameRate.common)
    func frameStartsMapBackToTheSameFrame(rate: FrameRate) {
        for frame in Int64(0)..<5_000 {
            #expect(MediaTime(frame: frame, rate: rate).frame(at: rate) == frame)
        }
    }

    @Test func frameAtRoundsDownWithinAFrame() {
        let justBeforeFrameOne = MediaTime(value: 1_000, timescale: 24_000)
        #expect(justBeforeFrameOne.frame(at: .fps23_976) == 0)
        #expect(MediaTime(seconds: 1.0).frame(at: .fps25) == 25)
        #expect(MediaTime(value: -1, timescale: 1_000).frame(at: .fps25) == -1)
    }

    @Test func arithmeticAndOrdering() {
        let a = MediaTime(frame: 10, rate: .fps23_976)
        let b = MediaTime(frame: 4, rate: .fps25)
        #expect((a + b) - b == a)
        #expect(b < a)
        #expect(a.snapped(to: .fps23_976) == a)
    }

    @Test func frameRateDescriptions() {
        #expect(FrameRate.fps23_976.description == "23.976 fps")
        #expect(FrameRate.fps29_97DropFrame.description == "29.97 fps DF")
        #expect(FrameRate.fps25.description == "25 fps")
    }
}

struct MediaTimestampTests {
    @Test(arguments: FrameRate.common)
    func millisecondRoundedTimestampsMapToTheirFrame(rate: FrameRate) {
        for frame in Int64(0)..<5_000 {
            let exact = MediaTime(frame: frame, rate: rate)
            let milliseconds = (exact.seconds * 1000).rounded() / 1000
            #expect(MediaTime(seconds: milliseconds).nearestFrame(at: rate) == frame)
        }
    }

    @Test(arguments: FrameRate.common)
    func frameMidpointsLieInsideTheirFrame(rate: FrameRate) {
        for frame in Int64(0)..<1_000 {
            #expect(MediaTime(midpointOfFrame: frame, rate: rate).frame(at: rate) == frame)
        }
    }

    @Test func containerRatesMapToExactRates() {
        #expect(FrameRate(approximately: 23.976023) == .fps23_976)
        #expect(FrameRate(approximately: 29.97) == .fps29_97)
        #expect(FrameRate(approximately: 25) == .fps25)
        #expect(FrameRate(approximately: 12.5) == FrameRate(numerator: 12_500, denominator: 1000))
        #expect(FrameRate(approximately: 0) == nil)
        #expect(FrameRate(approximately: .nan) == nil)
    }
}

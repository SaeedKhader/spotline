import Testing
@testable import SubtitleCore

struct TimestampTests {
    @Test func formatsAndParsesMilliseconds() {
        #expect(Timestamp.format(MediaTime(value: 133_790, timescale: 1000)) == "00:02:13,790")
        #expect(Timestamp.format(MediaTime(frame: 1, rate: .fps23_976), fractionSeparator: ".") == "00:00:00.042")
        #expect(Timestamp.parse("00:02:13,790") == MediaTime(value: 133_790, timescale: 1000))
        #expect(Timestamp.parse("02:13.79") == MediaTime(value: 13_379, timescale: 100))
        #expect(Timestamp.parse("00:02:13:19") == nil, "Frame timecodes are not timestamps")
    }
}

import Testing
@testable import SubtitleCore

struct SubtitleTextTests {
    @Test func stripsMarkupAndDecodesEntities() {
        #expect(SubtitleText.visibleLines(of: "<i>Hello</i>\n{\\an8}Tom &amp; <v Anna>Jerry</v>") == ["Hello", "Tom & Jerry"])
        #expect(SubtitleText.visibleLines(of: "a &lt;b&gt; c") == ["a <b> c"])
        #expect(SubtitleText.visibleLines(of: "") == [""])
        #expect(SubtitleText.visibleLines(of: "One\n") == ["One", ""])
    }

    @Test func unmatchedBraceIsText() {
        #expect(SubtitleText.visibleLines(of: "A { B") == ["A { B"])
    }
}

struct FirstFrameTests {
    @Test func roundsUpToTheNextFrameStart() {
        let rate = FrameRate.fps23_976
        #expect(MediaTime(frame: 12, rate: rate).firstFrame(at: rate) == 12)
        // 0.5 s falls inside frame 11 (0.4588 s to 0.5005 s), which starts before it.
        #expect(MediaTime(value: 1, timescale: 2).firstFrame(at: rate) == 12)
        #expect(MediaTime.zero.firstFrame(at: rate) == 0)
    }
}

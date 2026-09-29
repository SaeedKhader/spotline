import Foundation
import SubtitleCore
import Testing
@testable import SubtitleFormats

/// Golden files in `Golden/` are canonical: reading and writing one reproduces it byte for byte.
/// Files in `Input/` are lenient real-world input; writing them gives `<name>.expected.<ext>`.
struct GoldenFileTests {
    static let goldenFiles = [
        "basic.srt", "basic.vtt", "styled.srt", "styled.vtt", "basic.ass", "styled.ass", "styled.ssa", "basic.ttml", "styled.ttml",
    ]

    @Test(arguments: goldenFiles)
    func roundTripIsExact(_ name: String) throws {
        let url = resource("Golden/\(name)")
        let original = try String(contentsOf: url, encoding: .utf8)
        let (format, track) = try SubtitleFile.read(from: url)
        #expect(!track.cues.isEmpty)
        #expect(format.serialize(track) == original)
    }

    @Test(arguments: ["lenient.srt", "features.vtt", "aegisub.ass", "legacy.ssa", "netflix.ttml", "ebu-tt.xml"])
    func lenientInputNormalizes(_ name: String) throws {
        let url = resource("Input/\(name)")
        let (format, track) = try SubtitleFile.read(from: url)
        let expectedName = url.deletingPathExtension().lastPathComponent + ".expected." + format.fileExtension
        let expected = try String(contentsOf: resource("Input/\(expectedName)"), encoding: .utf8)
        #expect(format.serialize(track) == expected)
        // The normalized output is itself canonical.
        #expect(format.serialize(try format.parseTrack(expected)) == expected)
    }

    @Test func srtAndVTTCarryTheSameCues() throws {
        let srt = try SubtitleFile.read(from: resource("Golden/basic.srt")).track.cues
        let vtt = try SubtitleFile.read(from: resource("Golden/basic.vtt")).track.cues
        #expect(srt.map(\.start) == vtt.map(\.start))
        #expect(srt.map(\.end) == vtt.map(\.end))
        #expect(srt.map(\.text) == vtt.map(\.text))
        let expectedVTT = try String(contentsOf: resource("Golden/basic.vtt"), encoding: .utf8)
        #expect(SubtitleFormat.webVTT.serialize(srt) == expectedVTT)
    }

    @Test func writtenFilesReadBack() throws {
        let cues = try SubtitleFile.read(from: resource("Golden/styled.srt")).track.cues
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // EBU STL keeps frames, not milliseconds; EBUSTLTests covers it.
        for format in SubtitleFormat.allCases where !format.isBinary {
            let url = directory.appending(path: "out.\(format.fileExtension)")
            try SubtitleFile.write(cues, as: format, to: url)
            let (readFormat, track) = try SubtitleFile.read(from: url)
            #expect(readFormat == format)
            // ASS keeps centiseconds.
            let precision: Int64 = format == .ass || format == .ssa ? 100 : 1000
            #expect(track.cues.map { ($0.start.seconds * Double(precision)).rounded() } == cues.map { ($0.start.seconds * Double(precision)).rounded() })
            // ASS and TTML write entities as characters, so compare what a viewer reads.
            #expect(track.cues.map { SubtitleText.visibleLines(of: $0.text) } == cues.map { SubtitleText.visibleLines(of: $0.text) })
            #expect(track.cues.map(\.position) == cues.map(\.position))
        }
    }

    private func resource(_ path: String) -> URL {
        Bundle.module.resourceURL!.appending(path: path)
    }
}

struct SRTTests {
    @Test func readsCRLFAndByteOrderMark() throws {
        let text = "\u{FEFF}1\r\n00:00:01,000 --> 00:00:02,000\r\nHello\r\nthere\r\n\r\n2\r\n00:00:03,000 --> 00:00:04,000\r\nBye\r\n"
        let cues = try SubtitleFormat.srt.parse(text)
        #expect(cues.map(\.text) == ["Hello\nthere", "Bye"])
        #expect(cues[1].start == MediaTime(value: 3, timescale: 1))
    }

    @Test func keepsExactFractions() throws {
        let cues = try SubtitleFormat.srt.parse("1\n00:00:01,0415 --> 00:00:02,5\nx\n")
        #expect(cues[0].start == MediaTime(value: 10_415, timescale: 10_000))
        #expect(cues[0].end == MediaTime(value: 5, timescale: 2))
    }

    @Test func writesFrameTimesToTheNearestMillisecond() {
        // Frame 1 at 23.976 fps starts at 1001/24000 s = 41.7083 ms.
        let cue = Cue(start: MediaTime(frame: 1, rate: .fps23_976), end: MediaTime(frame: 3, rate: .fps23_976), text: "x")
        #expect(SubtitleFormat.srt.serialize([cue]) == "1\n00:00:00,042 --> 00:00:00,125\nx\n")
    }

    @Test func dropsBlankLinesInsideCueText() throws {
        let cue = Cue(start: .zero, end: MediaTime(value: 1, timescale: 1), text: "One\n\nTwo\n")
        let written = SubtitleFormat.srt.serialize([cue])
        #expect(written == "1\n00:00:00,000 --> 00:00:01,000\nOne\nTwo\n")
        #expect(try SubtitleFormat.srt.parse(written).map(\.text) == ["One\nTwo"])
    }

    @Test func emptyFileHasNoCues() throws {
        #expect(try SubtitleFormat.srt.parse("").isEmpty)
        #expect(try SubtitleFormat.srt.parse("\n\n").isEmpty)
        #expect(SubtitleFormat.srt.serialize([]) == "")
    }

    @Test(arguments: [
        ("Hello\n", 1, "Expected a cue number or timing line"),
        ("1\n00:00:01,000 --> nope\nx\n", 2, "Invalid end time \"nope\""),
        ("1\n00:61:00,000 --> 00:00:02,000\nx\n", 2, "Invalid start time \"00:61:00,000\""),
        ("1\n00:00:01,000 --> 00:00:02,000\nx\n\ngarbage\n", 5, "Expected a cue number or timing line"),
    ])
    func reportsTheLineOfAnError(text: String, line: Int, reason: String) {
        #expect(throws: SubtitleParseError(line: line, reason: reason)) {
            try SubtitleFormat.srt.parse(text)
        }
    }
}

struct WebVTTTests {
    @Test func requiresTheHeader() throws {
        #expect(throws: SubtitleParseError.self) { try SubtitleFormat.webVTT.parse("00:01.000 --> 00:02.000\nx\n") }
        #expect(throws: SubtitleParseError.self) { try SubtitleFormat.webVTT.parse("WEBVTTX\n") }
        #expect(try SubtitleFormat.webVTT.parse("WEBVTT\n").isEmpty)
        #expect(try SubtitleFormat.webVTT.parse("\u{FEFF}WEBVTT\tHeader\n").isEmpty)
    }

    @Test func escapesArrowsInPayload() {
        let cue = Cue(start: .zero, end: MediaTime(value: 1, timescale: 1), text: "a --> b")
        #expect(SubtitleFormat.webVTT.serialize([cue]) == "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\na --&gt; b\n")
    }

    @Test func reportsABlockWithoutTiming() {
        #expect(throws: SubtitleParseError(line: 3, reason: "Expected a timing line (start --> end)")) {
            try SubtitleFormat.webVTT.parse("WEBVTT\n\nid\ntext\n")
        }
    }
}

struct FormatDetectionTests {
    @Test func detectsByExtensionThenContent() {
        #expect(SubtitleFormat.detect(fileExtension: "SRT", text: "") == .srt)
        #expect(SubtitleFormat.detect(fileExtension: "vtt", text: "") == .webVTT)
        #expect(SubtitleFormat.detect(fileExtension: "txt", text: "WEBVTT\n") == .webVTT)
        #expect(SubtitleFormat.detect(fileExtension: "txt", text: "1\n00:00:01,000 --> 00:00:02,000\n") == .srt)
        #expect(SubtitleFormat.detect(fileExtension: "txt", text: "hello") == nil)
        #expect(SubtitleFormat.detect(fileExtension: "ASS", text: "") == .ass)
        #expect(SubtitleFormat.detect(fileExtension: "dfxp", text: "") == .ttml)
        #expect(SubtitleFormat.detect(fileExtension: "txt", text: "[Script Info]\nScriptType: v4.00+\n") == .ass)
        #expect(SubtitleFormat.detect(fileExtension: "txt", text: "[Script Info]\nScriptType: v4.00\n") == .ssa)
        #expect(SubtitleFormat.detect(fileExtension: "xml", text: "<?xml version=\"1.0\"?>\n<tt xmlns=\"http://www.w3.org/ns/ttml\"/>") == .ttml)
        #expect(SubtitleFormat.detect(fileExtension: "xml", text: "<plist/>") == nil)
    }

    @Test func decodesCommonEncodings() throws {
        #expect(try SubtitleFile.decode(Data([0xEF, 0xBB, 0xBF, 0x41])) == "A")
        #expect(try SubtitleFile.decode(Data([0xFF, 0xFE, 0x41, 0x00])) == "A")
        #expect(try SubtitleFile.decode(Data([0xFE, 0xFF, 0x00, 0x41])) == "A")
        #expect(try SubtitleFile.decode(Data("Café".utf8)) == "Café")
        // "Café" in Windows-1252 is not valid UTF-8.
        #expect(try SubtitleFile.decode(Data([0x43, 0x61, 0x66, 0xE9])) == "Café")
    }
}

struct PositionTests {
    @Test func srtTopTagBecomesAPosition() throws {
        let cues = try SubtitleFormat.srt.parse("1\n00:00:01,000 --> 00:00:02,000\n{\\an8}Sign\nreads\n\n2\n00:00:03,000 --> 00:00:04,000\n{\\an2}Bottom\n")
        #expect(cues[0].position == .top)
        #expect(cues[0].text == "Sign\nreads")
        #expect(cues[1].position == .bottom)
        #expect(cues[1].text == "{\\an2}Bottom", "Other tags stay in the text")
        #expect(SubtitleFormat.srt.serialize([cues[0]]) == "1\n00:00:01,000 --> 00:00:02,000\n{\\an8}Sign\nreads\n")
    }

    @Test(arguments: [
        ("line:0", CuePosition.top), ("line:2", .top), ("line:-1", .bottom),
        ("line:10%", .top), ("line:90%,end", .bottom), ("align:start", .bottom),
    ])
    func vttLineSetting(_ setting: String, _ expected: CuePosition) throws {
        let cues = try SubtitleFormat.webVTT.parse("WEBVTT\n\n00:01.000 --> 00:02.000 \(setting)\nx\n")
        #expect(cues[0].position == expected)
    }

    @Test func topConvertsBetweenFormats() throws {
        let cue = Cue(start: .zero, end: MediaTime(value: 1, timescale: 1), text: "Up here", position: .top)
        let vtt = SubtitleFormat.webVTT.serialize([cue])
        #expect(vtt == "WEBVTT\n\n00:00:00.000 --> 00:00:01.000 line:0\nUp here\n")
        let back = try SubtitleFormat.srt.parse(SubtitleFormat.srt.serialize(try SubtitleFormat.webVTT.parse(vtt)))
        #expect(back[0].position == .top)
        #expect(back[0].text == "Up here")
    }
}


struct ASSTests {
    let styled: SubtitleTrack

    init() throws {
        styled = try SubtitleFile.read(from: Bundle.module.resourceURL!.appending(path: "Golden/styled.ass")).track
    }

    @Test func readsHeaderStylesAndSpeakers() throws {
        #expect(styled.properties["Title"] == "Spotline golden file")
        #expect(styled.properties["PlayResY"] == "1080")
        #expect(styled.properties["ScriptType"] == nil, "The writer decides the script type")
        #expect(styled.styles.map(\.name) == ["Default", "Flashback", "Sign"])
        let flashback = styled.styles[1]
        #expect(flashback.fontName == "Georgia")
        #expect(flashback.isItalic)
        #expect(flashback.spacing == 0.5)
        #expect(flashback.outlineColor == SubtitleColor(red: 0x20, green: 0x20, blue: 0x20))
        #expect(styled.styles[0].backColor.alpha == 0x80)
        #expect(styled.styles[2].alignment == 8)
        #expect(styled.cues[0].style == "Flashback")
        #expect(styled.cues[0].speaker == "Narrator")
        #expect(styled.cues[2].speaker == nil)
    }

    @Test func convertsMarkupAndPositions() {
        let cues = styled.cues
        #expect(cues[1].text == "- Is that you, Tom & Jerry?\n- <b>Who else?</b>")
        #expect(cues[3].position == .top, "The Sign style is top-aligned")
        #expect(cues[3].text == "هل أنت مشغول؟")
        #expect(cues[4].position == .top)
        #expect(cues[4].text == "Up here{\\fs48\\c&H00FFFF&}, smaller{\\r}")
        #expect(cues[5].position == .bottom)
        #expect(cues[5].text == "Sign style, at the bottom")
        #expect(cues[6].text == "Café, naïve,\u{00A0}日本語 ♪ <i>&lt;not a tag&gt;</i>")
        #expect(SubtitleText.visibleLines(of: cues[6].text) == ["Café, naïve,\u{00A0}日本語 ♪ <not a tag>"])
    }

    @Test func srtMarkupBecomesOverrideTags() throws {
        let cue = Cue(start: .zero, end: MediaTime(value: 1, timescale: 1), text: "<i>Hi</i> &amp; <font color=\"red\">bye</font>\nnow", position: .top)
        let written = SubtitleFormat.ass.serialize([cue])
        #expect(written.hasSuffix("Dialogue: 0,0:00:00.00,0:00:01.00,Default,,0,0,0,,{\\an8}{\\i1}Hi{\\i0} & bye\\Nnow\n"))
        #expect(written.contains("PlayResX: 1920\n"))
        let back = try SubtitleFormat.ass.parse(written)
        #expect(back[0].text == "<i>Hi</i> & bye\nnow")
        #expect(back[0].position == .top)
    }

    @Test func roundsToCentiseconds() {
        #expect(ASS.timestamp(MediaTime(frame: 1, rate: .fps23_976)) == "0:00:00.04")
        #expect(ASS.timestamp(MediaTime(value: 3_600_005, timescale: 1000)) == "1:00:00.01")
        #expect(ASS.timestamp(MediaTime(value: -1, timescale: 1)) == "0:00:00.00")
    }

    @Test func readsColorsInEveryNotation() {
        #expect(ASS.color("&H00FFFFFF") == .white)
        #expect(ASS.color("&H0000FF&") == SubtitleColor(red: 255, green: 0, blue: 0))
        #expect(ASS.color("&H800000FF") == SubtitleColor(red: 255, green: 0, blue: 0, alpha: 127))
        #expect(ASS.color("65535") == SubtitleColor(red: 255, green: 255, blue: 0))
        #expect(ASS.color("nope") == nil)
        #expect(ASS.assColor(SubtitleColor(red: 1, green: 2, blue: 3, alpha: 255)) == "&H00030201")
    }

    @Test func ssaAlignmentsAndBoldFlags() throws {
        let track = try SubtitleFile.read(from: Bundle.module.resourceURL!.appending(path: "Input/legacy.ssa")).track
        #expect(track.styles[0].isBold)
        #expect(track.styles[1].isItalic)
        #expect(track.styles[1].alignment == 8, "SSA 6 is top center")
        #expect(track.cues.map(\.position) == [.bottom, .top, .top])
        #expect(track.cues[2].text == "Moved to the top\nSecond line")
    }

    @Test func reportsBadTimes() {
        let text = "[Script Info]\nScriptType: v4.00+\n\n[Events]\nFormat: Layer, Start, End, Style, Text\nDialogue: 0,0:00:01.00,soon,Default,Hi\n"
        #expect(throws: SubtitleParseError(line: 6, reason: "Invalid end time \"soon\"")) { try SubtitleFormat.ass.parse(text) }
        #expect(throws: SubtitleParseError.self) { try SubtitleFormat.ass.parse("Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,x\n") }
    }
}

struct TTMLTests {
    func cues(_ body: String, root: String = "") throws -> [Cue] {
        try SubtitleFormat.ttml.parse("<tt xmlns=\"http://www.w3.org/ns/ttml\" xmlns:ttp=\"http://www.w3.org/ns/ttml#parameter\" \(root)><body><div>\(body)</div></body></tt>")
    }

    @Test func readsEveryTimeExpression() throws {
        let rate = "ttp:frameRate=\"25\" ttp:tickRate=\"1000\""
        let parsed = try cues("""
            <p begin="00:00:01.5" end="00:00:02:05">a</p>
            <p begin="3s" end="3500ms">b</p>
            <p begin="100f" dur="0.5m">c</p>
            <p begin="4500t" end="0.002h">d</p>
            """, root: rate)
        #expect(parsed.map(\.start) == [
            MediaTime(value: 3, timescale: 2), MediaTime(value: 3, timescale: 1),
            MediaTime(value: 4, timescale: 1), MediaTime(value: 9, timescale: 2),
        ])
        #expect(parsed.map(\.end) == [
            MediaTime(value: 11, timescale: 5), MediaTime(value: 7, timescale: 2),
            MediaTime(value: 34, timescale: 1), MediaTime(value: 36, timescale: 5),
        ])
    }

    @Test func framesUseTheMultiplier() throws {
        let parsed = try cues("<p begin=\"00:00:00:01\" end=\"00:00:01:00\">x</p>", root: "ttp:frameRate=\"24\" ttp:frameRateMultiplier=\"1000 1001\"")
        #expect(parsed[0].start == MediaTime(frame: 1, rate: .fps23_976))
    }

    @Test func languageAndStyles() throws {
        let track = try SubtitleFile.read(from: Bundle.module.resourceURL!.appending(path: "Input/netflix.ttml")).track
        #expect(track.languageCode == "en-US")
        #expect(track.cues[1].text == "<i>Somewhere quieter,\nwhere nobody </i>knows<i> us.</i>")
        #expect(track.cues[2].text == "<b>SIGN:</b> <i><b>Keep out</b></i>")
        #expect(track.cues[3].text == "Up top & <u>underlined</u> &lt;3")
        #expect(track.cues.map(\.position) == [.bottom, .bottom, .top, .top, .bottom])
        let written = SubtitleFormat.ttml.serialize(track)
        #expect(written.contains("xml:lang=\"en-US\""))
    }

    @Test func overlappingStylingTagsNestProperly() {
        #expect(TTML.content("<i>a<b>b</i>c</b>") == "<span tts:fontStyle=\"italic\">a<span tts:fontWeight=\"bold\">b</span></span><span tts:fontWeight=\"bold\">c</span>")
        #expect(TTML.content("</i>x<u>y") == "x<span tts:textDecoration=\"underline\">y</span>")
    }

    @Test func rejectsOtherXML() {
        #expect(throws: SubtitleParseError(line: 1, reason: "A TTML file must have a <tt> root element")) {
            try SubtitleFormat.ttml.parse("<plist/>")
        }
        #expect(throws: SubtitleParseError.self) { try SubtitleFormat.ttml.parse("<tt><body>") }
    }
}

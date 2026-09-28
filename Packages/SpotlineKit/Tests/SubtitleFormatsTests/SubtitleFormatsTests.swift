import Foundation
import SubtitleCore
import Testing
@testable import SubtitleFormats

/// Golden files in `Golden/` are canonical: reading and writing one reproduces it byte for byte.
/// Files in `Input/` are lenient real-world input; writing them gives `<name>.expected.<ext>`.
struct GoldenFileTests {
    static let goldenFiles = ["basic.srt", "basic.vtt", "styled.srt", "styled.vtt"]

    @Test(arguments: goldenFiles)
    func roundTripIsExact(_ name: String) throws {
        let url = resource("Golden/\(name)")
        let original = try String(contentsOf: url, encoding: .utf8)
        let (format, cues) = try SubtitleFile.read(from: url)
        #expect(!cues.isEmpty)
        #expect(format.serialize(cues) == original)
    }

    @Test(arguments: ["lenient.srt", "features.vtt"])
    func lenientInputNormalizes(_ name: String) throws {
        let url = resource("Input/\(name)")
        let expectedName = url.deletingPathExtension().lastPathComponent + ".expected." + url.pathExtension
        let expected = try String(contentsOf: resource("Input/\(expectedName)"), encoding: .utf8)
        let (format, cues) = try SubtitleFile.read(from: url)
        #expect(format.serialize(cues) == expected)
        // The normalized output is itself canonical.
        #expect(format.serialize(try format.parse(expected)) == expected)
    }

    @Test func srtAndVTTCarryTheSameCues() throws {
        let srt = try SubtitleFile.read(from: resource("Golden/basic.srt")).cues
        let vtt = try SubtitleFile.read(from: resource("Golden/basic.vtt")).cues
        #expect(srt.map(\.start) == vtt.map(\.start))
        #expect(srt.map(\.end) == vtt.map(\.end))
        #expect(srt.map(\.text) == vtt.map(\.text))
        let expectedVTT = try String(contentsOf: resource("Golden/basic.vtt"), encoding: .utf8)
        #expect(SubtitleFormat.webVTT.serialize(srt) == expectedVTT)
    }

    @Test func writtenFilesReadBack() throws {
        let cues = try SubtitleFile.read(from: resource("Golden/styled.srt")).cues
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for format in SubtitleFormat.allCases {
            let url = directory.appending(path: "out.\(format.fileExtension)")
            try SubtitleFile.write(cues, as: format, to: url)
            let (readFormat, readCues) = try SubtitleFile.read(from: url)
            #expect(readFormat == format)
            #expect(readCues.map(\.start) == cues.map(\.start))
            #expect(readCues.map(\.text) == cues.map(\.text))
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

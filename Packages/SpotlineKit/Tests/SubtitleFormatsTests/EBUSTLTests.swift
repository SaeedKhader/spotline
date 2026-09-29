import Foundation
import SubtitleCore
import Testing
@testable import SubtitleFormats

struct EBUSTLTests {
    let rate = FrameRate.fps25

    func frame(_ n: Int64, _ rate: FrameRate = .fps25) -> MediaTime { MediaTime(frame: n, rate: rate) }

    func roundTrip(_ track: SubtitleTrack, frameRate: FrameRate = .fps25) throws -> (Data, SubtitleTrack) {
        let data = EBUSTL.serialize(track, frameRate: frameRate, creationDate: Date(timeIntervalSince1970: 0))
        return (data, try EBUSTL.parse(data))
    }

    @Test func writesAHeaderAndOneBlockPerCue() throws {
        let track = SubtitleTrack(languageCode: "en", cues: [
            Cue(start: frame(25), end: frame(75), text: "Hello"),
            Cue(start: frame(100), end: frame(150), text: "World"),
        ], properties: ["Title": "Pilot"])
        let (data, _) = try roundTrip(track)
        #expect(data.count == 1024 + 2 * 128)
        let header = String(decoding: data[0..<16], as: UTF8.self)
        #expect(header == "850STL25.011" + "0009")
        #expect(String(decoding: data[16..<21], as: UTF8.self) == "Pilot")
        // Total blocks and subtitles.
        #expect(String(decoding: data[238..<248], as: UTF8.self) == "0000200002")
        #expect(EBUSTL.isEBUSTL(data))
    }

    @Test func roundTripsTextTimesPositionLanguageAndTitle() throws {
        let track = SubtitleTrack(languageCode: "fr", cues: [
            Cue(start: frame(25), end: frame(75), text: "Déjà vu, <i>garçon</i>\nÇa va ? 50 £"),
            Cue(start: frame(80), end: frame(130), text: "SORTIE", position: .top),
        ], properties: ["Title": "Épisode 1"])
        let (_, back) = try roundTrip(track)
        #expect(back.cues.map(\.text) == ["Déjà vu, <i>garçon</i>\nÇa va ? 50 £", "SORTIE"])
        #expect(back.cues.map(\.start) == [frame(25), frame(80)])
        #expect(back.cues.map(\.end) == [frame(75), frame(130)])
        #expect(back.cues.map(\.position) == [.bottom, .top])
        #expect(back.languageCode == "fr")
        #expect(back.properties["Title"] == "Épisode 1")
    }

    @Test func arabicUsesTheLatinArabicTable() throws {
        let text = "أنتَ مشغول؟\nنعم، جداً"
        let track = SubtitleTrack(languageCode: "ar", cues: [Cue(start: frame(0), end: frame(50), text: text)])
        let (data, back) = try roundTrip(track)
        #expect(String(decoding: data[12..<16], as: UTF8.self) == "027E")
        #expect(back.cues.first?.text == text)
        #expect(back.languageCode == "ar")
    }

    @Test func hebrewUsesTheLatinHebrewTable() throws {
        let track = SubtitleTrack(cues: [Cue(start: frame(0), end: frame(50), text: "שלום")])
        let (data, back) = try roundTrip(track)
        #expect(String(decoding: data[12..<14], as: UTF8.self) == "04")
        #expect(back.cues.first?.text == "שלום")
    }

    @Test func longTextContinuesInExtensionBlocks() throws {
        let long = String(repeating: "abcdefghij ", count: 15).trimmingCharacters(in: .whitespaces)
        let track = SubtitleTrack(cues: [Cue(start: frame(0), end: frame(50), text: long), Cue(start: frame(60), end: frame(70), text: "x")])
        let (data, back) = try roundTrip(track)
        #expect(data.count == 1024 + 3 * 128)
        #expect(back.cues.map(\.text) == [long, "x"])
    }

    @Test func writes30FramesForOtherRates() throws {
        let rate = FrameRate.fps23_976
        let track = SubtitleTrack(cues: [Cue(start: MediaTime(value: 1, timescale: 1), end: MediaTime(value: 2, timescale: 1), text: "x")])
        let (data, back) = try roundTrip(track, frameRate: rate)
        #expect(String(decoding: data[3..<11], as: UTF8.self) == "STL30.01")
        // Whole frames at 29.97: 1 s is on frame 30.
        #expect(back.cues.first?.start == frame(30, .fps29_97))
    }

    @Test func programmeStartIsSubtractedAndKept() throws {
        var track = SubtitleTrack(cues: [Cue(start: frame(25), end: frame(50), text: "x")])
        track.properties[EBUSTL.Property.startOfProgramme] = "10000000"
        let (data, back) = try roundTrip(track)
        // TCI of the first block: 10:00:01:00.
        #expect(Array(data[1024 + 5..<1024 + 9]) == [10, 0, 1, 0])
        #expect(back.cues.first?.start == frame(25))
        #expect(back.properties[EBUSTL.Property.startOfProgramme] == "10000000")
    }

    /// A teletext-style file as broadcast tools write it: double height, boxes,
    /// colours, doubled line breaks, a comment block and an italic run.
    @Test func readsTeletextControlCodes() throws {
        var gsi = [UInt8](repeating: 0x20, count: 1024)
        func put(_ offset: Int, _ value: String) { gsi.replaceSubrange(offset..<offset + value.utf8.count, with: Array(value.utf8)) }
        put(0, "850STL25.011000923")
        put(253, "23")
        put(256, "00000000")
        func block(number: UInt16, in tcIn: [UInt8], out tcOut: [UInt8], row: UInt8, comment: Bool = false, text: [UInt8]) -> [UInt8] {
            var block = [UInt8](repeating: 0, count: 128)
            block[1] = UInt8(number & 0xFF)
            block[3] = 0xFF
            block.replaceSubrange(5..<9, with: tcIn)
            block.replaceSubrange(9..<13, with: tcOut)
            block[13] = row
            block[14] = 2
            block[15] = comment ? 1 : 0
            let field = text + [UInt8](repeating: 0x8F, count: 112 - text.count)
            block.replaceSubrange(16..<128, with: field)
            return block
        }
        let first: [UInt8] = [0x0D, 0x0B, 0x0B] + Array("Hello".utf8) + [0x0A, 0x0A, 0x8A, 0x8A, 0x0D, 0x0B, 0x0B, 0x07, 0x80]
            + Array("there".utf8) + [0x81, 0x0A, 0x0A]
        let data = Data(gsi
            + block(number: 0, in: [0, 0, 1, 0], out: [0, 0, 2, 12], row: 20, text: first)
            + block(number: 1, in: [0, 0, 3, 0], out: [0, 0, 4, 0], row: 20, comment: true, text: Array("note".utf8))
            + block(number: 2, in: [0, 0, 5, 0], out: [0, 0, 6, 0], row: 2, text: [0x0D] + Array("Sign".utf8)))
        let track = try EBUSTL.parse(data)
        #expect(track.cues.map(\.text) == ["Hello\n<i>there</i>", "Sign"])
        #expect(track.cues.map(\.position) == [.bottom, .top])
        #expect(track.cues.map(\.start) == [frame(25), frame(125)])
        #expect(track.cues.first?.end == frame(62))
        #expect(track.languageCode == "en")
    }

    @Test func fileReadDetectsEBUSTLByContent() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "out.stl")
        try SubtitleFile.write([Cue(start: frame(0), end: frame(25), text: "x")], as: .ebuSTL, frameRate: .fps25, to: url)
        let (format, track) = try SubtitleFile.read(from: url)
        #expect(format == .ebuSTL)
        #expect(track.cues.map(\.text) == ["x"])
        // A text .stl (Spruce STL) is not EBU STL.
        let spruce = directory.appending(path: "spruce.stl")
        try "$FontName = Arial\n00:00:01:00 , 00:00:02:00 , Hi\n".write(to: spruce, atomically: true, encoding: .utf8)
        #expect(throws: SubtitleParseError.self) { try SubtitleFile.read(from: spruce) }
    }

    @Test func iso6937() {
        let text = "Ærøskøbing: naïve café — ½ «ok»"
        let bytes = ISO6937.encode(text)
        // The em dash has no code, so it becomes "?".
        #expect(ISO6937.decode(bytes) == "Ærøskøbing: naïve café ? ½ «ok»")
        #expect(ISO6937.encode("é") == [0xC2, 0x65])
    }
}

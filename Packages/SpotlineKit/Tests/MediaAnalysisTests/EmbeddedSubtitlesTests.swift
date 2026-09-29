import Foundation
import SubtitleCore
import Testing
@testable import MediaAnalysis

/// Reads the subtitle tracks muxed into the fixture clips.
struct EmbeddedSubtitlesTests {
    static let mkv = MediaAnalyzerTests.fixtures.appending(path: "embedded-subs.mkv")
    static let mp4 = MediaAnalyzerTests.fixtures.appending(path: "embedded-text.mp4")

    func time(_ milliseconds: Int64) -> MediaTime { MediaTime(value: milliseconds, timescale: 1000) }

    @Test func listsEveryTrackWithItsLanguageTitleAndKind() throws {
        let tracks = try MediaAnalyzer.subtitleTracks(in: Self.mkv)
        #expect(tracks.map(\.streamIndex) == [2, 3, 4, 5])
        #expect(tracks.map(\.codec) == ["subrip", "ass", "hdmv_pgs_subtitle", "webvtt"])
        #expect(tracks.map(\.formatName) == ["SubRip", "ASS", "PGS", "WebVTT"])
        #expect(tracks.map(\.language) == ["eng", "eng", "eng", "fre"])
        #expect(tracks.map(\.title) == ["English", "Styled", "Signs", "Français"])
        #expect(tracks.map(\.isText) == [true, true, false, true])
        #expect(tracks.map(\.isDefault) == [true, false, false, false])
        #expect(tracks[2].isForced)
        #expect(tracks.map(\.fileFormat) == [.srt, .ass, nil, .webVTT])
    }

    @Test func mediaWithoutSubtitlesHasNoTracks() throws {
        #expect(try MediaAnalyzer.subtitleTracks(in: MediaAnalyzerTests.fixtures.appending(path: "testsrc-23.976.mp4")).isEmpty)
    }

    @Test func keepsSubRipTextAsWritten() throws {
        let track = try MediaAnalyzer.subtitles(in: Self.mkv, streamIndex: 2)
        #expect(track.languageCode == "en")
        #expect(track.cues.map(\.text) == ["<i>Hello</i> from the\nembedded track", "Second & last cue"])
        #expect(track.cues.map(\.start) == [time(500), time(2000)])
        #expect(track.cues.map(\.end) == [time(1500), time(3250)])
    }

    @Test func keepsASSStylesSpeakersAndPositions() throws {
        let track = try MediaAnalyzer.subtitles(in: Self.mkv, streamIndex: 3)
        #expect(track.styles.map(\.name) == ["Default", "Sign"])
        #expect(track.properties["PlayResX"] == "1920")
        #expect(track.cues.count == 4)
        #expect(track.cues[0].text == "<i>First cue</i>")
        #expect(track.cues[0].speaker == "Anna")
        #expect(track.cues[1].style == "Sign")
        #expect(track.cues[1].position == .top)
        #expect(track.cues.map(\.start) == [time(500), time(1000), time(2000), time(3000)])
        #expect(track.cues.map(\.end) == [time(1500), time(2500), time(2400), time(4000)])
    }

    @Test func readsWebVTT() throws {
        let track = try MediaAnalyzer.subtitles(in: Self.mkv, streamIndex: 5)
        #expect(track.cues.map(\.text) == ["Bonjour", "Au revoir"])
        #expect(track.cues.map(\.start) == [time(750), time(2500)])
        #expect(track.cues.map(\.end) == [time(1750), time(3000)])
    }

    @Test func readsMP4TimedTextAsPlainCues() throws {
        let tracks = try MediaAnalyzer.subtitleTracks(in: Self.mp4)
        #expect(tracks.map(\.codec) == ["mov_text"])
        let track = try MediaAnalyzer.subtitles(in: Self.mp4, streamIndex: tracks[0].streamIndex)
        #expect(track.styles.isEmpty)
        #expect(track.cues.map(\.text) == ["<i>Hello</i> from the\nembedded track", "Second & last cue"])
        #expect(track.cues.map(\.start) == [time(500), time(2000)])
        #expect(track.cues.map(\.end) == [time(1500), time(3250)])
        #expect(track.cues.allSatisfy { $0.style == nil })
    }

    @Test func refusesImageBasedTracks() {
        #expect(throws: MediaAnalyzer.Error.self) {
            try MediaAnalyzer.subtitles(in: Self.mkv, streamIndex: 4)
        }
    }

    @Test func refusesStreamsThatAreNotSubtitles() {
        #expect(throws: MediaAnalyzer.Error.self) {
            try MediaAnalyzer.subtitles(in: Self.mkv, streamIndex: 0)
        }
    }

    @Test func reportsProgressAndCanBeCancelled() throws {
        var counts: [Int] = []
        _ = try MediaAnalyzer.subtitles(in: Self.mkv, streamIndex: 2) { progress in
            if let count = progress.partial { counts.append(count) }
            return true
        }
        #expect(counts.last == 2)
    }
}

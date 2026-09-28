import Foundation
import SubtitleCore
import Testing
@testable import MediaAnalysis

struct MediaAnalyzerTests {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "../../../../Fixtures")
        .standardizedFileURL

    /// cuts-25.mp4: 4 s at 25 fps with cuts at frames 40 and 75, and a
    /// 440 Hz tone at 0.1 (0–1 s), silence (1–2 s), an 880 Hz tone at 0.0375 (2–4 s).
    /// (FFmpeg's sine source has amplitude 1/8, scaled by 0.8 and 0.3.)
    @Test func findsTheCutsAndTheLoudness() throws {
        let analysis = try MediaAnalyzer.analyze(Self.fixtures.appending(path: "cuts-25.mp4"))
        #expect(analysis.shotChanges.map { $0.nearestFrame(at: .fps25) } == [40, 75])

        let waveform = try #require(analysis.waveform)
        #expect(waveform.bucketsPerSecond == 100)
        #expect((395...405).contains(waveform.peaks.count))
        #expect((0.09...0.11).contains(waveform.peak(from: 0.2, to: 0.8)))
        #expect(waveform.peak(from: 1.2, to: 1.8) < 0.005)
        #expect((0.03...0.045).contains(waveform.peak(from: 2.5, to: 3.5)))
    }

    /// dialogue-5.1.mp4: loud pink noise ("music") on every channel but the center,
    /// and a 440 Hz tone ("dialogue") on the center from 1 to 2 s.
    @Test func surroundWaveformShowsTheDialogueChannel() throws {
        let analysis = try MediaAnalyzer.analyze(Self.fixtures.appending(path: "dialogue-5.1.mp4"))
        let waveform = try #require(analysis.waveform)
        #expect(waveform.source == .centerChannel)
        #expect(analysis.audioStreamIndex == 1)
        #expect(waveform.peak(from: 0.2, to: 0.8) < 0.02, "Music must not show")
        #expect(waveform.peak(from: 1.2, to: 1.8) > 0.4, "Dialogue must show")
        #expect(waveform.peak(from: 2.5, to: 3.5) < 0.02)
    }

    @Test func monoAndStereoAreMixed() throws {
        let analysis = try MediaAnalyzer.analyze(Self.fixtures.appending(path: "cuts-25.mp4"))
        #expect(analysis.waveform?.source == .mix)
    }

    @Test func aStreamThatIsNotAudioFallsBackToTheMainAudio() throws {
        var options = MediaAnalyzer.Options()
        options.audioStreamIndex = 0  // the video stream
        let analysis = try MediaAnalyzer.analyze(Self.fixtures.appending(path: "dialogue-5.1.mp4"), options: options)
        #expect(analysis.audioStreamIndex == 1)
    }

    @Test func steadyFootageHasNoCuts() throws {
        let analysis = try MediaAnalyzer.analyze(Self.fixtures.appending(path: "testsrc-23.976.mp4"))
        #expect(analysis.shotChanges.isEmpty)
    }

    @Test func reportsProgressAndCancels() throws {
        var reports: [Double] = []
        #expect(throws: MediaAnalyzer.Error.self) {
            try MediaAnalyzer.shotChanges(in: Self.fixtures.appending(path: "cuts-25.mp4")) { progress in
                reports.append(progress.fraction)
                return progress.fraction < 0.5
            }
        }
        #expect(reports.last! >= 0.5)
        #expect(reports == reports.sorted())
    }

    @Test func shotChangesArriveInOrder() throws {
        var options = MediaAnalyzer.Options()
        options.partialResultInterval = .zero
        var partials: [(until: MediaTime, cuts: [MediaTime])] = []
        let final = try MediaAnalyzer.shotChanges(in: Self.fixtures.appending(path: "cuts-25.mp4"), options: options) { progress in
            if let partial = progress.partial { partials.append((progress.analyzedUntil, partial)) }
            return true
        }
        #expect(partials.count > 10)
        #expect(partials.last?.cuts == final)
        // Every cut reported so far lies in the part already read, and none disappear later.
        for (index, entry) in partials.enumerated() {
            #expect(entry.cuts.allSatisfy { $0 <= entry.until })
            #expect(final.starts(with: entry.cuts), "\(index)")
        }
        #expect(partials.first!.cuts.isEmpty)
    }

    @Test func waveformGrowsAsItIsRead() throws {
        var options = MediaAnalyzer.Options()
        options.partialResultInterval = .zero
        var sizes: [Int] = []
        let final = try MediaAnalyzer.waveform(of: Self.fixtures.appending(path: "cuts-25.mp4"), options: options) { progress in
            if let partial = progress.partial { sizes.append(partial.waveform.peaks.count) }
            return true
        }
        #expect(sizes.count > 10)
        #expect(sizes == sizes.sorted())
        #expect(sizes.last == final.waveform.peaks.count)
        #expect(final.audioStreamIndex == 1)
    }

    @Test func missingFileThrows() {
        #expect(throws: MediaAnalyzer.Error.self) {
            try MediaAnalyzer.analyze(URL(fileURLWithPath: "/nonexistent.mov"))
        }
    }

    @Test func waveformCodesPeaksCompactly() throws {
        let waveform = Waveform(bucketsPerSecond: 10, peaks: [0, 128, 255])
        let decoded = try JSONDecoder().decode(Waveform.self, from: JSONEncoder().encode(waveform))
        #expect(decoded == waveform)
        #expect(waveform.peak(from: 0, to: 0.3) == 1)
        #expect(waveform.peak(from: 0.1, to: 0.15) == Float(128) / 255)
    }
}

struct AnalysisCacheTests {
    @Test func storesAndInvalidatesByModification() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "AnalysisCacheTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let media = directory.appending(path: "clip.mov")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: media)

        let cache = AnalysisCache(directory: directory.appending(path: "cache"))
        #expect(cache.waveform(for: media, audioStream: nil) == nil)
        #expect(cache.shotChanges(for: media) == nil)
        let audio = AudioAnalysis(waveform: Waveform(bucketsPerSecond: 100, peaks: [1, 2, 3]), audioStreamIndex: 1)
        let cuts = [MediaTime(frame: 40, rate: .fps25)]
        cache.store(audio, for: media, audioStream: nil)
        cache.store(shotChanges: cuts, for: media)
        #expect(cache.waveform(for: media, audioStream: nil) == audio)
        #expect(cache.shotChanges(for: media) == cuts)
        #expect(cache.waveform(for: media, audioStream: 2) == nil, "Another audio stream is another entry")

        try Data([1, 2, 3, 4]).write(to: media)
        #expect(cache.waveform(for: media, audioStream: nil) == nil)
        #expect(cache.shotChanges(for: media) == nil)
    }
}

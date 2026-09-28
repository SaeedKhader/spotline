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

    @Test func steadyFootageHasNoCuts() throws {
        let analysis = try MediaAnalyzer.analyze(Self.fixtures.appending(path: "testsrc-23.976.mp4"))
        #expect(analysis.shotChanges.isEmpty)
    }

    @Test func reportsProgressAndCancels() throws {
        var reports: [Double] = []
        #expect(throws: MediaAnalyzer.Error.self) {
            try MediaAnalyzer.analyze(Self.fixtures.appending(path: "cuts-25.mp4")) { fraction in
                reports.append(fraction)
                return fraction < 0.5
            }
        }
        #expect(reports.last! >= 0.5)
        #expect(reports == reports.sorted())
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
        #expect(cache.analysis(for: media) == nil)
        let analysis = MediaAnalysis(
            waveform: Waveform(bucketsPerSecond: 100, peaks: [1, 2, 3]),
            shotChanges: [MediaTime(frame: 40, rate: .fps25)]
        )
        cache.store(analysis, for: media)
        #expect(cache.analysis(for: media) == analysis)

        try Data([1, 2, 3, 4]).write(to: media)
        #expect(cache.analysis(for: media) == nil)
    }
}

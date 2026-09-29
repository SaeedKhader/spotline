import Foundation
import SubtitleCore
import Testing
@testable import MediaAnalysis

struct SpeechDetectionTests {
    static let say = URL(fileURLWithPath: "/usr/bin/say")

    /// Speech made at test time with macOS text-to-speech: 2 s of silence,
    /// about 6 s of speech, 2 s of silence. (Generated, not committed, so the
    /// repository holds no synthesized voice recordings.)
    static func makeSpeechFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "speech-\(UUID().uuidString).wav")
        let process = Process()
        process.executableURL = say
        process.arguments = [
            "-o", url.path, "--file-format=WAVE", "--data-format=LEI16@22050",
            "[[slnc 2000]] Where are we going? Somewhere quieter, where nobody knows us. We should leave now, before it gets dark. [[slnc 2000]]",
        ]
        try process.run()
        process.waitUntilExit()
        return url
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: say.path)))
    func findsTheSpokenPart() throws {
        let url = try Self.makeSpeechFile()
        defer { try? FileManager.default.removeItem(at: url) }
        // The system classifier on CI runners now and then hears nothing in a
        // run (or fails); a few tries tell that apart from a detector that never works.
        var regions: [SpeechRegion] = []
        var attempts: [String] = []
        for _ in 0..<3 where regions.isEmpty {
            do {
                regions = try MediaAnalyzer.speech(in: url)
                if regions.isEmpty { attempts.append("no speech") }
            } catch {
                attempts.append(String(describing: error))
            }
        }
        let region = try #require(regions.first, "Tries: \(attempts)")
        #expect(regions.count == 1, "\(regions)")
        #expect((1.2...2.6).contains(region.start.seconds), "\(region)")
        #expect((7.4...9.2).contains(region.end.seconds), "\(region)")
        #expect(region.confidence > 0.8)
    }

    @Test func tonesAndNoiseAreNotSpeech() throws {
        let fixtures = MediaAnalyzerTests.fixtures
        #expect(try MediaAnalyzer.speech(in: fixtures.appending(path: "cuts-25.mp4")).isEmpty)
        // The center channel of this clip is a beep; the noise elsewhere is left out.
        #expect(try MediaAnalyzer.speech(in: fixtures.appending(path: "dialogue-5.1.mp4")).isEmpty)
    }

    @Test func windowsMergeIntoRegions() {
        let regions = SpeechDetector.merge([
            (0, 1, 0.9), (0.5, 1.5, 0.8), (1, 2, 0.2), (1.5, 2.5, 0.1),
            (3, 4, 0.7), (3.5, 4.5, 0.9),
        ])
        #expect(regions.map { [$0.start.seconds, $0.end.seconds] } == [[0, 1.25], [3.25, 4.25]])
        #expect(regions.map(\.confidence) == [0.9, 0.9])
    }
}

struct VoiceBandFilterTests {
    func peak(ofSineAt frequency: Double, sampleRate: Double = 48_000) -> Float {
        var filter = VoiceBandFilter(sampleRate: sampleRate)
        let samples = (0..<Int(sampleRate)).map { Float(sin(2 * Double.pi * frequency * Double($0) / sampleRate)) }
        // Skip the first 0.2 s while the filter settles.
        return filter.process(samples)[Int(sampleRate * 0.2)...].map(abs).max()!
    }

    @Test func keepsSpeechFrequencies() {
        for frequency in [300.0, 1_000, 2_500] {
            #expect(peak(ofSineAt: frequency) > 0.85, "\(frequency) Hz")
        }
    }

    @Test func cutsRumbleAndHiss() {
        #expect(peak(ofSineAt: 40) < 0.1)
        #expect(peak(ofSineAt: 12_000) < 0.1)
    }

    @Test func worksAtLowSampleRates() {
        #expect(peak(ofSineAt: 1_000, sampleRate: 8_000) > 0.8)
    }
}

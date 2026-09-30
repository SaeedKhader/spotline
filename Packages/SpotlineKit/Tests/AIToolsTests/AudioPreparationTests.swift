import Foundation
import SubtitleCore
import Testing
@testable import AITools
@testable import MediaAnalysis

struct AudioPreparationTests {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "../../../../Fixtures")
        .standardizedFileURL

    /// dialogue-5.1.mp4: pink noise on every channel but the center, and a 440 Hz tone on the center from 1 to 2 s.
    @Test func surroundAudioKeepsOnlyTheDialogueChannelAt16kHz() throws {
        let audio = try MediaAnalyzer.prepareAudio(of: Self.fixtures.appending(path: "dialogue-5.1.mp4"))
        #expect(audio.source == .centerChannel)
        #expect(abs(audio.duration.seconds - 4) < 0.1)
        let chunk = try #require(audio.chunks.first)
        #expect(audio.chunks.count == 1, "Only the dialogue is speech")
        #expect(abs(chunk.start.seconds - 0.8) < 0.15)
        #expect(abs(chunk.end.seconds - 2.2) < 0.15)
        // 16 kHz: a second of audio is 16,000 samples.
        let second = audio.samples(from: MediaTime(value: 1, timescale: 1), to: MediaTime(value: 2, timescale: 1))
        #expect(second.count == 16_000)
        #expect((second.map(abs).max() ?? 0) > 0.3)
    }

    /// cuts-25.mp4: a tone from 0 to 1 s, silence, a quieter tone from 2 to 4 s.
    @Test func chunksEndAtPauses() throws {
        var chunker = AudioChunker()
        chunker.pauseSeconds = 0.5
        let audio = try MediaAnalyzer.prepareAudio(of: Self.fixtures.appending(path: "cuts-25.mp4"), chunking: chunker)
        #expect(audio.source == .mix)
        #expect(audio.chunks.count == 2)
        #expect(audio.chunks[0].start.seconds < 0.05)
        #expect(abs(audio.chunks[0].end.seconds - 1.2) < 0.15)
        #expect(abs(audio.chunks[1].start.seconds - 1.8) < 0.15)
        // A longer pause allowance keeps both in one chunk.
        let joined = try MediaAnalyzer.prepareAudio(of: Self.fixtures.appending(path: "cuts-25.mp4"))
        #expect(joined.chunks.count == 1)
    }

    @Test func longSpeechIsCutNearTheTarget() {
        // 70 s of "speech" (a tone that dips every 5 s).
        let rate = PreparedAudio.sampleRate
        let samples = (0..<(70 * rate)).map { index -> Float in
            let seconds = Double(index) / Double(rate)
            let dip = seconds.truncatingRemainder(dividingBy: 5) < 0.1 ? 0.2 : 1
            return Float(sin(2 * .pi * 200 * seconds) * 0.3 * dip)
        }
        let chunks = AudioChunker().chunks(of: samples, startingAt: .zero)
        #expect(chunks.count == 3)
        #expect(chunks.allSatisfy { $0.duration.seconds <= 30.5 })
        #expect(chunks.map(\.samples.count).reduce(0, +) >= samples.count - rate)
        // Starts follow on: each chunk begins where the previous one ended.
        for (previous, next) in zip(chunks, chunks.dropFirst()) {
            #expect(abs((next.start - previous.end).seconds) < 0.05)
        }
    }

    @Test func silenceMakesNoChunks() {
        #expect(AudioChunker().chunks(of: [Float](repeating: 0, count: 32_000), startingAt: .zero).isEmpty)
    }

    @Test func chunkTimesMapBackToTheMedia() {
        let chunk = AudioChunk(id: 0, start: MediaTime(value: 90, timescale: 1), samples: [])
        #expect(chunk.mediaTime(atOffset: 1.25) == MediaTime(value: 91_250, timescale: 1000))
    }

    @Test func opusRoundTrip() throws {
        let rate = PreparedAudio.sampleRate
        let tone = (0..<(2 * rate)).map { Float(sin(2 * .pi * 300 * Double($0) / Double(rate)) * 0.5) }
        let reported = Reported()
        let ogg = try OpusEncoder.oggOpus(tone) { reported.values.append($0) }
        #expect(reported.values.first == 0 && reported.values.last == 1)
        #expect(reported.values == reported.values.sorted(), "Encoding progress only goes forward")
        // About 24 kbit/s: 2 s is roughly 6 KB, far smaller than 64 KB of 16-bit PCM.
        #expect(ogg.count > 1_000 && ogg.count < 16_000)
        #expect(ogg.prefix(4) == Data("OggS".utf8))
        let url = FileManager.default.temporaryDirectory.appending(path: "opus-\(UUID().uuidString).ogg")
        try ogg.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let decoded = try MediaAnalyzer.prepareAudio(of: url)
        #expect(abs(decoded.duration.seconds - 2) < 0.1)
        #expect((decoded.chunks.first?.samples.map(abs).max() ?? 0) > 0.3)
    }

    @Test func preparedAudioIsCached() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AnalysisCache(directory: directory)
        let media = Self.fixtures.appending(path: "dialogue-5.1.mp4")
        let audio = try MediaAnalyzer.prepareAudio(of: media)
        cache.store(audio, for: media, audioStream: nil)
        let loaded = try #require(cache.preparedAudio(for: media, audioStream: nil))
        #expect(loaded.chunks.count == audio.chunks.count)
        #expect(loaded.chunks[0].start == audio.chunks[0].start)
        #expect(loaded.duration == audio.duration)
        let difference = zip(loaded.chunks[0].samples, audio.chunks[0].samples).map { abs($0 - $1) }.max() ?? 1
        #expect(difference < 0.001, "16-bit PCM keeps the samples")
        #expect(cache.preparedAudio(for: media, audioStream: 3) == nil)
    }
}

/// Collects progress values reported during a synchronous call.
private final class Reported {
    var values: [Double] = []
}

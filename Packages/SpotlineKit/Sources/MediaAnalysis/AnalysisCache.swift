import CryptoKit
import Foundation
import SubtitleCore

/// Keeps analyses on disk so a file is only decoded once. Entries are keyed by
/// the file's path, size and modification date, so an edited file is analyzed
/// again. Waveforms are also keyed by audio stream, so switching tracks redoes
/// only the waveform.
///
/// Project packages hold their own copy (docs/ARCHITECTURE.md, section 5); this
/// cache in ~/Library/Caches serves untitled projects and prepared audio.
public struct AnalysisCache: Sendable {
    /// Bumped whenever the analyzer's output changes, so old entries are ignored.
    public static let formatVersion = 4

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static var standard: AnalysisCache {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let app = Bundle.main.bundleIdentifier ?? "Spotline"
        return AnalysisCache(directory: caches.appending(path: app).appending(path: "MediaAnalysis"))
    }

    /// `audioStream` is the FFmpeg stream index asked for; nil means the main audio stream.
    public func waveform(for media: URL, audioStream: Int?) -> AudioAnalysis? {
        load(AudioAnalysis.self, kind: "waveform-\(audioStream.map(String.init) ?? "main")", for: media)
    }

    public func store(_ analysis: AudioAnalysis, for media: URL, audioStream: Int?) {
        save(analysis, kind: "waveform-\(audioStream.map(String.init) ?? "main")", for: media)
    }

    public func speech(for media: URL, audioStream: Int?) -> [SpeechRegion]? {
        load([SpeechRegion].self, kind: "speech-\(audioStream.map(String.init) ?? "main")", for: media)
    }

    public func store(speech: [SpeechRegion], for media: URL, audioStream: Int?) {
        save(speech, kind: "speech-\(audioStream.map(String.init) ?? "main")", for: media)
    }

    public func shotChanges(for media: URL) -> [MediaTime]? {
        load([MediaTime].self, kind: "shots", for: media)
    }

    public func store(shotChanges: [MediaTime], for media: URL) {
        save(shotChanges, kind: "shots", for: media)
    }

    /// Dialogue audio prepared for speech models, shared by transcription and speaker detection.
    /// Samples are kept as 16-bit PCM beside a small JSON index.
    public func preparedAudio(for media: URL, audioStream: Int?) -> PreparedAudio? {
        let kind = "audio16k-\(audioStream.map(String.init) ?? "main")"
        guard let index = load(PreparedAudioIndex.self, kind: kind, for: media),
              let pcmFile = entry(kind: kind, for: media)?.deletingPathExtension().appendingPathExtension("pcm"),
              let pcm = try? Data(contentsOf: pcmFile)
        else { return nil }
        var offset = 0
        var chunks: [AudioChunk] = []
        for chunk in index.chunks {
            let bytes = chunk.sampleCount * 2
            guard offset + bytes <= pcm.count else { return nil }
            let samples = pcm[pcm.startIndex + offset ..< pcm.startIndex + offset + bytes].withUnsafeBytes { raw in
                raw.bindMemory(to: Int16.self).map { Float($0) / Float(Int16.max) }
            }
            chunks.append(AudioChunk(id: chunks.count, start: chunk.start, samples: samples))
            offset += bytes
        }
        return PreparedAudio(source: index.source, audioStreamIndex: index.audioStreamIndex, duration: index.duration, chunks: chunks)
    }

    public func store(_ audio: PreparedAudio, for media: URL, audioStream: Int?) {
        let kind = "audio16k-\(audioStream.map(String.init) ?? "main")"
        guard let pcmFile = entry(kind: kind, for: media)?.deletingPathExtension().appendingPathExtension("pcm") else { return }
        var pcm = Data()
        for chunk in audio.chunks {
            let values = chunk.samples.map { Int16((min(max($0, -1), 1) * Float(Int16.max)).rounded()) }
            values.withUnsafeBytes { pcm.append(contentsOf: $0) }
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard (try? pcm.write(to: pcmFile, options: .atomic)) != nil else { return }
        let index = PreparedAudioIndex(
            source: audio.source, audioStreamIndex: audio.audioStreamIndex, duration: audio.duration,
            chunks: audio.chunks.map { .init(start: $0.start, sampleCount: $0.samples.count) }
        )
        save(index, kind: kind, for: media)
    }

    private struct PreparedAudioIndex: Codable {
        struct Chunk: Codable {
            var start: MediaTime
            var sampleCount: Int
        }

        var source: Waveform.Source
        var audioStreamIndex: Int
        var duration: MediaTime
        var chunks: [Chunk]
    }

    private func load<Value: Decodable>(_ type: Value.Type, kind: String, for media: URL) -> Value? {
        guard let file = entry(kind: kind, for: media), let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    private func save<Value: Encodable>(_ value: Value, kind: String, for media: URL) {
        guard let file = entry(kind: kind, for: media), let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    private func entry(kind: String, for media: URL) -> URL? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: media.path),
              let size = attributes[.size] as? Int,
              let modified = attributes[.modificationDate] as? Date
        else { return nil }
        let key = "\(Self.formatVersion)|\(kind)|\(media.standardizedFileURL.path)|\(size)|\(modified.timeIntervalSince1970)"
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(digest).json")
    }
}

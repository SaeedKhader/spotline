import CryptoKit
import Foundation

/// Keeps analyses on disk so a file is only decoded once. Entries are keyed by
/// the file's path, size and modification date, so an edited file is analyzed
/// again, and by the audio stream the waveform was read from.
///
/// Project packages will hold their own copy (docs/ARCHITECTURE.md, section 5);
/// until Spotline has project files, this cache lives in ~/Library/Caches.
public struct AnalysisCache: Sendable {
    /// Bumped whenever the analyzer's output changes, so old entries are ignored.
    public static let formatVersion = 2

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
    public func analysis(for media: URL, audioStream: Int? = nil) -> MediaAnalysis? {
        guard let file = entry(for: media, audioStream: audioStream), let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(MediaAnalysis.self, from: data)
    }

    public func store(_ analysis: MediaAnalysis, for media: URL, audioStream: Int? = nil) {
        guard let file = entry(for: media, audioStream: audioStream), let data = try? JSONEncoder().encode(analysis) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    private func entry(for media: URL, audioStream: Int?) -> URL? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: media.path),
              let size = attributes[.size] as? Int,
              let modified = attributes[.modificationDate] as? Date
        else { return nil }
        let key = "\(Self.formatVersion)|\(media.standardizedFileURL.path)|\(size)|\(modified.timeIntervalSince1970)|\(audioStream.map(String.init) ?? "main")"
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(digest).json")
    }
}

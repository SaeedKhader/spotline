import AITools
import Foundation
import MediaAnalysis
import SubtitleCore
import SubtitleFormats

/// A Spotline project (`Episode 1.spotline`): a package holding everything
/// about one video, so reopening it is instant and never analyzes, transcribes
/// or uploads anything again. Subtitle files stay imports and exports.
///
///     Episode 1.spotline/
///       project.json              manifest: the video, frame rate, QC preset, files, selection
///       subtitles.json            the cues being edited (the translation, when translating)
///       source.json               the source subtitles, when translating
///       Analysis/                 waveform-<stream>.json, speech-<stream>.json, shots.json
///       AI/                       transcript-<provider>-<stream>.json: the transcriber's raw words
public struct ProjectFile: Equatable, Sendable {
    /// Bumped when the package layout changes; older Spotlines refuse newer projects.
    public static let formatVersion = 1
    public static let fileExtension = "spotline"
    /// The exported type identifier (the app's Info.plist declares it).
    public static let typeIdentifier = "io.github.saeedkhader.spotline.project"

    public var media: MediaReference?
    public var frameRate: FrameRate
    public var track: SubtitleTrack
    public var sourceTrack: SubtitleTrack?
    /// The subtitle file last imported or exported, and the source's file.
    public var subtitleFile: StoredFile?
    public var sourceFile: StoredFile?
    public var qcPresetID: String?
    public var selectedCueID: Cue.ID?
    /// Where the playhead was, so the project reopens on the same frame.
    public var playhead: MediaTime?
    /// Cues whose text an agent wrote, for the AI tint's tooltip.
    public var agentWrittenCueIDs: [Cue.ID]
    public var analysis: StoredAnalysis
    public var transcripts: [StoredTranscript]

    public init(
        media: MediaReference? = nil, frameRate: FrameRate = .fps23_976, track: SubtitleTrack = SubtitleTrack(),
        sourceTrack: SubtitleTrack? = nil, subtitleFile: StoredFile? = nil, sourceFile: StoredFile? = nil,
        qcPresetID: String? = nil, selectedCueID: Cue.ID? = nil, playhead: MediaTime? = nil,
        agentWrittenCueIDs: [Cue.ID] = [], analysis: StoredAnalysis = StoredAnalysis(), transcripts: [StoredTranscript] = []
    ) {
        self.media = media
        self.frameRate = frameRate
        self.track = track
        self.sourceTrack = sourceTrack
        self.subtitleFile = subtitleFile
        self.sourceFile = sourceFile
        self.qcPresetID = qcPresetID
        self.selectedCueID = selectedCueID
        self.playhead = playhead
        self.agentWrittenCueIDs = agentWrittenCueIDs
        self.analysis = analysis
        self.transcripts = transcripts
    }

    /// A subtitle file on disk, by path and format.
    public struct StoredFile: Codable, Equatable, Sendable {
        public var path: String
        public var format: String

        public init(_ reference: SubtitleFileReference) {
            path = reference.url.path
            format = reference.format.rawValue
        }

        public var reference: SubtitleFileReference? {
            SubtitleFormat(rawValue: format).map { SubtitleFileReference(url: URL(fileURLWithPath: path), format: $0) }
        }
    }

    // MARK: Package

    public enum ReadError: LocalizedError, Equatable {
        case notAProject
        case newerVersion(Int)

        public var errorDescription: String? {
            switch self {
            case .notAProject: "It isn't a Spotline project, or it is damaged."
            case .newerVersion: "It was saved by a newer version of Spotline. Update Spotline to open it."
            }
        }
    }

    static let manifestName = "project.json"
    static let subtitlesName = "subtitles.json"
    static let sourceName = "source.json"
    static let analysisName = "Analysis"
    static let aiName = "AI"

    /// What `project.json` holds; the rest has files of its own.
    private struct Manifest: Codable {
        var formatVersion: Int
        var media: MediaReference?
        var frameRate: FrameRate
        var subtitleFile: StoredFile?
        var sourceFile: StoredFile?
        var qcPresetID: String?
        var selectedCueID: Cue.ID?
        var playhead: MediaTime?
        var agentWrittenCueIDs: [Cue.ID]?
    }

    /// Reads a package, leniently: a missing or damaged cache file only means
    /// that analysis runs again. A missing manifest or subtitles file is an error.
    public init(fileWrapper: FileWrapper) throws {
        guard fileWrapper.isDirectory, let files = fileWrapper.fileWrappers,
              let manifestData = files[Self.manifestName]?.regularFileContents,
              let manifest = try? Self.decoder.decode(Manifest.self, from: manifestData)
        else { throw ReadError.notAProject }
        guard manifest.formatVersion <= Self.formatVersion else { throw ReadError.newerVersion(manifest.formatVersion) }
        guard let trackData = files[Self.subtitlesName]?.regularFileContents,
              let track = try? Self.decoder.decode(SubtitleTrack.self, from: trackData)
        else { throw ReadError.notAProject }
        self.init(
            media: manifest.media, frameRate: manifest.frameRate, track: track,
            sourceTrack: files[Self.sourceName]?.regularFileContents.flatMap { try? Self.decoder.decode(SubtitleTrack.self, from: $0) },
            subtitleFile: manifest.subtitleFile, sourceFile: manifest.sourceFile, qcPresetID: manifest.qcPresetID,
            selectedCueID: manifest.selectedCueID, playhead: manifest.playhead,
            agentWrittenCueIDs: manifest.agentWrittenCueIDs ?? [],
            analysis: files[Self.analysisName].map(StoredAnalysis.init(directory:)) ?? StoredAnalysis(),
            transcripts: files[Self.aiName]?.fileWrappers?.values.compactMap { file in
                file.regularFileContents.flatMap { try? Self.decoder.decode(StoredTranscript.self, from: $0) }
            }.sorted { $0.fileName < $1.fileName } ?? []
        )
    }

    /// The package. `cache` keeps the encoded analysis and transcripts between saves,
    /// so autosaving a feature does not encode its waveform again every time.
    public func fileWrapper(cache: EncodingCache? = nil) throws -> FileWrapper {
        let manifest = Manifest(
            formatVersion: Self.formatVersion, media: media, frameRate: frameRate, subtitleFile: subtitleFile,
            sourceFile: sourceFile, qcPresetID: qcPresetID, selectedCueID: selectedCueID, playhead: playhead,
            agentWrittenCueIDs: agentWrittenCueIDs.isEmpty ? nil : agentWrittenCueIDs
        )
        var files: [String: FileWrapper] = [
            Self.manifestName: FileWrapper(regularFileWithContents: try Self.encoder.encode(manifest)),
            Self.subtitlesName: FileWrapper(regularFileWithContents: try Self.encoder.encode(track)),
        ]
        if let sourceTrack {
            let data = try cache?.sourceData(for: sourceTrack) ?? Self.encoder.encode(sourceTrack)
            files[Self.sourceName] = FileWrapper(regularFileWithContents: data)
        }
        let analysisFiles = try cache?.analysisFiles(for: analysis) ?? analysis.files()
        if !analysisFiles.isEmpty {
            files[Self.analysisName] = FileWrapper(directoryWithFileWrappers: analysisFiles.mapValues(FileWrapper.init(regularFileWithContents:)))
        }
        let transcriptFiles = try cache?.transcriptFiles(for: transcripts) ?? Self.files(for: transcripts)
        if !transcriptFiles.isEmpty {
            files[Self.aiName] = FileWrapper(directoryWithFileWrappers: transcriptFiles.mapValues(FileWrapper.init(regularFileWithContents:)))
        }
        return FileWrapper(directoryWithFileWrappers: files)
    }

    static func files(for transcripts: [StoredTranscript]) throws -> [String: Data] {
        try Dictionary(transcripts.map { ($0.fileName, try encoder.encode($0)) }, uniquingKeysWith: { _, last in last })
    }

    /// Keeps the last encoded analysis, transcripts and source subtitles; they change rarely, and are large.
    public final class EncodingCache: @unchecked Sendable {
        private var analysis: (StoredAnalysis, [String: Data])?
        private var transcripts: ([StoredTranscript], [String: Data])?
        private var source: (SubtitleTrack, Data)?

        public init() {}

        func sourceData(for value: SubtitleTrack) throws -> Data {
            if let (cached, data) = source, cached == value { return data }
            let data = try ProjectFile.encoder.encode(value)
            source = (value, data)
            return data
        }

        func analysisFiles(for value: StoredAnalysis) throws -> [String: Data] {
            if let (cached, files) = analysis, cached == value { return files }
            let files = try value.files()
            analysis = (value, files)
            return files
        }

        func transcriptFiles(for value: [StoredTranscript]) throws -> [String: Data] {
            if let (cached, files) = transcripts, cached == value { return files }
            let files = try ProjectFile.files(for: value)
            transcripts = (value, files)
            return files
        }
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder = JSONDecoder()

    // MARK: Where new projects go

    /// A project next to the video, named after it: “Episode 1.spotline”, or
    /// “Episode 1 2.spotline” when that name is taken.
    public static func suggestedURL(forMedia media: URL, fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let folder = media.deletingLastPathComponent()
        let name = media.deletingPathExtension().lastPathComponent
        var candidate = folder.appending(path: "\(name).\(fileExtension)")
        var number = 2
        while fileExists(candidate) {
            candidate = folder.appending(path: "\(name) \(number).\(fileExtension)")
            number += 1
        }
        return candidate
    }
}

/// Analyses of the video, kept so reopening the project reads nothing again.
/// Waveforms and speech are per audio stream ("main" is the default stream).
public struct StoredAnalysis: Equatable, Sendable {
    public var waveforms: [String: AudioAnalysis]
    public var speech: [String: [SpeechRegion]]
    public var shotChanges: [MediaTime]?

    public init(waveforms: [String: AudioAnalysis] = [:], speech: [String: [SpeechRegion]] = [:], shotChanges: [MediaTime]? = nil) {
        self.waveforms = waveforms
        self.speech = speech
        self.shotChanges = shotChanges
    }

    /// The key for an FFmpeg audio stream index; nil is the file's main audio stream.
    public static func key(forStream stream: Int?) -> String {
        stream.map(String.init) ?? "main"
    }

    public var isEmpty: Bool { waveforms.isEmpty && speech.isEmpty && shotChanges == nil }

    init(directory: FileWrapper) {
        self.init()
        for (name, file) in directory.fileWrappers ?? [:] {
            guard let data = file.regularFileContents, name.hasSuffix(".json") else { continue }
            let stem = String(name.dropLast(5))
            if stem == "shots" {
                shotChanges = try? ProjectFile.decoder.decode([MediaTime].self, from: data)
            } else if stem.hasPrefix("waveform-") {
                waveforms[String(stem.dropFirst(9))] = try? ProjectFile.decoder.decode(AudioAnalysis.self, from: data)
            } else if stem.hasPrefix("speech-") {
                speech[String(stem.dropFirst(7))] = try? ProjectFile.decoder.decode([SpeechRegion].self, from: data)
            }
        }
    }

    func files() throws -> [String: Data] {
        var files: [String: Data] = [:]
        for (key, analysis) in waveforms { files["waveform-\(key).json"] = try ProjectFile.encoder.encode(analysis) }
        for (key, regions) in speech { files["speech-\(key).json"] = try ProjectFile.encoder.encode(regions) }
        if let shotChanges { files["shots.json"] = try ProjectFile.encoder.encode(shotChanges) }
        return files
    }
}

/// A transcriber's raw result (the words with their times and speakers), kept so
/// transcribing again re-segments these words instead of sending the audio again.
public struct StoredTranscript: Codable, Equatable, Sendable {
    /// `AISettings.TranscriptionProvider` raw value, e.g. "elevenLabsScribe".
    public var provider: String
    public var audioStream: Int?
    /// The language asked for, nil when the provider detected it.
    public var language: String?
    public var words: [TranscribedWord]

    public init(provider: String, audioStream: Int?, language: String?, words: [TranscribedWord]) {
        self.provider = provider
        self.audioStream = audioStream
        self.language = language
        self.words = words
    }

    var fileName: String { "transcript-\(provider)-\(StoredAnalysis.key(forStream: audioStream)).json" }
}

/// Where the project's video is: a bookmark, which follows the file when it is
/// moved or renamed on its disk, plus its path and its path from the project,
/// which find it after it was copied to another Mac along with the project.
public struct MediaReference: Codable, Equatable, Sendable {
    public var bookmark: Data?
    /// True when `bookmark` is security-scoped (it must be resolved with that option).
    public var isSecurityScoped: Bool
    public var path: String
    /// From the project package's folder, e.g. "Episode 1.mkv" or "../Media/Episode 1.mkv".
    public var relativePath: String?

    public init(bookmark: Data?, isSecurityScoped: Bool, path: String, relativePath: String?) {
        self.bookmark = bookmark
        self.isSecurityScoped = isSecurityScoped
        self.path = path
        self.relativePath = relativePath
    }

    /// A reference to `url`, for a project saved at `projectURL` (nil while untitled).
    public init(url: URL, projectURL: URL?) {
        if let scoped = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            self.init(bookmark: scoped, isSecurityScoped: true, path: url.path, relativePath: nil)
        } else {
            self.init(bookmark: try? url.bookmarkData(), isSecurityScoped: false, path: url.path, relativePath: nil)
        }
        relativePath = projectURL.flatMap { Self.relativePath(from: $0.deletingLastPathComponent(), to: url) }
    }

    public var fileName: String { URL(fileURLWithPath: path).lastPathComponent }

    /// The video, if it can be found: by bookmark, then by path, then beside the project.
    /// `isStale` is true when the reference should be saved again (it was found elsewhere).
    public func resolve(projectURL: URL?, fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> (url: URL, isStale: Bool)? {
        if let bookmark {
            var stale = false
            let options: URL.BookmarkResolutionOptions = isSecurityScoped ? [.withSecurityScope, .withoutUI] : [.withoutUI]
            if let url = try? URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &stale),
               fileExists(url) {
                return (url, stale || url.path != path)
            }
        }
        let original = URL(fileURLWithPath: path)
        if fileExists(original) { return (original, false) }
        guard let folder = projectURL?.deletingLastPathComponent() else { return nil }
        for candidate in [relativePath.map { folder.appending(path: $0).standardizedFileURL }, folder.appending(path: fileName)] {
            if let candidate, fileExists(candidate) { return (candidate, true) }
        }
        return nil
    }

    /// `target`'s path from `folder`, with ".." where needed; nil across disks.
    static func relativePath(from folder: URL, to target: URL) -> String? {
        let base = folder.standardizedFileURL.pathComponents
        let path = target.standardizedFileURL.pathComponents
        // Across disks a relative path means nothing: the other disk may not be there.
        let volume = { (components: [String]) in
            components.count > 2 && components[1] == "Volumes" ? Array(components.prefix(3)) : ["/"]
        }
        guard volume(base) == volume(path) else { return nil }
        let common = zip(base, path).prefix { $0 == $1 }.count
        let ups = Array(repeating: "..", count: base.count - common)
        return (ups + path[common...]).joined(separator: "/")
    }
}

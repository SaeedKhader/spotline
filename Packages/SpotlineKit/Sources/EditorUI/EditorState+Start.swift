import AITools
import Foundation
import MediaAnalysis
import SubtitleCore
import SubtitleFormats

/// Where the start screen is.
public enum StartPhase: Sendable, Equatable {
    /// Recent projects and the drop area for a video.
    case chooseVideo
    /// A video is open: which subtitle to work from, then Translate or Just Edit.
    case chooseSubtitle
}

/// What the start screen works from.
public enum StartSubtitle: Hashable, Sendable {
    /// A text subtitle track inside the video, by FFmpeg stream index.
    case embedded(Int)
    /// A subtitle file.
    case file(URL)
    /// No subtitle: the audio is transcribed.
    case transcribe
}

/// One choice of the subtitle question.
public struct StartSubtitleChoice: Identifiable, Equatable, Sendable {
    public var subtitle: StartSubtitle
    public var title: String
    public var detail: String

    public var id: StartSubtitle { subtitle }
}

/// The start screen of a new project window: recent projects and a drop area; once a video
/// is in, which subtitle to work from (one found inside the video or beside it, one dropped,
/// or none, to transcribe), then Translate (the Translate page, which starts at once) or
/// Just Edit (the Edit page). A subtitle dropped alone opens the editor with it; a project
/// opens in its own window.
extension EditorState {
    /// Subtitle file extensions that can sit beside a video.
    static var subtitleExtensions: Set<String> {
        Set(SubtitleFormat.allCases.flatMap { [$0.fileExtension] + $0.alternativeExtensions }.map { $0.lowercased() })
    }

    /// The subtitle files beside `video` that are its: named like it, with a language or more
    /// before the extension ("Episode 1.en.srt"). The one named exactly like it first.
    static func subtitleFiles(beside video: URL, fileManager: FileManager = .default) -> [URL] {
        let folder = video.deletingLastPathComponent()
        let name = video.deletingPathExtension().lastPathComponent
        guard let files = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        let extensions = subtitleExtensions
        return files.map { $0.resolvingSymlinksInPath() }.filter { file in
            let base = file.deletingPathExtension().lastPathComponent
            return extensions.contains(file.pathExtension.lowercased()) && (base == name || base.hasPrefix(name + "."))
        }
        .sorted { first, second in
            let a = first.deletingPathExtension().lastPathComponent == name, b = second.deletingPathExtension().lastPathComponent == name
            return a != b ? a : first.lastPathComponent < second.lastPathComponent
        }
    }

    /// A video opened on the start screen: its subtitle is asked about next.
    func startSubtitleQuestion() {
        startPhase = .chooseSubtitle
        startSubtitleFiles = status.mediaURL.map { Self.subtitleFiles(beside: $0) } ?? []
    }

    /// The subtitle question's choices: tracks inside the video, files beside it or added, then transcribing.
    public var startSubtitleChoices: [StartSubtitleChoice] {
        var choices: [StartSubtitleChoice] = []
        for track in embeddedSubtitles where track.isText {
            choices.append(StartSubtitleChoice(
                subtitle: .embedded(track.streamIndex), title: "\(track.displayName) subtitle in the video",
                detail: track.isForced ? "Forced: only the lines in another language" : track.isHearingImpaired ? "With sound descriptions" : "Inside the video file"
            ))
        }
        for file in startSubtitleFiles {
            choices.append(StartSubtitleChoice(subtitle: .file(file), title: file.lastPathComponent, detail: "Beside the video"))
        }
        choices.append(StartSubtitleChoice(
            subtitle: .transcribe, title: "Transcribe the audio instead", detail: "It can mishear names and quiet lines, and you get more lines to check"
        ))
        return choices
    }

    /// The subtitle to work from unless the user picks another: a plain track or file, in the
    /// audio's language when that is known; nil when the video has none.
    public var recommendedStartSubtitle: StartSubtitle? {
        let spoken = selectedAudioTrack?.language.map(Languages.base)
        let plain = embeddedSubtitles.filter { $0.isText && !$0.isForced && !$0.isHearingImpaired }
        if let track = plain.first(where: { $0.language.map(Languages.base) == spoken }) ?? plain.first(where: \.isDefault) ?? plain.first {
            return .embedded(track.streamIndex)
        }
        if let file = startSubtitleFiles.first { return .file(file) }
        if let track = embeddedSubtitles.first(where: { $0.isText && !$0.isForced }) { return .embedded(track.streamIndex) }
        return nil
    }

    /// Files dropped or chosen on the start screen: a video opens (asking about its subtitle
    /// next), a subtitle becomes a choice of the question (or, with no video yet, opens the
    /// editor with it), a project opens in its own window. Returns the subtitle file added, if any.
    @discardableResult
    public func dropOnStartScreen(_ urls: [URL]) -> URL? {
        // The same file reads the same however it was reached (/var or /private/var).
        let files = urls.filter(\.isFileURL).map { $0.resolvingSymlinksInPath() }
        if let project = files.first(where: { $0.pathExtension == ProjectFile.fileExtension }) {
            openProjectFromStart?(project)
            return nil
        }
        let extensions = Self.subtitleExtensions
        let subtitles = files.filter { extensions.contains($0.pathExtension.lowercased()) }
        if let video = files.first(where: { !extensions.contains($0.pathExtension.lowercased()) }) {
            if startPhase == .chooseVideo || startPhase == nil { open(video) }
        } else if startPhase == .chooseVideo, let subtitle = subtitles.first {
            // A subtitle alone: the editor, with it.
            importSubtitles(from: subtitle)
            page = .edit
            startPhase = nil
            return nil
        }
        guard let subtitle = subtitles.first else { return nil }
        if !startSubtitleFiles.contains(subtitle) { startSubtitleFiles.insert(subtitle, at: 0) }
        return subtitle
    }

    /// Ends the start screen: brings in `subtitle`, then shows the Translate page and starts
    /// translating into `target`, or, with no target (Just Edit), shows the editor.
    public func finishStart(with subtitle: StartSubtitle?, translatingTo target: String?) {
        func proceed() {
            startPhase = nil
            guard let target else {
                page = .edit
                return
            }
            settings?.set(target, forKey: Self.targetLanguageKey)
            chosenPlanTicks = nil
            page = .translate
            startAIFlow(planTicks)
        }
        switch subtitle {
        case .embedded(let stream):
            importEmbeddedSubtitles(streamIndex: stream, savesCopy: false) { _ in proceed() }
        case .file(let url):
            importSubtitles(from: url)
            proceed()
        case .transcribe, nil:
            proceed()
        }
    }
}

extension EditorState {
    /// The start screen's Open…: a video, chosen in a panel.
    public func chooseStartVideo() {
        if let url = chooseMedia() { dropOnStartScreen([url]) }
    }

    /// The subtitle question's Choose a File…: returns the file added, to select it.
    public func chooseStartSubtitleFile() -> URL? {
        chooseSubtitlesToImport().flatMap { dropOnStartScreen([$0]) }
    }
}

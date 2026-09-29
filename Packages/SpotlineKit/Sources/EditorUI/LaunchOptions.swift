import Foundation

/// Process-level switches read once at launch.
public struct LaunchOptions: Sendable {
    /// Set by UI tests with `-UITestMode`: no animations, no audio, software
    /// decoding, deterministic state.
    public var isUITestMode: Bool
    /// Media to open at launch, from `-OpenMedia <path>`.
    public var mediaURL: URL?
    /// Subtitles to import at launch, from `-OpenSubtitles <path>`.
    public var subtitlesURL: URL?
    /// Source subtitles to translate from at launch, from `-OpenSource <path>`.
    public var sourceSubtitlesURL: URL?
    /// A project (`.spotline`) to open at launch, from `-OpenProject <path>`.
    public var projectURL: URL?
    /// Reuse cached media analysis. Off in UI tests and with `-NoAnalysisCache`,
    /// so analysis always runs (and can be watched filling in the timeline).
    public var usesAnalysisCache: Bool
    /// Turns on agent access at launch, from `-EnableAgentAccess` (UI tests).
    public var enablesAgentAccess: Bool

    public init(
        isUITestMode: Bool = false, mediaURL: URL? = nil, subtitlesURL: URL? = nil, sourceSubtitlesURL: URL? = nil,
        projectURL: URL? = nil, usesAnalysisCache: Bool? = nil, enablesAgentAccess: Bool = false
    ) {
        self.isUITestMode = isUITestMode
        self.mediaURL = mediaURL
        self.subtitlesURL = subtitlesURL
        self.sourceSubtitlesURL = sourceSubtitlesURL
        self.projectURL = projectURL
        self.usesAnalysisCache = usesAnalysisCache ?? !isUITestMode
        self.enablesAgentAccess = enablesAgentAccess
    }

    /// The same switches without the files to open, for every window after the first.
    public var withoutFiles: LaunchOptions {
        var options = self
        options.mediaURL = nil
        options.subtitlesURL = nil
        options.sourceSubtitlesURL = nil
        options.projectURL = nil
        return options
    }

    public static var current: LaunchOptions {
        let arguments = ProcessInfo.processInfo.arguments
        func path(after flag: String) -> URL? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return URL(fileURLWithPath: arguments[index + 1])
        }
        return LaunchOptions(
            isUITestMode: arguments.contains("-UITestMode"),
            mediaURL: path(after: "-OpenMedia"),
            subtitlesURL: path(after: "-OpenSubtitles"),
            sourceSubtitlesURL: path(after: "-OpenSource"),
            projectURL: path(after: "-OpenProject"),
            usesAnalysisCache: arguments.contains("-UITestMode") || arguments.contains("-NoAnalysisCache") ? false : true,
            enablesAgentAccess: arguments.contains("-EnableAgentAccess")
        )
    }
}

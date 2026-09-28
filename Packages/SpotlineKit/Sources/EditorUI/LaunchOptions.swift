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

    public init(isUITestMode: Bool = false, mediaURL: URL? = nil, subtitlesURL: URL? = nil) {
        self.isUITestMode = isUITestMode
        self.mediaURL = mediaURL
        self.subtitlesURL = subtitlesURL
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
            subtitlesURL: path(after: "-OpenSubtitles")
        )
    }
}

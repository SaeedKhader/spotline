import Foundation

/// Process-level switches read once at launch.
public struct LaunchOptions: Sendable {
    /// Set by UI tests with `-UITestMode`: no animations, no audio, software
    /// decoding, deterministic state.
    public var isUITestMode: Bool
    /// Media to open at launch, from `-OpenMedia <path>`.
    public var mediaURL: URL?

    public init(isUITestMode: Bool = false, mediaURL: URL? = nil) {
        self.isUITestMode = isUITestMode
        self.mediaURL = mediaURL
    }

    public static var current: LaunchOptions {
        let arguments = ProcessInfo.processInfo.arguments
        var mediaURL: URL?
        if let index = arguments.firstIndex(of: "-OpenMedia"), arguments.indices.contains(index + 1) {
            mediaURL = URL(fileURLWithPath: arguments[index + 1])
        }
        return LaunchOptions(isUITestMode: arguments.contains("-UITestMode"), mediaURL: mediaURL)
    }
}

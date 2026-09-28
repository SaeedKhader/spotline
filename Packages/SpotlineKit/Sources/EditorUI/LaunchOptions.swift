import Foundation

/// Process-level switches read once at launch.
public struct LaunchOptions: Sendable {
    /// Set by UI tests with `-UITestMode`: no animations, deterministic state.
    public var isUITestMode: Bool

    public init(isUITestMode: Bool = false) {
        self.isUITestMode = isUITestMode
    }

    public static var current: LaunchOptions {
        LaunchOptions(isUITestMode: ProcessInfo.processInfo.arguments.contains("-UITestMode"))
    }
}

import AgentBridge
import Foundation
import Observation

/// Whether AI agents can drive the editor (Settings › Agents), and the local
/// socket they connect through while it is on. Off by default; nothing listens
/// on the network, and only the user's own processes can open the socket.
@MainActor
@Observable
public final class AgentAccess {
    public enum State: Equatable, Sendable {
        case off
        case listening
        case failed(String)
    }

    public private(set) var state: State = .off
    public var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            settings?.set(isEnabled, forKey: Self.enabledKey)
            update()
        }
    }
    public let socketPath: String
    @ObservationIgnored private let run: @MainActor (AgentTool, [String: JSONValue]) async throws -> JSONValue
    @ObservationIgnored private let settings: UserDefaults?
    @ObservationIgnored private var server: AgentSocketServer?
    static let enabledKey = "AgentAccessEnabled"

    /// `enabled` overrides the stored setting (UI tests turn access on with `-EnableAgentAccess`).
    /// `run` runs a tool call on the project window agents work in.
    public init(
        settings: UserDefaults?, enabled: Bool? = nil, socketPath: String = AgentSocketPath.default,
        run: @escaping @MainActor (AgentTool, [String: JSONValue]) async throws -> JSONValue
    ) {
        self.run = run
        self.settings = settings
        self.socketPath = socketPath
        self.isEnabled = enabled ?? settings?.bool(forKey: Self.enabledKey) ?? false
        update()
    }

    /// The app's access setting, with the stored choice or the launch option. Agents
    /// work in the project window in front (see `EditorWorkspace.runAgentTool`).
    public convenience init(workspace: EditorWorkspace) {
        let options = workspace.launchOptions
        self.init(settings: options.isUITestMode ? nil : .standard, enabled: options.enablesAgentAccess ? true : nil) {
            [weak workspace] tool, arguments in
            guard let workspace else { throw AgentToolError("Spotline is quitting.") }
            return try await workspace.runAgentTool(tool, arguments: arguments)
        }
    }

    /// Stops listening, e.g. when the app quits.
    public func stop() {
        server?.stop()
        server = nil
    }

    private func update() {
        guard isEnabled else {
            stop()
            state = .off
            return
        }
        guard server == nil else { return }
        let run = run
        let mcp = MCPServer(version: Self.appVersion) { tool, arguments in
            try await run(tool, arguments)
        }
        let server = AgentSocketServer(path: socketPath) { line in await mcp.handle(line: line) }
        do {
            try server.start()
            self.server = server
            state = .listening
        } catch {
            state = .failed(String(describing: error))
        }
    }

    // MARK: Connecting agents

    /// The helper agents launch, inside the app bundle.
    public var helperPath: String {
        Bundle.main.bundleURL.appending(path: "Contents/MacOS/spotline-mcp").path
    }

    /// Adds Spotline to Claude Code for every project.
    public var claudeCodeCommand: String {
        "claude mcp add --scope user spotline -- \(Self.shellQuoted(helperPath))"
    }

    /// The `mcpServers` entry for Claude Desktop's claude_desktop_config.json.
    public var claudeDesktopConfig: String {
        let server: JSONValue = ["mcpServers": ["spotline": ["command": .string(helperPath)]]]
        let data = (try? JSONSerialization.data(
            withJSONObject: JSONSerialization.jsonObject(with: server.encoded()), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )) ?? server.encoded()
        return String(decoding: data, as: UTF8.self)
    }

    static func shellQuoted(_ path: String) -> String {
        path.allSatisfy { $0.isLetter || $0.isNumber || "/._-".contains($0) } ? path : "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }
}

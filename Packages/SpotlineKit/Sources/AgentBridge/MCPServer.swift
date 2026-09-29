import Foundation

/// A tool call that could not be done, with a message for the agent.
public struct AgentToolError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// The Model Context Protocol server side: JSON-RPC 2.0 messages in, responses
/// out, with the tools in `AgentTool`. It keeps no session state, so the helper
/// and the app can both answer, and a helper can reconnect to a restarted app.
public struct MCPServer: Sendable {
    public typealias Call = @Sendable (AgentTool, [String: JSONValue]) async throws -> JSONValue

    public static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    public static let serverName = "spotline"

    public let version: String
    let call: Call

    /// `call` runs a tool; it throws `AgentToolError` to report a failure to the agent.
    public init(version: String = "0.1.0", call: @escaping Call) {
        self.version = version
        self.call = call
    }

    public static let instructions = """
        Spotline is a subtitle editor. These tools read and edit the project open in its window, \
        as undoable steps the person can see and undo. Cues are referred to by the number get_cues shows \
        (1 is the first) or by id; numbers change when cues are added or removed, ids do not. Times are \
        SMPTE timecode (HH:MM:SS:FF, a frame's start) or HH:MM:SS,mmm. A cue's end is the first frame \
        without it. Transcription and translation fill cues directly; cleanup tools propose changes that \
        the person accepts or rejects in Spotline.
        """

    /// Answers one newline-free JSON-RPC message; nil for notifications, which get no answer.
    public func handle(line: Data) async -> Data? {
        let message: JSONValue
        do { message = try JSONValue.decode(line) } catch {
            return Self.error(id: .null, code: -32700, message: "Parse error").encoded()
        }
        return await handle(message)?.encoded()
    }

    public func handle(_ message: JSONValue) async -> JSONValue? {
        guard case .object(let request) = message, let method = request["method"]?.stringValue else {
            return Self.error(id: message["id"] ?? .null, code: -32600, message: "Invalid request")
        }
        // Notifications (no id), e.g. notifications/initialized, need no answer.
        guard let id = request["id"] else { return nil }
        let params = request["params"]?.objectValue ?? [:]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"]?.stringValue
            let version = asked.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil } ?? Self.supportedProtocolVersions[0]
            return Self.result(id: id, [
                "protocolVersion": .string(version),
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": .string(Self.serverName), "title": "Spotline", "version": .string(self.version)],
                "instructions": .string(Self.instructions),
            ])
        case "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            return Self.result(id: id, ["tools": .array(AgentTool.allCases.map(\.definition))])
        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return Self.error(id: id, code: -32602, message: "Missing tool name")
            }
            guard let tool = AgentTool(rawValue: name) else {
                return Self.error(id: id, code: -32602, message: "Unknown tool: \(name)")
            }
            let arguments = params["arguments"]?.objectValue ?? [:]
            do {
                let output = try await call(tool, arguments)
                return Self.result(id: id, Self.toolResult(output, isError: false))
            } catch {
                let text = (error as? AgentToolError)?.message ?? String(describing: error)
                return Self.result(id: id, Self.toolResult(.string(text), isError: true))
            }
        default:
            return Self.error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    /// A `tools/call` result: text content, as JSON for structured output.
    static func toolResult(_ output: JSONValue, isError: Bool) -> JSONValue {
        let text = output.stringValue ?? output.jsonString
        var result: [String: JSONValue] = ["content": [["type": "text", "text": .string(text)]], "isError": .bool(isError)]
        if case .object = output { result["structuredContent"] = output }
        return .object(result)
    }

    static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func error(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": JSONValue(code), "message": .string(message)]]
    }
}

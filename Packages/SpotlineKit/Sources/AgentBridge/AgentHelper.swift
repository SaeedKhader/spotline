import Darwin
import Foundation

/// The `spotline-mcp` helper: an MCP server on stdin/stdout that agents (Claude
/// Code, Claude Desktop) start, relaying tool calls to the running app over the
/// agent socket. It answers the handshake and the tool list itself, so an agent
/// connects even while Spotline is closed and gets a clear error from each call.
public enum AgentHelper {
    public static let unavailableMessage = """
        Spotline isn't running, or agent access is off. Open Spotline and turn on \
        Settings › Agents › Allow agents to control Spotline, then try again.
        """

    /// A server whose tool calls go to the app at `socketPath`.
    public static func server(socketPath: String = AgentSocketPath.default) -> MCPServer {
        let client = LockedClient(AgentSocketClient(path: socketPath))
        return MCPServer { tool, arguments in
            let request: JSONValue = [
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": .string(tool.rawValue), "arguments": .object(arguments)],
            ]
            let replyLine: Data
            do { replyLine = try client.send(request.encoded()) } catch AgentSocketError.system(let call, _) where call == "connect" {
                throw AgentToolError(unavailableMessage)
            } catch {
                throw AgentToolError("\(unavailableMessage) (\(error))")
            }
            let reply = try JSONValue.decode(replyLine)
            if let message = reply["error"]?["message"]?.stringValue { throw AgentToolError(message) }
            guard let result = reply["result"] else { throw AgentToolError("Spotline sent an unexpected reply.") }
            let text = result["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
            if result["isError"]?.boolValue == true { throw AgentToolError(text) }
            return result["structuredContent"] ?? .string(text)
        }
    }

    /// Serves MCP on stdin and stdout until stdin closes.
    public static func run(socketPath: String = AgentSocketPath.default) async {
        signal(SIGPIPE, SIG_IGN)
        let server = server(socketPath: socketPath)
        while let line = readLine(strippingNewline: true) {
            guard !line.allSatisfy(\.isWhitespace) else { continue }
            guard let reply = await server.handle(line: Data(line.utf8)) else { continue }
            FileHandle.standardOutput.write(reply + Data("\n".utf8))
        }
    }
}

/// One connection, used by one call at a time.
private final class LockedClient: @unchecked Sendable {
    private let lock = NSLock()
    private let client: AgentSocketClient

    init(_ client: AgentSocketClient) { self.client = client }

    func send(_ line: Data) throws -> Data {
        try lock.withLock { try client.send(line) }
    }
}

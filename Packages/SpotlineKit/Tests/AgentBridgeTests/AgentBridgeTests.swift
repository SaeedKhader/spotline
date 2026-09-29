import Foundation
import Testing
@testable import AgentBridge

struct JSONValueTests {
    @Test func roundTripsAndPrintsWholeNumbersWithoutAFraction() throws {
        let value: JSONValue = ["id": 7, "ratio": 0.5, "name": "cue", "flags": [true, nil], "nested": ["empty": [:]]]
        #expect(value.jsonString == #"{"flags":[true,null],"id":7,"name":"cue","nested":{"empty":{}},"ratio":0.5}"#)
        #expect(try JSONValue.decode(value.encoded()) == value)
        #expect(value["id"]?.intValue == 7)
        #expect(value["ratio"]?.intValue == nil)
    }
}

struct MCPServerTests {
    let server = MCPServer { tool, arguments in
        switch tool {
        case .getProject: return ["cue_count": 3]
        case .selectCue: throw AgentToolError("There is no cue \(arguments["cue"]?.intValue ?? 0); there are 3.")
        default: return .string("done")
        }
    }

    func send(_ message: JSONValue) async -> JSONValue? {
        await server.handle(message)
    }

    @Test func handshakeAgreesOnAVersionAndOffersTools() async throws {
        let reply = try #require(await send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-03-26"]]))
        #expect(reply["id"] == 1)
        #expect(reply["result"]?["protocolVersion"] == "2025-03-26")
        #expect(reply["result"]?["serverInfo"]?["name"] == "spotline")
        #expect(reply["result"]?["capabilities"]?["tools"] != nil)

        let unknownVersion = try #require(await send(["jsonrpc": "2.0", "id": 2, "method": "initialize", "params": ["protocolVersion": "1999-01-01"]]))
        #expect(unknownVersion["result"]?["protocolVersion"]?.stringValue == MCPServer.supportedProtocolVersions[0])
        // Notifications get no answer.
        #expect(await send(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
    }

    @Test func listsEveryToolWithAnObjectSchema() async throws {
        let reply = try #require(await send(["jsonrpc": "2.0", "id": "a", "method": "tools/list"]))
        let tools = try #require(reply["result"]?["tools"]?.arrayValue)
        #expect(tools.count == AgentTool.allCases.count)
        for tool in tools {
            #expect(tool["inputSchema"]?["type"] == "object")
            #expect(tool["description"]?.stringValue?.isEmpty == false)
        }
        let names = Set(tools.compactMap { $0["name"]?.stringValue })
        #expect(names.isSuperset(of: ["get_project", "get_cues", "set_cue_text", "seek", "run_qc", "start_ai_tool", "export_subtitles"]))
    }

    @Test func callsReturnTextAndStructuredContentOrAnError() async throws {
        let ok = try #require(await send(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "get_project", "arguments": [:]]]))
        #expect(ok["result"]?["isError"] == false)
        #expect(ok["result"]?["content"]?.arrayValue?.first?["text"] == #"{"cue_count":3}"#)
        #expect(ok["result"]?["structuredContent"]?["cue_count"] == 3)

        let failed = try #require(await send(["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "select_cue", "arguments": ["cue": 9]]]))
        #expect(failed["result"]?["isError"] == true)
        #expect(failed["result"]?["content"]?.arrayValue?.first?["text"] == "There is no cue 9; there are 3.")

        let unknown = try #require(await send(["jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": ["name": "format_disk"]]))
        #expect(unknown["error"]?["code"] == -32602)
        let method = try #require(await send(["jsonrpc": "2.0", "id": 6, "method": "resources/list"]))
        #expect(method["error"]?["code"] == -32601)
    }

    @Test func badJSONIsAParseError() async throws {
        let reply = try #require(await server.handle(line: Data("{not json".utf8)))
        #expect(try JSONValue.decode(reply)["error"]?["code"] == -32700)
    }
}

/// The helper and the app talking over a real socket.
struct AgentSocketTests {
    let path = FileManager.default.temporaryDirectory.appending(path: "sl-\(UUID().uuidString.prefix(8)).sock").path

    func appServer() -> AgentSocketServer {
        let mcp = MCPServer { tool, arguments in
            if tool == .setCueText { return ["text": arguments["text"] ?? .null] }
            throw AgentToolError("Only set_cue_text here.")
        }
        return AgentSocketServer(path: path) { await mcp.handle(line: $0) }
    }

    func call(_ helper: MCPServer, _ name: String, _ arguments: JSONValue = [:]) async throws -> JSONValue {
        let reply = try #require(await helper.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": .string(name), "arguments": arguments]]))
        return try #require(reply["result"])
    }

    @Test func helperRelaysToolCallsToTheApp() async throws {
        let server = appServer()
        try server.start()
        defer { server.stop() }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600, "Only the user may connect")

        let helper = AgentHelper.server(socketPath: path)
        let result = try await call(helper, "set_cue_text", ["cue": 1, "text": "Hello\nthere"])
        #expect(result["isError"] == false)
        #expect(result["structuredContent"]?["text"] == "Hello\nthere")
        // Errors come back as tool errors, over the same connection.
        let failed = try await call(helper, "get_project")
        #expect(failed["isError"] == true)
        #expect(failed["content"]?.arrayValue?.first?["text"] == "Only set_cue_text here.")
    }

    @Test func helperExplainsWhenTheAppIsNotListening() async throws {
        let helper = AgentHelper.server(socketPath: path)
        // The handshake works without the app, so the agent connects and can say what to do.
        let hello = try #require(await helper.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]]))
        #expect(hello["result"] != nil)
        let result = try await call(helper, "get_project")
        #expect(result["isError"] == true)
        #expect(result["content"]?.arrayValue?.first?["text"]?.stringValue == AgentHelper.unavailableMessage)

        // Once Spotline listens, the same helper gets through.
        let server = appServer()
        try server.start()
        defer { server.stop() }
        #expect(try await call(helper, "set_cue_text", ["text": "Now"])["isError"] == false)
    }

    @Test func helperReconnectsAfterTheAppRestarts() async throws {
        let helper = AgentHelper.server(socketPath: path)
        let first = appServer()
        try first.start()
        #expect(try await call(helper, "set_cue_text", ["text": "One"])["isError"] == false)
        first.stop()
        let second = appServer()
        try second.start()
        defer { second.stop() }
        #expect(try await call(helper, "set_cue_text", ["text": "Two"])["structuredContent"]?["text"] == "Two")
    }

    @Test func aSecondAppCannotTakeTheSocketButAStaleFileIsReplaced() throws {
        let first = appServer()
        try first.start()
        #expect(throws: AgentSocketError.inUse(path)) { try appServer().start() }
        first.stop()
        #expect(!FileManager.default.fileExists(atPath: path), "Stopping removes the socket file")

        // A file left behind by a Spotline that crashed.
        FileManager.default.createFile(atPath: path, contents: Data())
        let second = appServer()
        try second.start()
        #expect(second.isRunning)
        second.stop()
    }
}

import AgentBridge
import SpotlineAccessibility
import XCTest

/// Agents drive the running app through the MCP bridge: their edits show in the
/// cue list and undo like the person's own.
final class AgentBridgeUITests: XCTestCase {
    /// A short path in /tmp, shared by the test runner and the app (Unix socket paths are limited to 103 bytes).
    let socketPath = "/tmp/spotline-uitest-\(UUID().uuidString.prefix(8)).sock"

    @MainActor
    func launchAppForAgents() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment[AgentSocketPath.environmentKey] = socketPath
        app.launchArguments += ["-EnableAgentAccess"]
        return launchApp(openSubtitles: true, prepared: app)
    }

    /// Calls a tool the way an agent does, through the helper's MCP server.
    @MainActor
    func call(_ tool: String, _ arguments: JSONValue = [:]) async throws -> JSONValue {
        let helper = AgentHelper.server(socketPath: socketPath)
        var reply: JSONValue?
        // The app starts listening as it finishes launching.
        for _ in 0..<50 {
            reply = await helper.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": .string(tool), "arguments": arguments]])
            if reply?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue != AgentHelper.unavailableMessage { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        let result = try XCTUnwrap(reply?["result"])
        XCTAssertEqual(result["isError"], false, "\(tool) failed: \(result)")
        return result["structuredContent"] ?? .null
    }

    @MainActor
    func testAgentEditsShowInTheCueListAndUndo() async throws {
        let app = launchAppForAgents()
        let texts = app.cueCells(.text)
        XCTAssertTrue(texts.firstMatch.waitForExistence(timeout: 10), "No cue rows")

        let cues = try await call("get_cues")
        XCTAssertEqual(cues["total"], 3)
        XCTAssertEqual(cues["cues"]?.arrayValue?[1]["text"], "Second cue\nwith two lines")

        _ = try await call("set_cue_text", ["cue": 1, "text": "Written by an agent"])
        waitForValue(of: texts.element(boundBy: 0), toEqual: "Written by an agent")

        _ = try await call("seek", ["cue": 2])
        waitForValue(of: app.timecode, toEqual: "00:00:02:00")

        // The person undoes the agent's edit like their own.
        app.typeKey("z", modifierFlags: .command)
        waitForValue(of: texts.element(boundBy: 0), toEqual: "First cue")
    }

    @MainActor
    func testSettingsTurnAgentAccessOnAndShowHowToConnect() throws {
        let app = launchApp()
        app.typeKey(",", modifierFlags: .command)
        let agentsTab = app.toolbars.buttons["Agents"]
        XCTAssertTrue(agentsTab.waitForExistence(timeout: 10), "No Agents tab in Settings")
        agentsTab.click()

        let status = app.descendants(matching: .any)[AccessibilityID.AgentSettings.status]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertEqual(status.value as? String, "off", "Agent access is off by default")
        let command = app.staticTexts[AccessibilityID.AgentSettings.claudeCodeCommand]
        XCTAssertTrue((command.value as? String ?? command.label).contains("spotline-mcp"))

        app.checkBoxes[AccessibilityID.AgentSettings.enabled].click()
        waitForValue(of: status, toEqual: "listening")
        app.checkBoxes[AccessibilityID.AgentSettings.enabled].click()
        waitForValue(of: status, toEqual: "off")
    }
}

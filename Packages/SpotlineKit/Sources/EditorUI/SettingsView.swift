import AppKit
import SpotlineAccessibility
import SwiftUI

/// The Settings window: AI providers, and agent access.
public struct SettingsView: View {
    var editor: EditorState
    var agentAccess: AgentAccess

    public init(editor: EditorState, agentAccess: AgentAccess) {
        self.editor = editor
        self.agentAccess = agentAccess
    }

    public var body: some View {
        TabView {
            AISettingsView(editor: editor)
                .tabItem { Label("AI", systemImage: "sparkles") }
            AgentSettingsView(access: agentAccess)
                .tabItem { Label("Agents", systemImage: "point.3.connected.trianglepath.dotted") }
        }
    }
}

/// Settings › Agents: lets AI agents such as Claude Code drive Spotline over MCP (docs/AGENTS.md).
public struct AgentSettingsView: View {
    @Bindable var access: AgentAccess

    public init(access: AgentAccess) {
        self.access = access
    }

    public var body: some View {
        Form {
            Section {
                Toggle("Allow agents to control Spotline", isOn: $access.isEnabled)
                    .accessibilityIdentifier(AccessibilityID.AgentSettings.enabled)
                Label(statusText, systemImage: statusSymbol)
                    .foregroundStyle(statusColor)
                    .accessibilityIdentifier(AccessibilityID.AgentSettings.status)
                    .accessibilityValue(statusValue)
            } footer: {
                Text("Agents read the project and edit it with the same commands as you. Each edit is one step you can undo, and text they write is tinted until you edit it. Cleanup changes still wait for you to accept or reject them. Only apps running as you on this Mac can connect.")
                    .foregroundStyle(.secondary)
            }

            Section {
                snippet(access.claudeCodeCommand, id: AccessibilityID.AgentSettings.claudeCodeCommand,
                        copyID: AccessibilityID.AgentSettings.copyClaudeCodeCommand)
            } header: {
                Text("Claude Code")
            } footer: {
                Text("Run this once in Terminal, then ask Claude Code to work on the subtitles open in Spotline.")
                    .foregroundStyle(.secondary)
            }

            Section {
                snippet(access.claudeDesktopConfig, id: AccessibilityID.AgentSettings.claudeDesktopConfig,
                        copyID: AccessibilityID.AgentSettings.copyClaudeDesktopConfig)
            } header: {
                Text("Claude Desktop and other MCP clients")
            } footer: {
                Text("Add this server to the client's MCP configuration (for Claude Desktop, claude_desktop_config.json).")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
    }

    private func snippet(_ text: String, id: String, copyID: String) -> some View {
        HStack(alignment: .top) {
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier(id)
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .accessibilityIdentifier(copyID)
        }
    }

    private var statusText: String {
        switch access.state {
        case .off: "Off"
        case .listening: "Agents can connect"
        case .failed(let reason): "Agents can't connect: \(reason)"
        }
    }

    private var statusValue: String {
        switch access.state {
        case .off: "off"
        case .listening: "listening"
        case .failed: "failed"
        }
    }

    private var statusSymbol: String {
        switch access.state {
        case .off: "circle"
        case .listening: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch access.state {
        case .off: .secondary
        case .listening: .green
        case .failed: .orange
        }
    }
}

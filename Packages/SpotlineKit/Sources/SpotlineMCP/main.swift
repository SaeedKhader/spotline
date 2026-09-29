import AgentBridge

// Agents start this helper and talk MCP over stdin/stdout; it relays tool calls
// to the running Spotline (docs/AGENTS.md).
await AgentHelper.run()

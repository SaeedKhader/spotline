# Connecting AI agents

Spotline has a built-in [MCP](https://modelcontextprotocol.io) server, so agents such as Claude Code and Claude Desktop can read the open project and edit it: fix timings, rewrite lines, run QC, start transcription or translation, and export. The agent works through the same commands as the menus, so every edit shows up in the window as it happens and is one step you can undo.

## Turn it on

1. Open Spotline › Settings (Command-,) › **Agents**.
2. Turn on **Allow agents to control Spotline**. It is off by default, and the status line says when agents can connect.
3. Copy the command or configuration shown there and add it to your agent (below).

The agent can only reach Spotline while the app is running with this setting on. If it tries otherwise, each tool call says so.

## Claude Code

Run once in Terminal (Settings › Agents shows the exact path for your copy of Spotline):

```sh
claude mcp add --scope user spotline -- /Applications/Spotline.app/Contents/MacOS/spotline-mcp
```

Then, in any Claude Code session, ask for things like:

- "Look at the subtitles open in Spotline and list the cues with QC errors."
- "Fix the reading speed issues by rewording the lines, keeping the meaning."
- "Split cue 12 at 00:01:02:10 and move the second half to the top."
- "Transcribe the audio, then translate it into Arabic and export it next to the video as .ar.srt."

`claude mcp list` shows whether Spotline is connected. Remove it with `claude mcp remove --scope user spotline`.

## Claude Desktop and other MCP clients

Add this to the client's MCP configuration (for Claude Desktop, `~/Library/Application Support/Claude/claude_desktop_config.json`) and restart the client:

```json
{
  "mcpServers": {
    "spotline": {
      "command": "/Applications/Spotline.app/Contents/MacOS/spotline-mcp"
    }
  }
}
```

## Tools

| Tool | What it does |
|---|---|
| `get_project` | Media, subtitle file, language, translation source, playhead, selection, QC summary, AI status, undo/redo |
| `get_cues` | Cues with number, id, timecodes, text, position, speaker, issues, source text and proposed changes (`from`, `count` to page) |
| `get_qc_issues` | Every QC issue under the current preset, and the available presets |
| `get_ai_status` | The running AI tool, cleanup changes waiting for review, the last AI error |
| `list_commands` | Every editor command, whether it can run now, and toggles' state |
| `select_cue`, `set_cue_text`, `set_cue_timing`, `add_cue`, `delete_cue`, `split_cue`, `merge_cues`, `set_cue_position` | Cue edits, one undo step each |
| `seek`, `play`, `pause` | Playback |
| `open_media`, `import_subtitles`, `open_source_subtitles`, `export_subtitles` | Files, by absolute path |
| `run_qc` | Checks against a preset and returns the issues |
| `start_ai_tool` | `transcribe`, `translate`, `detect_speakers`, `mask_profanity`, `remove_hearing_impaired`, `fix_punctuation` |
| `run_command` | Any command from `list_commands` by id, e.g. `editing.undo`, `cue.fixOverlaps`, `navigation.nextIssue` |

Cues are named by the number `get_cues` shows (1 is the first) or by id. Numbers shift when cues are added or removed; ids don't. Times are SMPTE timecode (`HH:MM:SS:FF`, the frame's start) or `HH:MM:SS,mmm`, and a cue's end is the first frame without it.

## What agents can and can't do

- Each edit is one undo step, listed in Edit › Undo like your own. Text an agent writes is tinted, like other AI text, until you edit it.
- Transcription and translation fill empty cues and gaps directly, one undo step per batch, and never overwrite what you typed meanwhile.
- Cleanup tools (profanity, hearing-impaired text, punctuation) only propose changes. You accept or reject them in the cue list; agents can read the proposals but can't decide on them.
- Agents can't open file dialogs. They pass paths to `open_media`, `import_subtitles`, `open_source_subtitles` and `export_subtitles`. `open_media` refuses to drop unexported subtitle changes unless the agent passes `discard_unsaved_changes`.
- Errors that would show an alert when you do something (a file that can't be read, say) go back to the agent instead.

## How it works

Agents start `spotline-mcp`, a small helper inside the app bundle, and speak MCP to it over stdin and stdout. The helper answers the handshake and tool list itself and relays each tool call to the running app over a Unix domain socket at `~/Library/Application Support/Spotline/agent.sock` (mode 0600, in a 0700 folder). Nothing listens on the network, and only processes running as you can connect. The app runs each call on the main actor through `EditorState.runAgentTool`, the same code the menus use.

The tool catalog and protocol live in `Packages/SpotlineKit/Sources/AgentBridge`; the tools' behaviour is in `EditorUI/EditorState+Agent.swift`. `SPOTLINE_AGENT_SOCKET` overrides the socket path for the app and the helper (UI tests use it), and `-EnableAgentAccess` turns access on at launch.

To try the helper from a build, run it against a running Spotline and paste a request:

```sh
build/DerivedData/Build/Products/Debug/Spotline.app/Contents/MacOS/spotline-mcp
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_project","arguments":{}}}
```

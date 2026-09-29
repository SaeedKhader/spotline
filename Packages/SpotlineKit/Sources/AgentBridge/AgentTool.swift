/// The tools Spotline offers AI agents over MCP. Each one maps onto the editor's
/// commands (docs/ARCHITECTURE.md, section 1), so an agent's edits are the same
/// undoable steps as a person's. Names and arguments are public API.
public enum AgentTool: String, CaseIterable, Sendable {
    // Reading
    case getProject = "get_project"
    case getCues = "get_cues"
    case getQCIssues = "get_qc_issues"
    case getAIStatus = "get_ai_status"
    case listCommands = "list_commands"
    // Cues
    case selectCue = "select_cue"
    case setCueText = "set_cue_text"
    case setCueTiming = "set_cue_timing"
    case addCue = "add_cue"
    case deleteCue = "delete_cue"
    case splitCue = "split_cue"
    case mergeCues = "merge_cues"
    case setCuePosition = "set_cue_position"
    // Playback
    case seek
    case play
    case pause
    // Files
    case openMedia = "open_media"
    case importSubtitles = "import_subtitles"
    case openSourceSubtitles = "open_source_subtitles"
    case exportSubtitles = "export_subtitles"
    // Review, AI and everything else
    case runQC = "run_qc"
    case startAITool = "start_ai_tool"
    case runCommand = "run_command"

    public var description: String {
        switch self {
        case .getProject:
            "The open project: media (file, duration, frame rate, audio tracks), subtitle file, language, translation source, playhead, selected cue, cue count, QC preset and issue count, the running AI tool, and whether undo/redo are possible."
        case .getCues:
            "Cues in time order, each with its number, id, start and end (SMPTE timecode and HH:MM:SS,mmm), text, position, speaker, voices, QC issues, the translation choice when a line reads more than one way, whether AI wrote it, its source text when translating, and any change an AI tool proposes for it. Use from and count to page through long files."
        case .getQCIssues:
            "Quality-control issues for every cue under the current preset (reading speed, line length, durations, gaps, overlaps, shot changes, untranslated cues, glossary terms), plus the available presets."
        case .getAIStatus:
            "The AI tool running now and its progress, the changes a cleanup tool proposes for review, and the last AI error."
        case .listCommands:
            "Every editor command with its id, title, category, shortcut, and whether it can run now. Run one with run_command."
        case .selectCue:
            "Selects a cue, which also moves the playhead to its first frame."
        case .setCueText:
            "Replaces a cue's text as one undoable edit. Use \\n between lines; ASS/HTML-style tags such as <i> are kept."
        case .setCueTiming:
            "Changes a cue's start and/or end as one undoable edit. Clamped so the cue never overlaps its neighbours in the same position (keeping the preset's minimum gap)."
        case .addCue:
            "Adds a cue from start to end as one undoable edit and selects it. Fails if it would overlap another cue in the same position."
        case .deleteCue:
            "Deletes a cue as one undoable edit."
        case .splitCue:
            "Splits a cue in two at a time inside it (default: the middle frame). Two or more lines split between lines; one line at the word nearest its middle. One undoable edit."
        case .mergeCues:
            "Merges a cue with the next one: the text is joined line by line and the cue lasts until the next one ends. One undoable edit."
        case .setCuePosition:
            "Shows a cue at the bottom (default) or top of the picture, e.g. for a sign over dialogue. One undoable edit."
        case .seek:
            "Moves the playhead to a time or to a cue's first frame, and returns the frame shown."
        case .play:
            "Plays the media (rate 1 by default; negative plays backward)."
        case .pause:
            "Pauses playback."
        case .openMedia:
            "Opens a video or audio file. When the project window in front already has a video, it opens in a new project window, so nothing is lost; later tools work there."
        case .importSubtitles:
            "Replaces the cues with a subtitle file's (SRT, WebVTT, ASS/SSA, TTML/IMSC, EBU STL). Undoable."
        case .openSourceSubtitles:
            "Opens a subtitle file as the source to translate from. Empty cues become copies of the source's timing; existing cues are paired with the source cues they overlap."
        case .exportSubtitles:
            "Writes the cues to a file. The format follows the extension (.srt, .vtt, .ass, .ssa, .ttml, .stl)."
        case .runQC:
            "Checks every cue against a QC preset (default: the current one) and returns the issues. Choosing a preset keeps it for the project."
        case .startAITool:
            "Starts an AI tool in the background; poll get_ai_status for progress. transcribe and translate fill empty cues and gaps directly, one undoable edit per batch. Into gendered languages, translate flags lines that read more than one way (see translation_choice in get_cues); set_cue_text with one of its variants settles one. The cleanup tools (mask_profanity, remove_hearing_impaired, fix_punctuation) only propose changes, which the person reviews and accepts or rejects in Spotline. Cancel a running tool with run_command ai.cancel."
        case .runCommand:
            "Runs any editor command by id (see list_commands), e.g. editing.undo, editing.redo, cue.fixOverlaps, navigation.nextIssue, playback.stepForward. Commands that open a file dialog have their own tools, and accepting or rejecting AI proposals is left to the person."
        }
    }

    /// The JSON Schema of the tool's arguments.
    public var inputSchema: JSONValue {
        switch self {
        case .getProject, .getQCIssues, .getAIStatus, .listCommands, .pause:
            Self.schema([:])
        case .getCues:
            Self.schema([
                "from": ["type": "integer", "minimum": 1, "description": "The first cue number to return (default 1)."],
                "count": ["type": "integer", "minimum": 1, "maximum": 1000, "description": "How many cues to return (default 200)."],
            ])
        case .selectCue, .deleteCue, .mergeCues:
            Self.schema(["cue": Self.cue], required: ["cue"])
        case .setCueText:
            Self.schema(["cue": Self.cue, "text": ["type": "string", "description": "The new text."]], required: ["cue", "text"])
        case .setCueTiming:
            Self.schema(
                ["cue": Self.cue, "start": Self.time("The new start."), "end": Self.time("The new end (the first frame without the cue).")],
                required: ["cue"]
            )
        case .addCue:
            Self.schema(
                [
                    "start": Self.time("When the cue appears."), "end": Self.time("The first frame without the cue."),
                    "text": ["type": "string", "description": "The cue's text (default empty)."], "position": Self.position,
                ],
                required: ["start", "end"]
            )
        case .splitCue:
            Self.schema(["cue": Self.cue, "at": Self.time("Where the second cue starts (default: the middle).")], required: ["cue"])
        case .setCuePosition:
            Self.schema(["cue": Self.cue, "position": Self.position], required: ["cue", "position"])
        case .seek:
            Self.schema(["time": Self.time("The time to show."), "cue": Self.cue])
        case .play:
            Self.schema(["rate": ["type": "number", "description": "Playback speed: 1 is normal, 2 double, -1 backward."]])
        case .openMedia:
            Self.schema(
                [
                    "path": Self.path,
                    "discard_unsaved_changes": ["type": "boolean", "description": "Open even though subtitle changes have not been exported."],
                ],
                required: ["path"]
            )
        case .importSubtitles, .exportSubtitles:
            Self.schema(["path": Self.path], required: ["path"])
        case .openSourceSubtitles:
            Self.schema(
                [
                    "path": Self.path,
                    "target_language": ["type": "string", "description": "The translation's language as a BCP 47 code, e.g. \"ar\"."],
                ],
                required: ["path"]
            )
        case .runQC:
            Self.schema(["preset": ["type": "string", "description": "A preset id from get_qc_issues, e.g. \"netflix\"."]])
        case .startAITool:
            Self.schema(
                [
                    "tool": [
                        "type": "string",
                        "enum": .array(AgentAITool.allCases.map { .string($0.rawValue) }),
                        "description": "The tool to run.",
                    ],
                    "target_language": [
                        "type": "string", "description": "For translate: the language to translate into, as a BCP 47 code.",
                    ],
                ],
                required: ["tool"]
            )
        case .runCommand:
            Self.schema(["id": ["type": "string", "description": "The command id, e.g. \"editing.undo\"."]], required: ["id"])
        }
    }

    /// True for tools that only read.
    public var isReadOnly: Bool {
        switch self {
        case .getProject, .getCues, .getQCIssues, .getAIStatus, .listCommands: true
        default: false
        }
    }

    /// The tool as `tools/list` describes it.
    public var definition: JSONValue {
        [
            "name": .string(rawValue),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": ["readOnlyHint": .bool(isReadOnly), "destructiveHint": false, "openWorldHint": false],
        ]
    }

    private static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "object", "properties": .object(properties), "additionalProperties": false]
        if !required.isEmpty { schema["required"] = .array(required.map(JSONValue.string)) }
        return .object(schema)
    }

    private static let cue: JSONValue = [
        "type": ["integer", "string"],
        "description": "The cue's number as get_cues lists it (1 is the first), or its id.",
    ]
    private static let position: JSONValue = ["type": "string", "enum": ["bottom", "top"]]
    private static let path: JSONValue = ["type": "string", "description": "An absolute file path."]

    private static func time(_ description: String) -> JSONValue {
        ["type": "string", "description": .string("\(description) SMPTE timecode (HH:MM:SS:FF) or HH:MM:SS,mmm.")]
    }
}

/// The AI tools an agent can start.
public enum AgentAITool: String, CaseIterable, Sendable {
    case transcribe
    case translate
    case maskProfanity = "mask_profanity"
    case removeHearingImpaired = "remove_hearing_impaired"
    case fixPunctuation = "fix_punctuation"
}

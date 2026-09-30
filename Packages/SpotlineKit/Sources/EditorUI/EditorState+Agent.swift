import AgentBridge
import AITools
import EditorCommands
import Foundation
import QualityControl
import SubtitleCore
import SubtitleFormats

/// The agent bridge's tools (docs/AGENTS.md), run through the same commands and
/// edits as the menus, so each change is one undoable step the person can see.
/// Transcription and translation fill cues directly; cleanup tools propose
/// changes that only the person accepts or rejects.
extension EditorState {
    /// Commands an agent may not run with `run_command`: file dialogs (which have
    /// their own tools, taking a path) and the person's decisions on AI proposals.
    static let commandsAgentsCannotRun: Set<String> = [
        EditorCommand.openMedia.id, EditorCommand.importSubtitles.id, EditorCommand.importEmbeddedSubtitles.id,
        EditorCommand.exportSubtitles.id, EditorCommand.openSourceSubtitles.id, EditorCommand.importGlossary.id,
        EditorCommand.acceptChange.id, EditorCommand.rejectChange.id, EditorCommand.acceptAllChanges.id,
        EditorCommand.rejectAllChanges.id,
    ]

    /// Runs one tool call from an agent. Throws `AgentToolError` with a message for the agent.
    public func runAgentTool(_ tool: AgentTool, arguments: [String: JSONValue]) async throws -> JSONValue {
        recordErrorsForAgents()
        switch tool {
        case .getProject:
            return agentProject()
        case .getCues:
            let from = try agentInteger(arguments["from"], name: "from") ?? 1
            let count = min(try agentInteger(arguments["count"], name: "count") ?? 200, 1000)
            guard from >= 1, count >= 1 else { throw AgentToolError("from and count must be 1 or more.") }
            let cues = track.cues.enumerated().dropFirst(from - 1).prefix(count)
            return [
                "total": JSONValue(track.cues.count),
                "cues": .array(cues.map { agentJSON(for: $0.element, number: $0.offset + 1) }),
            ]
        case .getQCIssues:
            return agentQCReport()
        case .getAIStatus:
            return agentAIStatus()
        case .listCommands:
            return .array(EditorCommand.all.filter { !Self.commandsAgentsCannotRun.contains($0.id) }.map(agentJSON(for:)))

        case .selectCue:
            let cue = try agentCue(arguments["cue"])
            select(cue.id)
            return agentCueResult(cue.id)
        case .setCueText:
            let cue = try agentCue(arguments["cue"])
            guard let text = arguments["text"]?.stringValue else { throw AgentToolError("text is required.") }
            guard let index = track.cues.firstIndex(where: { $0.id == cue.id }) else { throw AgentToolError("The cue is gone.") }
            edit("Set Cue Text") { track in
                track.cues[index].text = text
                // Tinted like other AI text until the person edits it.
                track.cues[index].isAIGenerated = true
            }
            agentWrittenCues.insert(cue.id)
            return agentCueResult(cue.id)
        case .setCueTiming:
            let cue = try agentCue(arguments["cue"])
            let start = try agentTime(arguments["start"], name: "start") ?? cue.start
            let end = try agentTime(arguments["end"], name: "end") ?? cue.end
            guard start < end else { throw AgentToolError("The start must be before the end.") }
            setTiming(start: start, end: end, forCue: cue.id, actionName: "Set Cue Timing")
            let after = self.cue(withID: cue.id)
            guard after?.start != cue.start || after?.end != cue.end || (start == cue.start && end == cue.end) else {
                throw AgentToolError("There is no room for that timing: it would overlap a neighbouring cue.")
            }
            return agentCueResult(cue.id)
        case .addCue:
            guard let start = try agentTime(arguments["start"], name: "start"), let end = try agentTime(arguments["end"], name: "end") else {
                throw AgentToolError("start and end are required.")
            }
            let position = try agentPosition(arguments["position"]) ?? .bottom
            guard start < end else { throw AgentToolError("The start must be before the end.") }
            if let other = track.cues.first(where: { $0.position == position && $0.start < end && start < $0.end }) {
                throw AgentToolError("It would overlap cue \(agentNumber(of: other.id) ?? 0) (\(label(for: other.start)) to \(label(for: other.end))).")
            }
            var cue = Cue(start: start, end: end, text: arguments["text"]?.stringValue ?? "", position: position)
            if !cue.text.isEmpty { cue.isAIGenerated = true }
            edit("Add Cue") { track in track.cues.append(cue) }
            if !cue.text.isEmpty { agentWrittenCues.insert(cue.id) }
            select(cue.id)
            return agentCueResult(cue.id)
        case .deleteCue:
            let cue = try agentCue(arguments["cue"])
            deleteCue(cue.id)
            return ["deleted": .string(cue.id.uuidString), "total": JSONValue(track.cues.count)]
        case .splitCue:
            let cue = try agentCue(arguments["cue"])
            let at = try agentTime(arguments["at"], name: "at")
            guard splitCue(cue.id, at: at), let index = track.cues.firstIndex(where: { $0.id == cue.id }) else {
                throw AgentToolError("The cue is too short to split.")
            }
            return ["first": agentJSON(for: track.cues[index], number: index + 1), "second": agentJSON(for: track.cues[index + 1], number: index + 2)]
        case .mergeCues:
            let cue = try agentCue(arguments["cue"])
            guard let number = agentNumber(of: cue.id), number < track.cues.count else { throw AgentToolError("It is the last cue; there is none to merge with.") }
            mergeWithNext(cue.id)
            return agentCueResult(cue.id)
        case .setCuePosition:
            let cue = try agentCue(arguments["cue"])
            guard let position = try agentPosition(arguments["position"]) else { throw AgentToolError("position is required.") }
            setPosition(position, forCue: cue.id)
            return agentCueResult(cue.id)

        case .seek:
            guard hasMedia else { throw AgentToolError("No media is open.") }
            let target: MediaTime
            if let time = try agentTime(arguments["time"], name: "time") {
                target = time
            } else if arguments["cue"] != nil {
                target = try agentCue(arguments["cue"]).start
            } else {
                throw AgentToolError("Give a time or a cue.")
            }
            let frame = target.firstFrame(at: frameRate)
            seek(toFrame: frame)
            // The playhead is what the player reports, which follows shortly.
            for _ in 0..<100 where currentFrame != max(frame, 0) {
                try? await Task.sleep(for: .milliseconds(20))
            }
            return agentPlayhead()
        case .play:
            guard hasMedia else { throw AgentToolError("No media is open.") }
            let rate = arguments["rate"]?.doubleValue ?? 1
            guard rate != 0, abs(rate) <= 16 else { throw AgentToolError("rate must be between -16 and 16, and not 0.") }
            playback.play(rate: rate)
            return agentPlayhead()
        case .pause:
            perform(.pause)
            return agentPlayhead()

        case .openMedia:
            let url = try agentFile(arguments["path"])
            if hasMedia, hasUnsavedChanges, !track.cues.isEmpty, arguments["discard_unsaved_changes"]?.boolValue != true {
                throw AgentToolError("The subtitles have changes that were not exported. Export them first, or pass discard_unsaved_changes.")
            }
            let confirm = confirmReplacingSubtitles
            confirmReplacingSubtitles = { .discard }
            defer { confirmReplacingSubtitles = confirm }
            open(url)
            for _ in 0..<250 where status.mediaURL?.standardizedFileURL != url.standardizedFileURL {
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard status.mediaURL?.standardizedFileURL == url.standardizedFileURL else {
                throw AgentToolError("“\(url.lastPathComponent)” did not open. Is it a video or audio file?")
            }
            return agentProject()
        case .importSubtitles:
            let url = try agentFile(arguments["path"])
            try reportingErrorsToAgent { importSubtitles(from: url) }
            return agentProject()
        case .openSourceSubtitles:
            let url = try agentFile(arguments["path"])
            try reportingErrorsToAgent { openSourceSubtitles(from: url) }
            if let language = arguments["target_language"]?.stringValue { setTargetLanguage(language) }
            return agentProject()
        case .exportSubtitles:
            guard let path = arguments["path"]?.stringValue, path.hasPrefix("/") else { throw AgentToolError("path must be an absolute file path.") }
            let url = URL(fileURLWithPath: path)
            guard let format = SubtitleFormat(fileExtension: url.pathExtension) else {
                let known = SubtitleFormat.allCases.map { ".\($0.fileExtension)" }.joined(separator: ", ")
                throw AgentToolError("Spotline can't tell the format from “.\(url.pathExtension)”. Use one of \(known).")
            }
            try reportingErrorsToAgent { exportSubtitles(to: SubtitleFileReference(url: url, format: format)) }
            return ["path": .string(url.path), "format": .string(format.displayName), "cues": JSONValue(track.cues.count)]

        case .runQC:
            if let id = arguments["preset"]?.stringValue {
                guard QCPreset.named(id) != nil else {
                    throw AgentToolError("No preset “\(id)”. Presets: \(QCPreset.all.map(\.id).joined(separator: ", ")).")
                }
                selectQCPreset(id: id)
            }
            return agentQCReport()
        case .startAITool:
            guard let name = arguments["tool"]?.stringValue, let aiTool = AgentAITool(rawValue: name) else {
                throw AgentToolError("tool must be one of \(AgentAITool.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            return try startAITool(aiTool, targetLanguage: arguments["target_language"]?.stringValue)
        case .runCommand:
            guard let id = arguments["id"]?.stringValue, let command = EditorCommand.named(id) else {
                throw AgentToolError("No command “\(arguments["id"]?.stringValue ?? "")”. See list_commands.")
            }
            guard !Self.commandsAgentsCannotRun.contains(id) else {
                throw AgentToolError(
                    command.category == .ai
                        ? "Accepting and rejecting AI proposals is left to the person, in Spotline."
                        : "“\(command.title)” opens a dialog. Use open_media, import_subtitles, open_source_subtitles or export_subtitles with a path."
                )
            }
            guard canPerform(command) else { throw AgentToolError("“\(command.title)” can't run now.") }
            // Agents never see dialogs: clearing the transcript is undoable, and asked for.
            let confirmClearing = confirmClearingTranscript
            confirmClearingTranscript = { _ in true }
            defer { confirmClearingTranscript = confirmClearing }
            let done = try reportingErrorsToAgent { perform(command) }
            guard done else { throw AgentToolError("“\(command.title)” had nothing to do.") }
            return [
                "command": .string(id), "selected_cue": agentSelection(), "playhead": agentPlayhead(),
                "can_undo": JSONValue(canUndo), "can_redo": JSONValue(canRedo),
            ]
        }
    }

    // MARK: AI tools

    private func startAITool(_ tool: AgentAITool, targetLanguage: String?) throws -> JSONValue {
        let command: EditorCommand = switch tool {
        case .transcribe: .transcribe
        case .translate: .translateWithAI
        case .maskProfanity: .maskProfanity
        case .removeHearingImpaired: .removeHearingImpaired
        case .fixPunctuation: .fixPunctuation
        }
        guard canPerform(command) else {
            if let task = aiTask { throw AgentToolError("\(task.title) is running. Wait for it, or cancel it with run_command ai.cancel.") }
            if let review = pendingReview {
                throw AgentToolError("\(review.title) changes are waiting for the person to accept or reject them in Spotline.")
            }
            switch tool {
            case .transcribe:
                throw AgentToolError("No media is open.")
            case .translate: throw AgentToolError(isTranslating ? "Every cue with source text is translated already." : "There are no cues with text to translate.")
            default: throw AgentToolError("There are no cues for \(command.title).")
            }
        }
        // Agents never see dialogs: they translate as asked.
        let confirmUnsure = confirmTranslatingUnsureCues
        confirmTranslatingUnsureCues = { _ in .translateAnyway }
        defer { confirmTranslatingUnsureCues = confirmUnsure }
        if tool == .translate, let targetLanguage {
            if !isTranslating { useCuesAsSource() }
            setTargetLanguage(targetLanguage)
        }
        try reportingErrorsToAgent { _ = perform(command) }
        var result: [String: JSONValue] = ["tool": .string(tool.rawValue)]
        if let task = aiTask {
            result["running"] = .string(task.title)
            result["note"] = "Poll get_ai_status for progress. Results go into the cue list as they arrive."
        } else if let review = pendingReview {
            result["proposed_changes"] = JSONValue(review.changes.count)
            result["note"] = "The changes are shown for review; the person accepts or rejects them in Spotline."
        }
        return .object(result)
    }

    // MARK: Reports

    private func agentProject() -> JSONValue {
        var media: JSONValue = .null
        if let url = status.mediaURL {
            media = [
                "path": .string(url.path),
                "duration": status.duration.map { agentTimeJSON($0) } ?? .null,
                "frame_rate": .string(frameRate.description),
                "audio_tracks": .array(audioTracks.map { ["id": JSONValue($0.id), "name": .string($0.displayName)] }),
                "selected_audio_track": selectedAudioTrackID.map { JSONValue($0) } ?? .null,
            ]
        }
        var translation: JSONValue = .null
        if let sourceTrack {
            translation = [
                "source_file": JSONValue(sourceFile?.url.path),
                "source_language": .string(sourceTrack.languageCode),
                "target_language": .string(track.languageCode),
                "untranslated_cues": JSONValue(untranslatedCues.count),
            ]
        }
        let issueList = issues.values.flatMap { $0 }
        return [
            // The .spotline project the window saves to, null while untitled.
            "project_file": JSONValue(projectURL?.path),
            "media": media,
            "subtitles": [
                "file": JSONValue(subtitleFile?.url.path),
                "format": JSONValue(subtitleFile?.format.displayName),
                "language": .string(track.languageCode),
                "cue_count": JSONValue(track.cues.count),
                "unsaved_changes": JSONValue(hasUnsavedChanges),
            ],
            "translation": translation,
            "playhead": agentPlayhead(),
            "selected_cue": agentSelection(),
            "qc": [
                "preset": .string(qcPreset.id),
                "cues_with_issues": JSONValue(issues.count),
                "errors": JSONValue(issueList.filter { $0.severity == .error }.count),
                "warnings": JSONValue(issueList.filter { $0.severity == .warning }.count),
            ],
            "ai": [
                "running": aiTask.map { ["title": .string($0.title), "progress": JSONValue($0.fraction)] } ?? .null,
                "changes_awaiting_review": JSONValue(pendingReview?.changes.count ?? 0),
            ],
            "undo": undoManager.canUndo ? .string(undoManager.undoActionName) : .null,
            "redo": undoManager.canRedo ? .string(undoManager.redoActionName) : .null,
        ]
    }

    private func agentPlayhead() -> JSONValue {
        guard hasMedia else { return .null }
        return ["timecode": .string(timecode.description), "time": .string(Timestamp.format(currentTime)),
                "frame": JSONValue(currentFrame), "playing": JSONValue(isPlaying)]
    }

    private func agentSelection() -> JSONValue {
        guard let id = selectedCueID, let number = agentNumber(of: id) else { return .null }
        return ["number": JSONValue(number), "id": .string(id.uuidString)]
    }

    private func agentCueResult(_ id: Cue.ID) -> JSONValue {
        guard let number = agentNumber(of: id) else { return ["total": JSONValue(track.cues.count)] }
        return ["cue": agentJSON(for: track.cues[number - 1], number: number), "total": JSONValue(track.cues.count)]
    }

    func agentJSON(for cue: Cue, number: Int) -> JSONValue {
        var json: [String: JSONValue] = [
            "number": JSONValue(number),
            "id": .string(cue.id.uuidString),
            "start": agentTimeJSON(cue.start),
            "end": agentTimeJSON(cue.end),
            "text": .string(cue.text),
            "position": .string(cue.position.rawValue),
            "characters_per_second": JSONValue((cue.readingSpeed * 10).rounded() / 10),
        ]
        if let speaker = cue.speaker { json["speaker"] = .string(speaker) }
        if let voices = cue.voices { json["voices"] = .array(voices.map(JSONValue.string)) }
        if let flag = cue.flag {
            json["translation_choice"] = [
                "why": .string(flag.note),
                "confidence": JSONValue(flag.confidence),
                "decided": JSONValue(flag.isResolved),
                "variants": .array(flag.variants.map { .string($0.text) }),
                "chosen": JSONValue(flag.chosen + 1),
            ]
        }
        if cue.isAIGenerated == true { json["written_by_ai"] = true }
        if let source = sourceCues[cue.id] { json["source_text"] = .string(source.text) }
        if let found = issues[cue.id] { json["issues"] = .array(found.map { .string($0.message) }) }
        if let change = pendingReview?.change(forCue: cue.id) { json["proposed_change"] = agentJSON(for: change) }
        return .object(json)
    }

    private func agentJSON(for change: ProposedChange) -> JSONValue {
        let kind = switch change.kind {
        case .insert: "insert"
        case .update: "update"
        case .delete: "delete"
        }
        var json: [String: JSONValue] = ["kind": .string(kind), "cue_id": .string(change.cueID.uuidString), "text": .string(change.cue.text)]
        if let before = change.before { json["text_before"] = .string(before.text) }
        if let note = change.note { json["note"] = .string(note) }
        return .object(json)
    }

    private func agentTimeJSON(_ time: MediaTime) -> JSONValue {
        ["timecode": .string(Timecode(frameNumber: max(time.firstFrame(at: frameRate), 0), rate: frameRate).description),
         "time": .string(Timestamp.format(time))]
    }

    private func agentJSON(for command: EditorCommand) -> JSONValue {
        var json: [String: JSONValue] = [
            "id": .string(command.id), "title": .string(command.title), "category": .string(command.category.rawValue),
            "enabled": JSONValue(canPerform(command)),
        ]
        if let on = isOn(command) { json["on"] = JSONValue(on) }
        return .object(json)
    }

    private func agentQCReport() -> JSONValue {
        let items = issueList
        let limit = 500
        return [
            "preset": ["id": .string(qcPreset.id), "name": .string(qcPreset.name), "summary": .string(qcPreset.summary)],
            "presets": .array(QCPreset.all.map { ["id": .string($0.id), "name": .string($0.name)] }),
            "issue_count": JSONValue(items.count),
            "issues": .array(items.prefix(limit).map { item in
                [
                    "cue": JSONValue(item.cueNumber), "cue_id": .string(item.cueID.uuidString),
                    "start": .string(label(for: item.start)),
                    "severity": .string(item.issue.severity == .error ? "error" : "warning"),
                    "message": .string(item.issue.message),
                ]
            }),
            "truncated": JSONValue(items.count > limit),
        ]
    }

    private func agentAIStatus() -> JSONValue {
        var review: JSONValue = .null
        if let pending = pendingReview {
            review = [
                "title": .string(pending.title),
                "changes": .array(pending.changes.sorted { $0.cue.start < $1.cue.start }.map { change in
                    var json = agentJSON(for: change).objectValue ?? [:]
                    json["cue"] = agentNumber(of: change.cueID).map { JSONValue($0) } ?? .null
                    json["start"] = .string(label(for: change.cue.start))
                    return .object(json)
                }),
                "note": "The person accepts or rejects these in Spotline.",
            ]
        }
        return [
            "running": aiTask.map { ["title": .string($0.title), "progress": JSONValue($0.fraction)] } ?? .null,
            "review": review,
            "last_error": JSONValue(lastAgentVisibleError),
        ]
    }

    // MARK: Arguments

    private func agentNumber(of id: Cue.ID) -> Int? {
        track.cues.firstIndex { $0.id == id }.map { $0 + 1 }
    }

    /// A cue by its 1-based number or its ID.
    private func agentCue(_ value: JSONValue?) throws -> Cue {
        guard let value else { throw AgentToolError("cue is required.") }
        if let number = value.intValue ?? value.stringValue.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) {
            guard track.cues.indices.contains(number - 1) else {
                throw AgentToolError("There is no cue \(number); there are \(track.cues.count).")
            }
            return track.cues[number - 1]
        }
        if let id = value.stringValue.flatMap(UUID.init(uuidString:)), let cue = cue(withID: id) { return cue }
        throw AgentToolError("No cue \(value.stringValue ?? value.jsonString). Give its number from get_cues or its id.")
    }

    private func agentTime(_ value: JSONValue?, name: String) throws -> MediaTime? {
        guard let value, value != .null else { return nil }
        guard let text = value.stringValue, let time = time(from: text), time >= .zero else {
            throw AgentToolError("\(name) must be SMPTE timecode (HH:MM:SS:FF) or HH:MM:SS,mmm.")
        }
        return time
    }

    private func agentInteger(_ value: JSONValue?, name: String) throws -> Int? {
        guard let value, value != .null else { return nil }
        guard let int = value.intValue ?? value.stringValue.flatMap({ Int($0) }) else { throw AgentToolError("\(name) must be a whole number.") }
        return int
    }

    private func agentPosition(_ value: JSONValue?) throws -> CuePosition? {
        guard let value, value != .null else { return nil }
        guard let position = value.stringValue.flatMap(CuePosition.init(rawValue:)) else { throw AgentToolError("position must be bottom or top.") }
        return position
    }

    private func agentFile(_ value: JSONValue?) throws -> URL {
        guard let path = value?.stringValue, path.hasPrefix("/") else { throw AgentToolError("path must be an absolute file path.") }
        guard FileManager.default.fileExists(atPath: path) else { throw AgentToolError("There is no file at \(path).") }
        return URL(fileURLWithPath: path)
    }

    // MARK: Errors

    /// Runs `body` with errors going to the agent instead of an alert.
    private func reportingErrorsToAgent<Result>(_ body: () throws -> Result) throws -> Result {
        let report = reportError
        var failure: String?
        reportError = { title, error in
            if failure == nil { failure = "\(title) \(Self.message(for: error))" }
        }
        defer { reportError = report }
        let result = try body()
        if let failure { throw AgentToolError(failure) }
        return result
    }

    /// Keeps the last error the person was shown (such as a background AI tool failing), for get_ai_status.
    private func recordErrorsForAgents() {
        guard !isRecordingErrorsForAgents else { return }
        isRecordingErrorsForAgents = true
        let report = reportError
        reportError = { [weak self] title, error in
            self?.lastAgentVisibleError = "\(title) \(Self.message(for: error))"
            report(title, error)
        }
    }

    private static func message(for error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

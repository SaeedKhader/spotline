import AITools
import EditorCommands
import QualityControl
import SpotlineAccessibility
import SubtitleCore
import SwiftUI
import SubtitleTranslation

/// Every cue as an editable row: number, start and end, reading speed and the
/// text itself. Only rows on screen are built, so long files stay fast.
///
/// In translation mode each row shows the source cue's text (read-only, with
/// its glossary terms) beside the target text, each in its own direction
/// (Arabic and Hebrew right to left); the selected row lists translation memory
/// suggestions.
///
/// Click a row to select it (the playhead moves to it); Up and Down select the
/// previous and next cue, Return edits the text and Esc goes back to the list.
struct CueEditorList: View {
    let editor: EditorState
    @FocusState private var focusedText: Cue.ID?
    @FocusState private var isListFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if editor.track.cues.isEmpty {
                ContentUnavailableView {
                    Label("No Subtitles", systemImage: "captions.bubble")
                } description: {
                    Text("Import a subtitle file or add a cue at the playhead.")
                } actions: {
                    HStack {
                        CommandButton(command: .importSubtitles, editor: editor)
                        CommandButton(command: .addCue, editor: editor)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if editor.isIssuesPanelShown {
                VSplitView {
                    rows.frame(minHeight: 120)
                    IssuesPanel(editor: editor).frame(minHeight: 80, idealHeight: 180)
                }
            } else {
                rows
            }
            Divider()
            ReviewFooter(editor: editor)
        }
        .onChange(of: focusedText) { _, id in
            editor.isEditingText = id != nil
            if let id, id != editor.selectedCueID { editor.select(id) }
        }
        .onChange(of: editor.textFocusRequest) {
            // A just-added cue's row appears in this update; focus it in the next.
            let id = editor.selectedCueID
            Task { @MainActor in focusedText = id }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.CueList.root)
    }

    private var rows: some View {
        let directions = TextDirections(
            source: editor.isTranslating ? editor.sourceDirection : .leftToRight, target: editor.targetDirection
        )
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(listItems) { item in
                        Group {
                            switch item {
                            case .cue(let cue, let number):
                                CueRow(editor: editor, cue: cue, number: number, directions: directions, focusedText: $focusedText)
                            case .proposed(let change):
                                ProposedCueRow(editor: editor, change: change, direction: directions.target)
                            }
                        }
                        .id(item.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            editor.select(item.id)
                            isListFocused = true
                        }
                        Divider()
                    }
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($isListFocused)
            .onKeyPress(.upArrow) { editor.perform(.previousCue) ? .handled : .ignored }
            .onKeyPress(.downArrow) { editor.perform(.nextCue) ? .handled : .ignored }
            .onKeyPress(.return) {
                guard let id = editor.selectedCueID else { return .ignored }
                focusedText = id
                return .handled
            }
            .onChange(of: editor.selectedCueID) { _, id in
                guard let id else { return }
                withAnimation(editor.launchOptions.isUITestMode ? nil : .default) { proxy.scrollTo(id) }
            }
        }
    }

    /// The cues, with the new cues an AI tool proposes in their places.
    private var listItems: [CueListItem] {
        let cues = editor.track.cues.enumerated().map { CueListItem.cue($0.element, number: $0.offset + 1) }
        let inserts = editor.proposedInserts
        guard !inserts.isEmpty else { return cues }
        var items: [CueListItem] = []
        var next = inserts.startIndex
        for item in cues {
            guard case .cue(let cue, _) = item else { continue }
            while next < inserts.endIndex, inserts[next].cue.start < cue.start {
                items.append(.proposed(inserts[next]))
                next += 1
            }
            items.append(item)
        }
        items += inserts[next...].map { .proposed($0) }
        return items
    }
}

/// A row of the cue list: a cue, or a cue an AI tool proposes to add.
private enum CueListItem: Identifiable {
    case cue(Cue, number: Int)
    case proposed(ProposedChange)

    var id: Cue.ID {
        switch self {
        case .cue(let cue, _): cue.id
        case .proposed(let change): change.cueID
        }
    }
}

/// Which way source and target text run.
private struct TextDirections: Equatable {
    var source: TextDirection
    var target: TextDirection
}

extension TextDirection {
    var layoutDirection: LayoutDirection { self == .rightToLeft ? .rightToLeft : .leftToRight }
}

/// One cue: its number, start and end, reading speed, review warnings, text and actions.
private struct CueRow: View {
    let editor: EditorState
    let cue: Cue
    let number: Int
    let directions: TextDirections
    var focusedText: FocusState<Cue.ID?>.Binding
    @State private var isHovered = false

    private var isSelected: Bool { editor.selectedCueID == cue.id }
    private var isCurrent: Bool { editor.currentCueID == cue.id }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
                .padding(.top, 6)
                .accessibilityValue("\(number)")
                .accessibilityIdentifier(AccessibilityID.CueList.cell(cue.id, .number))
            VStack(alignment: .leading, spacing: 6) {
                TimeField(editor: editor, cue: cue, edge: .start)
                TimeField(editor: editor, cue: cue, edge: .end)
                speedAndIssues
            }
            VStack(alignment: .trailing, spacing: 6) {
                if editor.isTranslating {
                    HStack(alignment: .top, spacing: 8) {
                        SourceText(editor: editor, cueID: cue.id, source: editor.sourceCues[cue.id], direction: directions.source)
                            .frame(maxWidth: .infinity)
                        textEditor
                            .frame(maxWidth: .infinity)
                    }
                    if isSelected {
                        MemorySuggestions(editor: editor, cueID: cue.id, direction: directions.target)
                    }
                } else {
                    textEditor
                }
                if let change = editor.proposedChange(forCue: cue.id) {
                    ProposalBox(editor: editor, change: change, direction: directions.target)
                }
                if isHovered || isSelected {
                    actions
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(rowBackground)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.CueList.row(cue.id))
    }

    /// The cue's text (the target, in translation mode), typed in its language's direction.
    private var textEditor: some View {
                TextEditor(text: Binding(
                    get: { editor.cue(withID: cue.id)?.text ?? "" },
                    set: { editor.setText($0, forCue: cue.id) }
                ))
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(minHeight: 58)
                .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator))
                .focused(focusedText, equals: cue.id)
                .onKeyPress(.escape) {
                    focusedText.wrappedValue = nil
                    return .handled
                }
                .environment(\.layoutDirection, directions.target.layoutDirection)
                .accessibilityIdentifier(AccessibilityID.CueList.cell(cue.id, .text))
    }

    private var rowBackground: some View {
        Group {
            if case .delete = editor.proposedChange(forCue: cue.id)?.kind {
                Color.red.opacity(isSelected ? 0.2 : 0.1)
            } else if isSelected {
                Color.accentColor.opacity(0.16)
            } else if isCurrent {
                Color.primary.opacity(0.06)
            } else {
                Color.clear
            }
        }
    }

    private var speedAndIssues: some View {
        let speed = Int(cue.readingSpeed.rounded())
        let tooFast = editor.qcPreset.maxCharactersPerSecond.map { cue.readingSpeed > $0 } ?? false
        let issues = editor.issues[cue.id] ?? []
        return HStack(spacing: 6) {
            Text("\(speed)c/s")
                .font(.caption.monospacedDigit())
                .foregroundStyle(tooFast ? .orange : .secondary)
                .help("Reading speed in characters per second")
                .accessibilityValue("\(speed)")
                .accessibilityIdentifier(AccessibilityID.CueList.cell(cue.id, .readingSpeed))
            if let speakerID = cue.speakerID {
                SpeakerChip(editor: editor, speakerID: speakerID, cueID: cue.id)
            }
            if let tag = cue.addressee {
                // Filled in by the AI tools; a guess can be fixed in one click, never entered by hand.
                AddresseeChip(editor: editor, cue: cue, tag: tag)
            }
            if !issues.isEmpty {
                let messages = issues.map(\.message).joined(separator: "\n")
                let severity = issues.map(\.severity).max() ?? .warning
                IssueIcon(severity: severity)
                    .font(.caption)
                    .help(messages)
                    .accessibilityLabel("Needs review")
                    .accessibilityValue(messages)
                    .accessibilityIdentifier(AccessibilityID.CueList.cell(cue.id, .issues))
            }
        }
        .padding(.leading, 4)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Picker("Position", selection: Binding(
                get: { cue.position },
                set: { editor.setPosition($0, forCue: cue.id) }
            )) {
                Text("Default").tag(CuePosition.bottom)
                Text("Top").tag(CuePosition.top)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Show this cue at the bottom (default) or top of the picture")
            .accessibilityIdentifier(AccessibilityID.CueList.cell(cue.id, .position))
            RowButton(title: "Add Cue After", systemImage: "plus", id: AccessibilityID.CueList.action(cue.id, EditorCommand.addCue.id)) {
                editor.addCue(after: cue.id)
            }
            rowCommand(.splitCue, systemImage: "scissors")
            rowCommand(.mergeWithNext, systemImage: "arrow.right.and.line.vertical.and.arrow.left")
            rowCommand(.deleteCue, systemImage: "trash")
        }
        .font(.callout)
    }

    /// Selects this row's cue, then runs `command` on it.
    private func rowCommand(_ command: EditorCommand, systemImage: String) -> some View {
        RowButton(title: command.title, systemImage: systemImage, id: AccessibilityID.CueList.action(cue.id, command.id)) {
            editor.select(cue.id)
            editor.perform(command)
        }
        .disabled(command == .mergeWithNext && editor.track.cues.last?.id == cue.id)
    }
}

/// The source cue's text, read-only and selectable, with the glossary terms it uses.
private struct SourceText: View {
    let editor: EditorState
    let cueID: Cue.ID
    let source: Cue?
    let direction: TextDirection

    var body: some View {
        let text = source.map { SubtitleText.visibleLines(of: $0.text).joined(separator: "\n") } ?? ""
        VStack(alignment: .leading, spacing: 4) {
            Text(text.isEmpty ? "No source cue" : text)
                .font(.system(size: 15))
                .foregroundStyle(text.isEmpty ? .tertiary : .secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 50, alignment: .topLeading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                .help("Source")
                .accessibilityLabel("Source")
                .accessibilityValue(text)
                .accessibilityIdentifier(AccessibilityID.CueList.cell(cueID, .source))
            let matches = editor.glossaryMatches(for: cueID)
            if !matches.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(matches.enumerated()), id: \.offset) { index, match in
                        GlossaryChip(match: match)
                            .accessibilityIdentifier(AccessibilityID.CueList.glossaryTerm(cueID, index))
                    }
                }
            }
        }
        .environment(\.layoutDirection, direction.layoutDirection)
    }
}

/// "Winterfell → وينترفيل": green when the translation uses the agreed term, orange when not.
private struct GlossaryChip: View {
    let match: Glossary.Match

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: match.isUsed ? "checkmark" : "character.book.closed")
            Text("\(match.entry.source) → \(match.entry.target)")
                .lineLimit(1)
        }
        .font(.caption)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(match.isUsed ? Color.green : Color.orange)
        .background((match.isUsed ? Color.green : Color.orange).opacity(0.12), in: Capsule())
        .help(match.entry.note.isEmpty ? "Glossary" : "Glossary: \(match.entry.note)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(match.entry.source)
        .accessibilityValue("\(match.entry.target)\(match.isUsed ? "" : " (not used)")")
    }
}

/// Translation memory suggestions for the selected cue: click one to use it.
private struct MemorySuggestions: View {
    let editor: EditorState
    let cueID: Cue.ID
    let direction: TextDirection

    var body: some View {
        let matches = editor.memoryMatches(for: cueID)
        if !matches.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(matches.enumerated()), id: \.offset) { index, match in
                    // A tap target like the issues panel's rows, so the row's own tap doesn't take the click.
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(match.percent)
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(match.isExact ? Color.green : Color.yellow)
                            .frame(width: 38, alignment: .trailing)
                        Text(SubtitleText.visibleLines(of: match.entry.target).joined(separator: " / "))
                            .lineLimit(2)
                            .environment(\.layoutDirection, direction.layoutDirection)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { editor.useMemoryMatch(match, forCue: cueID) }
                    .help("Use this translation. Memory source: \(match.entry.source)")
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Memory match \(match.percent)")
                    .accessibilityValue(match.entry.target)
                    .accessibilityIdentifier(AccessibilityID.CueList.memoryMatch(cueID, index))
                    .accessibilityAction { editor.useMemoryMatch(match, forCue: cueID) }
                }
            }
            .font(.callout)
            .padding(6)
            .background(.background.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
        }
    }
}

private struct RowButton: View {
    let title: String
    let systemImage: String
    let id: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage).labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help(title)
        .accessibilityIdentifier(id)
    }
}

/// A cue's start (S) or end (E), editable by typing a timecode or HH:MM:SS,mmm.
private struct TimeField: View {
    enum Edge { case start, end }

    let editor: EditorState
    let cue: Cue
    let edge: Edge
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    private var time: MediaTime { edge == .start ? cue.start : cue.end }
    private var label: String { editor.label(for: time) }

    var body: some View {
        HStack(spacing: 0) {
            Text(edge == .start ? "S" : "E")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Divider().frame(height: 18)
            TextField(edge == .start ? "Start" : "End", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(.callout, design: .monospaced))
                .frame(width: 104)
                .padding(.horizontal, 6)
                .focused($isFocused)
                .onSubmit(commit)
                .onChange(of: isFocused) { _, focused in
                    editor.isEditingText = focused
                    if !focused { commit() }
                }
                .accessibilityIdentifier(AccessibilityID.CueList.cell(cue.id, edge == .start ? .inPoint : .outPoint))
        }
        .padding(.vertical, 4)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        .onAppear { draft = label }
        .onChange(of: label) { _, new in if !isFocused { draft = new } }
    }

    /// Applies a typed time, or restores the current one when it cannot be read or used.
    private func commit() {
        defer { draft = label }
        guard draft != label, let typed = editor.time(from: draft) else { return }
        switch edge {
        case .start: editor.setTiming(start: typed, end: cue.end, forCue: cue.id, actionName: "Set In")
        case .end: editor.setTiming(start: cue.start, end: typed, forCue: cue.id, actionName: "Set Out")
        }
    }
}

/// "N cues need review" and the QC preset, with buttons to open the issues
/// panel and step through the cues with issues.
private struct ReviewFooter: View {
    let editor: EditorState

    var body: some View {
        let count = editor.issues.count
        let summary = count == 0 ? "No cues need review" : count == 1 ? "1 cue needs review" : "\(count) cues need review"
        HStack {
            CommandButton(
                command: .toggleIssuesPanel, systemImage: editor.isIssuesPanelShown ? "chevron.down" : "chevron.up", editor: editor
            )
            Label(summary, systemImage: count == 0 ? "checkmark.circle" : "exclamationmark.circle")
                .foregroundStyle(count == 0 ? Color.secondary : Color.orange)
                .accessibilityValue(summary)
                .accessibilityIdentifier(AccessibilityID.CueList.reviewSummary)
            Text(editor.qcPreset.name)
                .foregroundStyle(.secondary)
                .help(editor.qcPreset.summary)
                .accessibilityLabel("QC preset")
                .accessibilityValue(editor.qcPreset.name)
                .accessibilityIdentifier(AccessibilityID.Issues.preset)
            Spacer()
            CommandButton(command: .previousIssue, systemImage: "chevron.up.circle", editor: editor)
            CommandButton(command: .nextIssue, systemImage: "chevron.down.circle", editor: editor)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Every issue under the QC preset, in cue order. Click one to select its cue.
private struct IssuesPanel: View {
    let editor: EditorState

    var body: some View {
        let items = editor.issueList
        Group {
            if items.isEmpty {
                Text("No issues under \(editor.qcPreset.name)")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(items) { item in
                                IssueRow(editor: editor, item: item)
                                    .id(item.id)
                            }
                        }
                    }
                    .onChange(of: editor.selectedCueID) { _, id in
                        guard let first = items.first(where: { $0.cueID == id }) else { return }
                        proxy.scrollTo(first.id)
                    }
                }
            }
        }
        .background(.background.opacity(0.4))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Issues.root)
    }
}

private struct IssueRow: View {
    let editor: EditorState
    let item: IssueListItem

    var body: some View {
        let isSelected = editor.selectedCueID == item.cueID
        HStack(spacing: 8) {
            IssueIcon(severity: item.issue.severity)
            Text("\(item.cueNumber)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
            Text(editor.label(for: item.start))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(item.issue.message)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { editor.select(item.cueID) }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Cue \(item.cueNumber)")
        .accessibilityValue(item.issue.message)
        .accessibilityIdentifier(AccessibilityID.Issues.item(item.cueID, item.offset))
        .accessibilityAction { editor.select(item.cueID) }
    }
}

/// Red for errors (no text, overlaps), orange for warnings.
private struct IssueIcon: View {
    let severity: QCIssue.Severity

    var body: some View {
        Image(systemName: severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(severity == .error ? Color.red : Color.orange)
    }
}

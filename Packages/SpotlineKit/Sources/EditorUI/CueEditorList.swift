import EditorCommands
import SpotlineAccessibility
import SubtitleCore
import SwiftUI

/// Every cue as an editable row: number, start and end, reading speed and the
/// text itself. Only rows on screen are built, so long files stay fast.
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
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(editor.track.cues.enumerated()), id: \.element.id) { index, cue in
                        CueRow(editor: editor, cue: cue, number: index + 1, focusedText: $focusedText)
                            .id(cue.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                editor.select(cue.id)
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
}

/// One cue: its number, start and end, reading speed, review warnings, text and actions.
private struct CueRow: View {
    let editor: EditorState
    let cue: Cue
    let number: Int
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
                .accessibilityIdentifier(AccessibilityID.CueList.cell(cue.id, .text))
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

    private var rowBackground: some View {
        Group {
            if isSelected {
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
        let tooFast = cue.readingSpeed > SubtitleGuidelines.maxCharactersPerSecond
        let issues = editor.issues[cue.id] ?? []
        return HStack(spacing: 6) {
            Text("\(speed)c/s")
                .font(.caption.monospacedDigit())
                .foregroundStyle(tooFast ? .orange : .secondary)
                .help("Reading speed in characters per second")
                .accessibilityValue("\(speed)")
                .accessibilityIdentifier(AccessibilityID.CueList.cell(cue.id, .readingSpeed))
            if !issues.isEmpty {
                let messages = issues.map(\.message).joined(separator: "\n")
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
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

/// "N cues need review", with buttons to step through them.
private struct ReviewFooter: View {
    let editor: EditorState

    var body: some View {
        let count = editor.issues.count
        let summary = count == 0 ? "No cues need review" : count == 1 ? "1 cue needs review" : "\(count) cues need review"
        HStack {
            Label(summary, systemImage: count == 0 ? "checkmark.circle" : "exclamationmark.circle")
                .foregroundStyle(count == 0 ? Color.secondary : Color.orange)
                .accessibilityValue(summary)
                .accessibilityIdentifier(AccessibilityID.CueList.reviewSummary)
            Spacer()
            CommandButton(command: .previousIssue, systemImage: "chevron.up", editor: editor)
            CommandButton(command: .nextIssue, systemImage: "chevron.down", editor: editor)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

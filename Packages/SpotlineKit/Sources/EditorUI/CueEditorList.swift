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
/// What there is to review is decided in the review sidebar; here a cue with
/// something open gets a dot beside its number.
///
/// Click a cue's text to edit it; click elsewhere on its row to select it (the
/// playhead moves to it) and leave the text; click empty space below the rows
/// to deselect. Up and Down select the previous and next cue, Return edits the
/// text, Esc goes back to the list and a second Esc deselects.
struct CueEditorList: View {
    let editor: EditorState
    @FocusState private var focusedText: Cue.ID?
    @FocusState private var isListFocused: Bool
    /// Which rows are whole on screen, so selecting one of them scrolls nothing.
    @State private var rowsOnScreen = RowsOnScreen()

    var body: some View {
        VStack(spacing: 0) {
            if editor.track.cues.isEmpty && editor.proposedInserts.isEmpty {
                CueListEmptyState(editor: editor)
            } else {
                rows
            }
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

    /// What changes from one moment to the next (the selection, the cue at the playhead, the
    /// issues, the proposed changes) is read here and handed to each row as its own part of it,
    /// so a row redraws only when something of its own cue changes, not with every edit and selection.
    private var rows: some View {
        let isTranslating = editor.isTranslating
        let directions = TextDirections(
            source: isTranslating ? editor.sourceDirection : .leftToRight, target: editor.targetDirection
        )
        let selected = editor.selectedCueID
        let current = editor.currentCueID
        let issues = editor.issues
        let sources = editor.sourceCues
        let review = editor.pendingReview
        let cast = editor.track.cast
        let lastID = editor.track.cues.last?.id
        let maxSpeed = editor.qcPreset.maxCharactersPerSecond
        return GeometryReader { geometry in ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(listItems) { item in
                        Group {
                            switch item {
                            case .cue(let cue, let number):
                                CueRow(
                                    editor: editor, cue: cue, number: number, directions: directions,
                                    isSelected: cue.id == selected, isCurrent: cue.id == current, isLast: cue.id == lastID,
                                    issues: issues[cue.id] ?? [], source: sources[cue.id], isTranslating: isTranslating,
                                    change: review?.change(forCue: cue.id), cast: cast, maxSpeed: maxSpeed,
                                    focusedText: $focusedText, leaveText: { isListFocused = true },
                                    editText: { editText(of: cue.id) }
                                )
                                .equatable()
                                .overlay { InFlightOverlay(editor: editor, cueID: cue.id) }
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
                        .onScrollVisibilityChange(threshold: 0.98) { isWhole in
                            if isWhole {
                                rowsOnScreen.whole.insert(item.id)
                            } else {
                                rowsOnScreen.whole.remove(item.id)
                                // Selecting a row makes it taller (its actions, its suggestions): if it no longer fits, show all of it.
                                if item.id == editor.selectedCueID, Date().timeIntervalSince(rowsOnScreen.selectedAt) < 0.5 {
                                    proxy.scrollTo(item.id)
                                }
                            }
                        }
                        Divider()
                    }
                }
                // The space under the last row (to the bottom of the list, 80 points at least):
                // a click there leaves the text and deselects.
                .padding(.bottom, 80)
                .frame(minHeight: geometry.size.height, alignment: .top)
                .background {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            editor.perform(.deselectCue)
                            isListFocused = true
                        }
                        .accessibilityHidden(true)
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
            // Esc in the text goes back to the list (the text editor passes Esc up to
            // here); Esc in the list deselects.
            .onKeyPress(.escape) {
                if editor.isEditingText || focusedText != nil {
                    focusedText = nil
                    isListFocused = true
                    return .handled
                }
                return editor.perform(.deselectCue) ? .handled : .ignored
            }
            .onChange(of: selected) { old, id in
                guard let id else { return }
                rowsOnScreen.selectedAt = Date()
                // A row that is whole on screen needs no scrolling (finding where a row is takes the list a walk from its top).
                guard !rowsOnScreen.whole.contains(id) else { return }
                // To a cue nearby the list slides; to one far away it jumps, or every row on the way would be built to slide past.
                let isNear = old.flatMap(editor.index(ofCue:)).flatMap { from in
                    editor.index(ofCue: id).map { abs($0 - from) <= 12 }
                } ?? false
                withAnimation(isNear && !editor.launchOptions.isUITestMode ? .default : nil) { proxy.scrollTo(id) }
            }
        } }
    }

    /// A click on the text of a cue that is not selected: selects it and puts the cursor where
    /// the click was. Only the selected row has a text editor (the others show their text as a
    /// plain line, which costs the list far less to lay out), so the editor is there one update later.
    private func editText(of id: Cue.ID) {
        let click = NSApp.currentEvent.flatMap { $0.type == .leftMouseUp || $0.type == .leftMouseDown ? $0.locationInWindow : nil }
        editor.select(id)
        DispatchQueue.main.async {
            focusedText = id
            placeCursor(at: click, tries: 5)
        }
    }

    /// Once the row's editor has the focus: the cursor at the click, or at the end of the text.
    private func placeCursor(at click: NSPoint?, tries: Int) {
        DispatchQueue.main.async {
            guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else {
                if tries > 1 { placeCursor(at: click, tries: tries - 1) }
                return
            }
            let end = (textView.string as NSString).length
            let index = click.map { textView.characterIndexForInsertion(at: textView.convert($0, from: nil)) } ?? end
            textView.setSelectedRange(NSRange(location: min(index, end), length: 0))
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

/// The rows whole on screen, and when the selection last changed. Not observed: no view redraws for it.
@MainActor
private final class RowsOnScreen {
    var whole: Set<Cue.ID> = []
    var selectedAt = Date.distantPast
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
struct TextDirections: Equatable {
    var source: TextDirection
    var target: TextDirection

    /// Rows mirror for a right-to-left track, except in translation mode,
    /// where the source column stays on the left and the target on the right.
    func rowLayout(isTranslating: Bool) -> LayoutDirection {
        !isTranslating && target == .rightToLeft ? .rightToLeft : .leftToRight
    }
}

extension TextDirection {
    var layoutDirection: LayoutDirection { self == .rightToLeft ? .rightToLeft : .leftToRight }
}

/// The shimmer over a row whose line a translator is working on now, in a view of its own so
/// the tool's progress reports redraw it and not the row.
private struct InFlightOverlay: View {
    let editor: EditorState
    let cueID: Cue.ID

    var body: some View {
        if editor.aiTask?.inFlight.contains(cueID) == true {
            InFlightShimmer()
                .allowsHitTesting(false)
                .accessibilityIdentifier(AccessibilityID.CueList.inFlight(cueID))
        }
    }
}

/// One cue: its number (with a dot when there is something to review), start and end, reading speed, text and actions.
///
/// Everything it shows comes from what the list hands it (compared by `==`), so it is drawn
/// again only when that changes.
private struct CueRow: View, Equatable {
    let editor: EditorState
    let cue: Cue
    let number: Int
    let directions: TextDirections
    let isSelected: Bool
    /// On screen at the playhead.
    let isCurrent: Bool
    let isLast: Bool
    let issues: [QCIssue]
    /// The source cue it translates, in translation mode.
    let source: Cue?
    let isTranslating: Bool
    /// What an AI tool proposes for the cue, while that is under review.
    let change: ProposedChange?
    let cast: [CastMember]
    /// The QC preset's reading speed limit.
    let maxSpeed: Double?
    var focusedText: FocusState<Cue.ID?>.Binding
    /// Gives the list the keyboard focus, as Esc leaves the text.
    let leaveText: () -> Void
    /// Selects the cue and starts typing in its text (a click on the text of a row that is not selected).
    let editText: () -> Void
    @State private var isHovered = false

    nonisolated static func == (lhs: CueRow, rhs: CueRow) -> Bool {
        lhs.isSelected == rhs.isSelected && lhs.isCurrent == rhs.isCurrent && lhs.isLast == rhs.isLast && lhs.number == rhs.number
            && lhs.isTranslating == rhs.isTranslating && lhs.maxSpeed == rhs.maxSpeed && lhs.directions == rhs.directions
            && lhs.cue == rhs.cue && lhs.source == rhs.source && lhs.issues == rhs.issues && lhs.change == rhs.change && lhs.cast == rhs.cast
    }

    /// What there is to review on the cue, for its dots: orange for a check
    /// (issues, words), purple for an AI suggestion (a choice, a change).
    private var reviewKinds: [String] {
        [
            !issues.isEmpty ? "issues" : nil,
            cue.unsureWords?.isEmpty == false ? "words" : nil,
            cue.flag?.isResolved == false ? "choice" : nil,
            change != nil ? "change" : nil,
        ].compactMap { $0 }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
                .padding(.top, 6)
                .accessibilityValue("\(number)")
                .accessibilityIdentifier(AccessibilityID.CueList.cell(cue.id, .number))
                // After the number's identifier, so the dots are their own element.
                .overlay(alignment: .topLeading) {
                    let kinds = reviewKinds
                    if !kinds.isEmpty {
                        VStack(spacing: 3) {
                            if kinds.contains("issues") || kinds.contains("words") { Circle().fill(Color.attentionTint).frame(width: 6, height: 6) }
                            if kinds.contains("choice") || kinds.contains("change") { Circle().fill(Color.aiTint).frame(width: 6, height: 6) }
                        }
                        .padding(.top, 10)
                        .padding(.leading, -2)
                        .help("To review in the review sidebar (\(EditorCommand.toggleReviewSidebar.menuHint("View")))")
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("To review")
                        .accessibilityValue(kinds.joined(separator: ", "))
                        .accessibilityIdentifier(AccessibilityID.CueList.cell(cue.id, .review))
                    }
                }
            VStack(alignment: .leading, spacing: 6) {
                TimeField(editor: editor, cue: cue, edge: .start, showsFrame: isHovered || isSelected, isEditable: isSelected) { editor.select(cue.id) }
                TimeField(editor: editor, cue: cue, edge: .end, showsFrame: isHovered || isSelected, isEditable: isSelected) { editor.select(cue.id) }
                speedAndIssues
                speakers
            }
            VStack(alignment: .trailing, spacing: 6) {
                if isTranslating {
                    HStack(alignment: .top, spacing: 8) {
                        SourceText(editor: editor, cue: cue, source: source, direction: directions.source, isSelectable: isSelected)
                            .frame(maxWidth: .infinity)
                        text
                            .frame(maxWidth: .infinity)
                    }
                    if isSelected {
                        MemorySuggestions(editor: editor, cueID: cue.id, direction: directions.target)
                    }
                } else {
                    text
                }
                if isHovered || isSelected {
                    actions
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // An Arabic or Hebrew track reads from the right: number and times go there too.
        .environment(\.layoutDirection, directions.rowLayout(isTranslating: isTranslating))
        .background(rowBackground)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.CueList.row(cue.id))
    }

    /// The cue's text: an editor in the selected row, a plain line that looks the same in the others.
    /// A text editor is an AppKit text view; one in every row made the list slow to lay out, scroll and jump in.
    @ViewBuilder private var text: some View {
        if isSelected {
            textEditor
                // The text cell automation finds (by its ID, with the text as its value) is an element
                // behind the editor, of the same kind as the plain line's in the other rows. The editor's
                // own element is the AppKit text view, which is not listed in the rows' order when it
                // is made after its row, and a container's value is not reported.
                .background {
                    Color.clear
                        .accessibilityElement()
                        .accessibilityLabel("Text")
                        .accessibilityValue(cue.text)
                        .accessibilityIdentifier(AccessibilityID.CueList.cell(cue.id, .text))
                }
                .overlay(alignment: .topTrailing) { aiMark }
        } else {
            // The text as it is typed, markup and all, as the editor shows it.
            Text(cue.text)
                .font(SpotlineStyle.cueFont)
                .foregroundStyle(cue.isAIGenerated == true ? AnyShapeStyle(Color.aiTint) : AnyShapeStyle(.primary))
                .frame(maxWidth: .infinity, alignment: .topLeading)
                // Where the editor's text is: its own padding, and the text view's inside it.
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .frame(minHeight: 58, alignment: .topLeading)
                .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: SpotlineStyle.cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: SpotlineStyle.cornerRadius).strokeBorder(.separator))
                .environment(\.layoutDirection, directions.target.layoutDirection)
                .contentShape(Rectangle())
                .onTapGesture(perform: editText)
                // An element of its own, so a cue with no text has its cell too.
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Text")
                .accessibilityValue(cue.text)
                .accessibilityAction(.default, editText)
                .accessibilityIdentifier(AccessibilityID.CueList.cell(cue.id, .text))
                .overlay(alignment: .topTrailing) { aiMark }
        }
    }

    /// Sparkles in the corner of text an AI tool wrote, until someone edits it.
    @ViewBuilder private var aiMark: some View {
        if cue.isAIGenerated == true {
            Image(systemName: "sparkles")
                .font(.caption2)
                .foregroundStyle(Color.aiTint)
                .padding(5)
                .help("Written by \(editor.aiToolName(for: cue)); edit it to make it yours")
                .accessibilityHidden(true)
        }
    }

    /// The cue's text (the target, in translation mode), typed in its language's direction.
    private var textEditor: some View {
                TextEditor(text: Binding(
                    get: { editor.cue(withID: cue.id)?.text ?? "" },
                    set: { editor.setText($0, forCue: cue.id) }
                ))
                .onChange(of: editor.wordSelectionRequest) { _, request in
                    // A word to check was clicked: select it once the editor has focus, to type over it.
                    // (Through AppKit: a SwiftUI selection binding put the cursor back at the start on every keystroke.)
                    guard let request, request.cueID == cue.id else { return }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(50))
                        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
                        let range = (textView.string as NSString).range(of: request.word, options: .caseInsensitive)
                        if range.location != NSNotFound { textView.setSelectedRange(range) }
                    }
                }
                .font(SpotlineStyle.cueFont)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(minHeight: 58)
                // Text an AI tool wrote is in the AI tint until someone edits it.
                .foregroundStyle(cue.isAIGenerated == true ? AnyShapeStyle(Color.aiTint) : AnyShapeStyle(.primary))
                .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: SpotlineStyle.cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: SpotlineStyle.cornerRadius).strokeBorder(.separator))
                .focused(focusedText, equals: cue.id)
                .onKeyPress(.escape) {
                    focusedText.wrappedValue = nil
                    // After this key press, so the list does not take the same Esc as a second one.
                    Task { @MainActor in leaveText() }
                    return .handled
                }
                .environment(\.layoutDirection, directions.target.layoutDirection)
    }

    private var rowBackground: some View {
        Group {
            if case .delete = change?.kind {
                Color.errorTint.opacity(isSelected ? 0.2 : 0.1)
            } else if isSelected {
                Color.accentColor.opacity(0.16)
            } else if isCurrent {
                Color.primary.opacity(0.06)
            } else {
                Color.clear
            }
        }
    }

    /// Who says the line, when the cue has a speaker or the audio told its voices.
    @ViewBuilder private var speakers: some View {
        let spoken = source ?? cue
        let names = EditorState.speakerNames(of: spoken, cast: cast)
        if !names.isEmpty {
            let text = names.joined(separator: ", ")
            // A waveform marks a cue matched to the audio: its speakers were heard, not typed.
            let heard = EditorState.isMatchedToAudio(spoken)
            HStack(spacing: 4) {
                Image(systemName: heard ? "waveform" : names.count > 1 ? "person.2" : "person")
                    .foregroundStyle(heard ? AnyShapeStyle(Color.aiTint) : AnyShapeStyle(.secondary))
                Text(text)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .font(.caption)
            .padding(.leading, 4)
            .help(heard ? "Matched to the audio. Says the line: \(text)" : "Says the line: \(text)")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(heard ? "Matched to the audio" : "Speaker")
            .accessibilityValue(text)
            .accessibilityIdentifier(AccessibilityID.CueList.cell(cue.id, .speaker))
        }
    }

    private var speedAndIssues: some View {
        let readingSpeed = cue.readingSpeed
        let speed = Int(readingSpeed.rounded())
        let tooFast = maxSpeed.map { readingSpeed > $0 } ?? false
        return HStack(spacing: 6) {
            Text("\(speed)c/s")
                .font(.caption.monospacedDigit())
                .foregroundStyle(tooFast ? Color.attentionTint : Color.secondary)
                .help("Reading speed in characters per second")
                .accessibilityValue("\(speed)")
                .accessibilityIdentifier(AccessibilityID.CueList.cell(cue.id, .readingSpeed))
            if cue.position == .top {
                Image(systemName: "arrow.up.to.line")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Shown at the top of the picture")
                    .accessibilityHidden(true)
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
            let isTop = cue.position == .top
            Button {
                editor.setPosition(isTop ? .bottom : .top, forCue: cue.id)
            } label: {
                Label(EditorCommand.togglePositionTop.title, systemImage: "arrow.up.to.line")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(isTop ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            }
            .buttonStyle(.borderless)
            .help(isTop ? "Shown at the top of the picture. Click to show it at the bottom." : EditorCommand.togglePositionTop.title)
            .accessibilityValue(isTop ? "top" : "bottom")
            .accessibilityIdentifier(AccessibilityID.CueList.cell(cue.id, .position))
            RowButton(title: "Add Cue After", systemImage: "plus", id: AccessibilityID.CueList.action(cue.id, EditorCommand.addCue.id)) {
                editor.addCue(after: cue.id)
            }
            rowCommand(.splitCue, systemImage: "scissors")
            rowCommand(.mergeWithNext, systemImage: "arrow.right.and.line.vertical.and.arrow.left")
            rowCommand(.deleteCue, systemImage: "trash")
            if let flag = cue.flag, flag.isResolved {
                VariantsMenu(editor: editor, cue: cue, flag: flag)
            }
        }
        .font(.callout)
    }

    /// Selects this row's cue, then runs `command` on it.
    private func rowCommand(_ command: EditorCommand, systemImage: String) -> some View {
        RowButton(title: command.title, systemImage: systemImage, id: AccessibilityID.CueList.action(cue.id, command.id)) {
            editor.select(cue.id)
            editor.perform(command)
        }
        .disabled(command == .mergeWithNext && isLast)
    }
}

/// The source cue's text, read-only and selectable, with the glossary terms it uses.
private struct SourceText: View {
    let editor: EditorState
    let cue: Cue
    let source: Cue?
    let direction: TextDirection
    /// Its text can be selected (to copy) in the selected row; selectable text costs more to lay out.
    var isSelectable = true

    var body: some View {
        let text = source.map { SubtitleText.visibleLines(of: $0.text).joined(separator: "\n") } ?? ""
        VStack(alignment: .leading, spacing: 4) {
            sourceLine(text)
                .frame(maxWidth: .infinity, minHeight: 50, alignment: .topLeading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: SpotlineStyle.cornerRadius))
                .help("Source")
                .accessibilityLabel("Source")
                .accessibilityValue(text)
                .accessibilityIdentifier(AccessibilityID.CueList.cell(cue.id, .source))
            let matches = editor.glossaryMatches(for: cue)
            if !matches.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(matches.enumerated()), id: \.offset) { index, match in
                        GlossaryChip(match: match)
                            .accessibilityIdentifier(AccessibilityID.CueList.glossaryTerm(cue.id, index))
                    }
                }
            }
        }
        .environment(\.layoutDirection, direction.layoutDirection)
    }
}

extension SourceText {
    @ViewBuilder fileprivate func sourceLine(_ text: String) -> some View {
        let line = Text(text.isEmpty ? "No source cue" : text)
            .font(SpotlineStyle.cueFont)
            .foregroundStyle(text.isEmpty ? .tertiary : .secondary)
        if isSelectable { line.textSelection(.enabled) } else { line }
    }
}

/// "Winterfell → وينترفيل": plain with a tick when the translation uses the agreed term, orange when not.
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
        .foregroundStyle(match.isUsed ? Color.secondary : Color.attentionTint)
        .background((match.isUsed ? Color.secondary : Color.attentionTint).opacity(0.12), in: Capsule())
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
                            .foregroundStyle(match.isExact ? Color.primary : Color.secondary)
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
            .background(.background.opacity(0.4), in: RoundedRectangle(cornerRadius: SpotlineStyle.cornerRadius))
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

/// A cue's start (S) or end (E), editable by typing a timecode or HH:MM:SS,mmm
/// (in the cue list, and in an issue card being edited).
struct TimeField: View {
    enum Edge { case start, end }

    let editor: EditorState
    let cue: Cue
    let edge: Edge
    /// The field's box shows only on the hovered or selected row, or while typing.
    let showsFrame: Bool
    /// False in a cue list row that is not selected: the time shows as plain text (a text field is
    /// an AppKit view, and two in every row made the list slow), and a click selects the row and types here.
    var isEditable = true
    /// Selects the row, for a click on the time while it is plain text.
    var activate: () -> Void = {}
    @State private var draft = ""
    /// A click on the plain text asked to type here, once the field is there.
    @State private var wantsFocus = false
    @FocusState private var isFocused: Bool

    private var time: MediaTime { edge == .start ? cue.start : cue.end }
    private var label: String { editor.label(for: time) }

    var body: some View {
        HStack(spacing: 0) {
            Text(edge == .start ? "S" : "E")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Divider().frame(height: 18).opacity(showsFrame || isFocused ? 1 : 0)
            if isEditable {
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
                    .onAppear {
                        guard wantsFocus else { return }
                        wantsFocus = false
                        DispatchQueue.main.async { isFocused = true }
                    }
                    // Removed while focused (an issue card's edit finished, another row selected): typing is over.
                    .onDisappear { if isFocused { editor.isEditingText = false } }
                    .accessibilityIdentifier(AccessibilityID.CueList.cell(cue.id, edge == .start ? .inPoint : .outPoint))
            } else {
                Text(label)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .frame(width: 104, alignment: .leading)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        wantsFocus = true
                        activate()
                    }
                    .accessibilityValue(label)
                    .accessibilityIdentifier(AccessibilityID.CueList.cell(cue.id, edge == .start ? .inPoint : .outPoint))
            }
        }
        .padding(.vertical, 4)
        .background(.background.opacity(showsFrame || isFocused ? 0.6 : 0), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator.opacity(showsFrame || isFocused ? 1 : 0)))
        // Timecodes read left to right in every language.
        .environment(\.layoutDirection, .leftToRight)
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

/// Red for errors (no text, overlaps), orange for warnings.
private struct IssueIcon: View {
    let severity: QCIssue.Severity

    var body: some View {
        Image(systemName: severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(severity == .error ? Color.errorTint : Color.attentionTint)
    }
}

/// The empty cue list: what to do first, pointing at the menu commands.
private struct CueListEmptyState: View {
    let editor: EditorState

    var body: some View {
        let hint = editor.hasMedia
            ? "Transcribe the dialogue (\(EditorCommand.transcribe.menuHint("AI"))) or import a subtitle file (\(EditorCommand.importSubtitles.menuHint("File")))."
            : "Open a video first: drop it on the player (\(EditorCommand.openMedia.menuHint("File")))."
        ContentUnavailableView {
            Label("No Subtitles", systemImage: "captions.bubble")
        } description: {
            Text(hint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityValue(hint)
        .accessibilityIdentifier(AccessibilityID.CueList.emptyState)
    }
}

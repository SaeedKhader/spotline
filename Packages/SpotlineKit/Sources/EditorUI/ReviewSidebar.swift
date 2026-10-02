import AITools
import EditorCommands
import QualityControl
import SpotlineAccessibility
import SubtitleCore
import SubtitleTranslation
import SwiftUI

/// Right of the video (View › Show Review): every thing to review as a card, in
/// time order. Filter chips pick a kind (none picked: everything), with its "all at once" action. Picking a
/// card selects its cue (the list, video and timeline go there); selecting a cue
/// anywhere else marks its cards.
///
/// Picking a reading or a fix applies it at once, and the card stays until it is
/// confirmed, so the change can be seen (and another tried) first.
///
/// With the sidebar focused: Up and Down move between cards, Return takes the
/// card's blue button (Confirm), Delete rejects a change, 1 to 9 try a reading or fix, E edits
/// the cue right in the card (⌘Return or Esc finishes) and P plays it. A decision
/// moves on to the next card and can be undone from the note at the bottom.
struct ReviewSidebar: View {
    let editor: EditorState
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ReviewHeader(editor: editor)
            Divider()
            if editor.isReviewHeld {
                BriefWaiting(editor: editor)
            } else {
                cards
            }
        }
        .overlay(alignment: .bottom) { UndoNote(editor: editor) }
        .background(.background.opacity(0.4))
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(phases: .down) { press in handle(press) }
        .onChange(of: editor.reviewFocusRequest) { isFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Review.root)
    }

    private var cards: some View {
        let entries = self.entries
        let current = editor.currentReviewItem
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(entries) { entry in
                        switch entry {
                        case .open(let item):
                            ReviewCard(editor: editor, item: item, isCurrent: item.id == current?.id || item == editor.reviewEditingItem) {
                                editor.selectReviewItem(item)
                                isFocused = true
                            }
                        case .settled(let settled):
                            SettledCard(editor: editor, settled: settled)
                        }
                    }
                    if entries.isEmpty {
                        Text(editor.reviewItems(in: .all).isEmpty ? "Everything is reviewed." : "Nothing left under this filter.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 30)
                            .accessibilityIdentifier(AccessibilityID.Review.emptyState)
                    }
                }
                .padding(8)
            }
            .onChange(of: current?.id) { _, id in
                guard let id else { return }
                withAnimation(editor.launchOptions.isUITestMode ? nil : .default) { proxy.scrollTo(id) }
            }
        }
    }

    /// Open cards, and settled ones while Show settled is on, in time order. Cards being
    /// tried or edited stay, even once their issue is gone, until confirmed.
    private var entries: [ReviewEntry] {
        let open = editor.reviewCards.map(ReviewEntry.open)
        guard editor.showsSettledReviews else { return open }
        let settled = editor.settledReviewsToShow.map(ReviewEntry.settled)
        return (open + settled).sorted { $0.start < $1.start }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        // Keys typed into a card's text are the text's.
        guard editor.reviewEditingItem == nil else { return .ignored }
        // Menu shortcuts (⌘↑, ⌥⌘↩…) pass through.
        guard press.modifiers.isDisjoint(with: [.command, .option, .control]) else { return .ignored }
        // Space plays and pauses here as everywhere (a focused view can take it before the menu does).
        if press.key == .space { return editor.perform(.togglePlay) ? .handled : .ignored }
        switch press.key {
        case .upArrow:
            return editor.stepReviewItem(forward: false) ? .handled : .ignored
        case .downArrow:
            return editor.stepReviewItem(forward: true) ? .handled : .ignored
        default:
            break
        }
        guard let item = editor.currentReviewItem else { return .ignored }
        switch press.key {
        case .return:
            if item.kind == .glossary ? editor.glossaryReplacement(forCue: item.cueID) == nil : item.kind.isIssueCard && editor.reviewSuggestions(for: item).isEmpty {
                editor.editReviewItem(item)
            } else {
                editor.decide(item, .primary)
            }
            return .handled
        case .delete, .deleteForward:
            guard item.kind == .change || item.kind == .script else { return .ignored }
            editor.decide(item, .reject)
            return .handled
        default:
            break
        }
        switch press.characters.lowercased() {
        case "e":
            editor.editReviewItem(item)
        case "p":
            editor.playReviewItem(item)
        case let digit where digit.count == 1 && ("1"..."9").contains(digit):
            guard let index = Int(digit) else { return .ignored }
            switch item.kind {
            case .choice, .script: editor.decide(item, .variant(index - 1))
            case .issues, .frames: editor.decide(item, .suggestion(index - 1))
            default: return .ignored
            }
        default:
            return .ignored
        }
        return .handled
    }
}

/// Instead of the cards while the review waits for the episode brief or the script
/// review: what is happening, and the button that opens the brief to confirm.
private struct BriefWaiting: View {
    let editor: EditorState

    var body: some View {
        VStack(spacing: 10) {
            if editor.isReviewingScript {
                ProgressView().controlSize(.small)
                Text("Reviewing the script with the brief…")
                    .font(.callout)
                Text("Everything to review shows once it's done.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if editor.isBuildingBrief {
                ProgressView().controlSize(.small)
                Text("Building the episode brief…")
                    .font(.callout)
                Text("The review shows once you confirm who is who.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Confirm the episode brief to see the review.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                CommandButton(command: .showEpisodeBrief, editor: editor)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Brief.waiting)
    }
}

private enum ReviewEntry: Identifiable {
    case open(ReviewItem)
    case settled(SettledReview)

    var id: String {
        switch self {
        case .open(let item): item.id
        case .settled(let settled): "settled.\(settled.id)"
        }
    }

    var start: MediaTime {
        switch self {
        case .open(let item): item.start
        case .settled(let settled): settled.item.start
        }
    }
}

/// Over the cards: how much is left, the filter chips and the filter's "all at once" action.
private struct ReviewHeader: View {
    let editor: EditorState

    var body: some View {
        let left = editor.reviewCount(in: .all)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Review").font(.headline)
                Text(editor.isReviewingScript ? "Reviewing the script" : editor.isReviewHeld ? "Waiting for the brief" : left == 0 ? "All done" : "\(left) to review")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if editor.track.brief != nil {
                    CommandButton(command: .showEpisodeBrief, systemImage: "person.2", editor: editor)
                }
            }
            // No All chip: with no chip picked the sidebar lists everything, and picking one again clears it.
            let scopes = ReviewScope.allCases.filter { $0 != .all && ($0 == editor.reviewScope || editor.reviewCount(in: $0) > 0) }
            FlowRow(spacing: 4) {
                ForEach(scopes, id: \.self) { scope in
                    ScopeButton(editor: editor, scope: scope)
                }
            }
            HStack(spacing: 8) {
                Toggle("Show settled", isOn: Binding(get: { editor.showsSettledReviews }, set: { editor.showsSettledReviews = $0 }))
                    .toggleStyle(.checkbox)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AccessibilityID.Review.showSettled)
                Spacer(minLength: 4)
                filterActions
            }
            .font(.callout)
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    /// What settles the filter's rest at once, and what issues are checked against.
    @ViewBuilder private var filterActions: some View {
        switch editor.reviewScope {
        case .all:
            EmptyView()
        case .issues, .frames:
            Text(editor.qcPreset.name)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(editor.qcPreset.summary)
                .accessibilityLabel("QC preset")
                .accessibilityValue(editor.qcPreset.name)
                .accessibilityIdentifier(AccessibilityID.Issues.preset)
            if editor.canPerform(.fixOverlaps) { CommandButton(command: .fixOverlaps, editor: editor) }
        case .glossary:
            CommandButton(command: .showGlossary, editor: editor)
        case .words:
            CommandButton(command: .confirmRemainingWords, editor: editor)
        case .choices:
            CommandButton(command: .acceptRemainingChoices, editor: editor)
        case .script:
            EmptyView()
        case .changes:
            CommandButton(command: .rejectAllChanges, editor: editor)
            CommandButton(command: .acceptAllChanges, editor: editor)
                .buttonStyle(.borderedProminent)
        }
    }
}

/// Lays chips out in rows, wrapping when the sidebar is narrow.
private struct FlowRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map { $0.last.map { $0.x + $0.size.width } ?? 0 }.max() ?? 0
        let height = rows.last.flatMap { row in row.map { $0.y + $0.size.height }.max() } ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, place) in arrange(subviews, width: bounds.width).joined().enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + place.x, y: bounds.minY + place.y), proposal: ProposedViewSize(place.size))
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [[(x: CGFloat, y: CGFloat, size: CGSize)]] {
        var rows: [[(x: CGFloat, y: CGFloat, size: CGSize)]] = [[]]
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                rows.append([])
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            rows[rows.count - 1].append((x, y, size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return rows
    }
}

/// "Issues 3": picks a filter (again: back to everything). There is no chip for everything.
private struct ScopeButton: View {
    let editor: EditorState
    let scope: ReviewScope

    var body: some View {
        let isOn = editor.reviewScope == scope
        let count = editor.reviewCount(in: scope)
        Button {
            editor.perform(command)
        } label: {
            HStack(spacing: 5) {
                Text(title)
                    .foregroundStyle(isOn ? .primary : .secondary)
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(tint)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(tint.opacity(scope == .all ? 0.12 : 0.14), in: Capsule())
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(isOn ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .font(.callout)
        .lineLimit(1)
        .help(help)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityLabel(title)
        .accessibilityValue(summary(count))
        .accessibilityIdentifier(identifier)
    }

    /// All lists everything; each other chip toggles its filter.
    private var command: EditorCommand {
        switch scope {
        case .all: .showAllCues
        case .issues: .toggleIssuesPanel
        case .frames: .reviewFrames
        case .glossary: .reviewGlossary
        case .words: .reviewWords
        case .choices: .reviewChoices
        case .script: .reviewScriptFindings
        case .changes: .reviewChanges
        }
    }

    private var title: String {
        switch scope {
        case .all: "All"
        case .issues: "Issues"
        case .frames: "Frames"
        case .glossary: "Glossary"
        case .words: "Words"
        case .choices: "Choices"
        case .script: "AI Review"
        case .changes: "AI Changes"
        }
    }

    /// Orange for what needs the user's check, purple for AI suggestions to decide.
    private var tint: Color {
        switch scope {
        case .all: .secondary
        case .issues, .frames, .glossary, .words: .attentionTint
        case .choices, .changes, .script: .aiTint
        }
    }

    private var help: String {
        switch scope {
        case .all: "Everything to review"
        case .issues: "Cues that break the \(editor.qcPreset.name) rules"
        case .frames: "Cues too close to a shot change or the next cue"
        case .glossary: "Lines that do not use a glossary term's agreed translation"
        case .words: "Words the transcription wasn't sure of"
        case .choices: "Lines the translation could word more than one way"
        case .script: "Lines the AI script review thinks were misheard or make no sense, or where the audio says something else"
        case .changes: "Changes \(editor.pendingReview?.title ?? "an AI tool") proposes"
        }
    }

    private func summary(_ count: Int) -> String {
        switch scope {
        case .all: "\(count) to review"
        case .issues: count == 0 ? "No cues need review" : count == 1 ? "1 cue needs review" : "\(count) cues need review"
        case .frames: count == 1 ? "1 cue with frame issues" : "\(count) cues with frame issues"
        case .glossary: count == 1 ? "1 line misses a glossary term" : "\(count) lines miss a glossary term"
        case .words: count == 1 ? "1 word to check" : "\(count) words to check"
        case .choices: count == 1 ? "1 line to choose" : "\(count) lines to choose"
        case .script: count == 1 ? "1 line to check" : "\(count) lines to check"
        case .changes: "\(editor.pendingReview?.title ?? "AI"): \(count == 1 ? "1 change" : "\(count) changes") to review"
        }
    }

    private var identifier: String {
        switch scope {
        case .all: AccessibilityID.CueList.allScope
        case .issues: AccessibilityID.CueList.reviewSummary
        case .frames: AccessibilityID.CueList.framesSummary
        case .glossary: AccessibilityID.CueList.glossarySummary
        case .words: AccessibilityID.CueList.wordsSummary
        case .choices: AccessibilityID.CueList.choicesSummary
        case .script: AccessibilityID.CueList.scriptSummary
        case .changes: AccessibilityID.CueList.aiReview
        }
    }
}

/// One thing to decide: what it is, on which cue and when, enough of the line
/// to decide without looking away, and its buttons (the blue one is Return).
private struct ReviewCard: View {
    let editor: EditorState
    let item: ReviewItem
    let isCurrent: Bool
    let pick: () -> Void

    private var cue: Cue? { editor.cue(withID: item.cueID) ?? editor.proposedChange(forCue: item.cueID)?.cue }
    private var isOnSelectedCue: Bool { editor.selectedCueID == item.cueID }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            content
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isCurrent ? Color.accentColor : isOnSelectedCue ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.12),
                              lineWidth: isCurrent ? 2 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: pick)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityLabel("\(kindTitle), cue \(number)")
        .accessibilityValue(summary)
        .accessibilityIdentifier(AccessibilityID.Review.card(item.id))
    }

    private var number: Int {
        (editor.track.cues.firstIndex { $0.id == item.cueID } ?? -1) + 1
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(kindTitle)
                .fontWeight(.semibold)
                .foregroundStyle(kindTint)
            Text(number > 0 ? "Cue \(number)" : "New cue")
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(editor.label(for: item.start))
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
    }

    @ViewBuilder private var content: some View {
        if editor.reviewEditingItem == item {
            editingContent
        } else {
            kindContent
        }
    }

    /// Fixing right in the card: the cue's text (and its timing, for issues) with Done.
    @ViewBuilder private var editingContent: some View {
        if item.kind.isIssueCard, let cue = editor.cue(withID: item.cueID) {
            let issues = editor.cardIssues(item)
            ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(issue.severity == .error ? Color.errorTint : Color.attentionTint)
                    Text(issue.message)
                }
                .font(.callout)
            }
            if issues.isEmpty {
                Label("Fixed", systemImage: "checkmark").font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                TimeField(editor: editor, cue: cue, edge: .start, showsFrame: true)
                TimeField(editor: editor, cue: cue, edge: .end, showsFrame: true)
            }
        }
        if editor.cue(withID: item.cueID) != nil {
            CardTextEditor(editor: editor, item: item, direction: direction)
        }
        buttons {
            Text("⌘↩ when done")
                .font(.caption)
                .foregroundStyle(.tertiary)
            CardButton(editor: editor, item: item, action: .done, title: "Done", key: "⌘Return", isPrimary: true) {
                editor.finishEditingReviewItem()
            }
        }
    }

    @ViewBuilder private var kindContent: some View {
        switch item.kind {
        case .change: changeContent
        case .choice: choiceContent
        case .script: scriptContent
        case .word(let index): wordContent(index)
        case .issues, .frames: issuesContent
        case .glossary: glossaryContent
        }
    }

    // MARK: Kinds

    private var kindTitle: String {
        switch item.kind {
        case .change: "AI change"
        case .choice: "Choice"
        case .script: "AI review"
        case .word: "Unsure word"
        case .issues: "Issue"
        case .frames: "Frames"
        case .glossary: "Glossary"
        }
    }

    private var kindTint: Color {
        switch item.kind {
        case .change, .choice, .script: .aiTint
        case .word, .issues, .frames, .glossary: .attentionTint
        }
    }

    private var direction: TextDirection { editor.targetDirection }

    @ViewBuilder private var changeContent: some View {
        if let change = editor.proposedChange(forCue: item.cueID) {
            Group {
                switch change.kind {
                case .insert:
                    Text(change.cue.text).foregroundStyle(Color.aiTint)
                case .delete:
                    Text(change.cue.text).strikethrough().foregroundStyle(Color.errorTint)
                case .update(let before):
                    if change.changesText, !before.text.isEmpty {
                        DiffText(old: before.text, new: change.cue.text)
                    } else {
                        Text(change.cue.text)
                    }
                }
            }
            .font(SpotlineStyle.cueFont)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.layoutDirection, direction.layoutDirection)
            .frame(maxWidth: .infinity, alignment: .leading)
            let details = changeDetails(change)
            if !details.isEmpty {
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let note = change.note {
                Text(note).font(.caption).foregroundStyle(Color.attentionTint)
            }
            buttons {
                CardButton(editor: editor, item: item, action: .reject, title: "Reject", key: "Delete") { editor.decide(item, .reject) }
                CardButton(editor: editor, item: item, action: .accept, title: "Accept", key: "Return", isPrimary: true) { editor.decide(item, .primary) }
            }
        }
    }

    /// "New cue", "Remove this cue", "Timing 00:00:01:00 – 00:00:02:00".
    private func changeDetails(_ change: ProposedChange) -> String {
        switch change.kind {
        case .insert: return "New cue, \(editor.label(for: change.cue.start)) – \(editor.label(for: change.cue.end))"
        case .delete: return "Remove this cue"
        case .update(let before):
            guard before.start != change.cue.start || before.end != change.cue.end else { return "" }
            return "Timing \(editor.label(for: change.cue.start)) – \(editor.label(for: change.cue.end))"
        }
    }

    @ViewBuilder private var choiceContent: some View {
        if let cue, let flag = cue.flag {
            HStack(spacing: 6) {
                if let source = editor.sourceCues[cue.id] {
                    Text(SubtitleText.visibleLines(of: source.text).joined(separator: " "))
                        .lineLimit(2)
                }
                Text("\(Int((flag.confidence * 100).rounded()))% sure")
                    .monospacedDigit()
                    .foregroundStyle(flag.confidence < 0.75 ? Color.attentionTint : Color.secondary)
                    .help("How sure the translator was of its pick")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if !flag.note.isEmpty {
                Text(flag.note).font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(flag.variants.enumerated()), id: \.offset) { index, variant in
                    VariantRow(editor: editor, item: item, index: index, variant: variant, isChosen: index == flag.chosen, direction: direction)
                }
            }
            buttons {
                CardButton(editor: editor, item: item, action: .edit, title: "Edit", key: "E") { editor.editReviewItem(item) }
                CardButton(editor: editor, item: item, action: .confirm, title: "Confirm", key: "Return", isPrimary: true) { editor.decide(item, .primary) }
            }
        }
    }

    /// What the AI script review doubts, why, and its fixes to try (1 to 9), with how sure it is of each.
    @ViewBuilder private var scriptContent: some View {
        if let cue, let finding = cue.scriptFinding {
            let shown = finding.tried == nil ? cue.text : finding.original
            Text(highlighting(finding.words, in: SubtitleText.visibleLines(of: shown).joined(separator: "\n")))
                .font(SpotlineStyle.cueFont)
                .foregroundStyle(finding.tried == nil ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.layoutDirection, direction.layoutDirection)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !finding.reason.isEmpty {
                Text(finding.reason).font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(finding.fixes.enumerated()), id: \.offset) { index, fix in
                    FixRow(editor: editor, item: item, index: index, fix: fix, isTried: finding.tried == index, direction: direction)
                }
            }
            buttons {
                CardButton(editor: editor, item: item, action: .play, title: "Play", key: "P") { editor.playReviewItem(item) }
                    .disabled(!editor.hasMedia)
                CardButton(editor: editor, item: item, action: .keep, title: "Keep Line", key: "Delete") { editor.decide(item, .reject) }
                CardButton(editor: editor, item: item, action: .confirm, title: finding.tried == nil ? "Try Fix" : "Confirm", key: "Return", isPrimary: true) {
                    editor.decide(item, .primary)
                }
            }
        }
    }

    @ViewBuilder private func wordContent(_ index: Int) -> some View {
        if let cue, let word = cue.unsureWords?[safe: index] {
            Text(highlighting(word.text, in: SubtitleText.visibleLines(of: cue.text).joined(separator: "\n")))
                .font(SpotlineStyle.cueFont)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.layoutDirection, direction.layoutDirection)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(word.confidence.map { "The transcription was \(Int(($0 * 100).rounded()))% sure of “\(word.text)”" }
                ?? "The transcription wasn't sure of “\(word.text)”")
                .font(.caption)
                .foregroundStyle(.secondary)
            buttons {
                CardButton(editor: editor, item: item, action: .play, title: "Play", key: "P") { editor.playReviewItem(item) }
                    .disabled(!editor.hasMedia)
                CardButton(editor: editor, item: item, action: .edit, title: "Fix", key: "E") { editor.editReviewItem(item) }
                CardButton(editor: editor, item: item, action: .confirm, title: "Confirm", key: "Return", isPrimary: true) { editor.decide(item, .primary) }
            }
        }
    }

    @ViewBuilder private var issuesContent: some View {
        let issues = editor.cardIssues(item)
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(issue.severity == .error ? Color.errorTint : Color.attentionTint)
                    Text(issue.message)
                }
                .font(.callout)
            }
            // A fix being tried that clears everything: the card stays until confirmed.
            if issues.isEmpty {
                Label(cue == nil ? "Cue deleted" : "No issues left", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.tint)
            }
        }
        if let cue, !cue.text.isEmpty {
            Text(SubtitleText.visibleLines(of: cue.text).joined(separator: "\n"))
                .font(SpotlineStyle.cueFont)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .environment(\.layoutDirection, direction.layoutDirection)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        let suggestions = editor.reviewSuggestions(for: item)
        let picked = editor.pickedSuggestions(of: item)
        // Group names only where there is a choice to combine.
        let groups = Set(suggestions.map(\.group).filter { $0 != .all })
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                    if groups.count > 1, suggestion.group != .all, index == 0 || suggestions[index - 1].group != suggestion.group {
                        Text(suggestion.group.title)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.top, index == 0 ? 0 : 4)
                    }
                    SuggestionRow(
                        editor: editor, item: item, index: index, suggestion: suggestion,
                        isPicked: editor.isPicked(index, of: item), direction: direction
                    )
                }
            }
        }
        buttons {
            if editor.canIgnoreReadingSpeed(item) {
                CardButton(editor: editor, item: item, action: .ignore, title: "Ignore", key: "no key") {
                    editor.decide(item, .ignoreReadingSpeed)
                }
                .help("No fix reads slower here: accept this reading speed. The cue is flagged again if it gets faster.")
            }
            CardButton(editor: editor, item: item, action: .play, title: "Play", key: "P") { editor.playReviewItem(item) }
                .disabled(!editor.hasMedia || cue == nil)
            CardButton(editor: editor, item: item, action: .edit, title: "Edit", key: suggestions.isEmpty ? "Return or E" : "E", isPrimary: suggestions.isEmpty) {
                editor.editReviewItem(item)
            }
            .disabled(cue == nil)
            if !suggestions.isEmpty {
                CardButton(editor: editor, item: item, action: .confirm, title: "Confirm", key: "Return", isPrimary: true) {
                    editor.decide(item, .primary)
                }
                .disabled(picked.isEmpty)
            }
        }
    }

    /// A glossary term the line does not use: the line as Replace would make it (the word it
    /// used struck out, the agreed one in), and Replace as the card's button. With no word to
    /// replace, the line as it is and Edit.
    @ViewBuilder private var glossaryContent: some View {
        let issues = editor.cardIssues(item)
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.attentionTint)
                    Text(issue.message)
                }
                .font(.callout)
            }
        }
        let replacement = editor.glossaryReplacement(forCue: item.cueID)
        if let cue, !cue.text.isEmpty {
            Group {
                if let replacement {
                    DiffText(old: SubtitleText.visibleLines(of: cue.text).joined(separator: "\n"), new: SubtitleText.visibleLines(of: replacement.text).joined(separator: "\n"))
                } else {
                    Text(SubtitleText.visibleLines(of: cue.text).joined(separator: "\n")).foregroundStyle(.secondary)
                }
            }
            .font(SpotlineStyle.cueFont)
            .lineLimit(3)
            .environment(\.layoutDirection, direction.layoutDirection)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        buttons {
            CardButton(editor: editor, item: item, action: .play, title: "Play", key: "P") { editor.playReviewItem(item) }
                .disabled(!editor.hasMedia || cue == nil)
            CardButton(editor: editor, item: item, action: .edit, title: "Edit", key: replacement == nil ? "Return or E" : "E", isPrimary: replacement == nil) {
                editor.editReviewItem(item)
            }
            .disabled(cue == nil)
            if let replacement {
                CardButton(editor: editor, item: item, action: .confirm, title: "Replace", key: "Return", isPrimary: true) {
                    editor.decide(item, .primary)
                }
                .help("\(replacement.title) (Return)")
            }
        }
    }

    private func buttons<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            content()
        }
        .controlSize(.small)
    }

    /// The line with the unsure word underlined in orange.
    private func highlighting(_ word: String, in text: String) -> AttributedString {
        highlighting([word], in: text)
    }

    /// The line with each of `words` underlined in orange.
    private func highlighting(_ words: [String], in text: String) -> AttributedString {
        var result = AttributedString(text)
        for word in words where !word.isEmpty {
            if let range = result.range(of: word, options: .caseInsensitive) {
                result[range].swiftUI.underlineStyle = Text.LineStyle(pattern: .solid, color: .attentionTint)
                result[range].swiftUI.foregroundColor = .attentionTint
            }
        }
        return result
    }

    private var summary: String {
        guard let cue else { return "" }
        switch item.kind {
        case .change: return editor.proposedChange(forCue: item.cueID)?.cue.text ?? ""
        case .choice: return cue.text
        case .script: return cue.scriptFinding?.reason ?? ""
        case .word(let index): return cue.unsureWords?[safe: index]?.text ?? ""
        case .issues, .frames, .glossary: return editor.cardIssues(item).map(\.message).joined(separator: "\n")
        }
    }
}

/// The cue's text, edited in its card: typed in its language's direction, the
/// unsure word selected when the card opens. ⌘Return or Esc finishes.
private struct CardTextEditor: View {
    let editor: EditorState
    let item: ReviewItem
    let direction: TextDirection
    @FocusState private var isFocused: Bool

    var body: some View {
        TextEditor(text: Binding(
            get: { editor.cue(withID: item.cueID)?.text ?? "" },
            set: { editor.setText($0, forCue: item.cueID) }
        ))
        .font(SpotlineStyle.cueFont)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(minHeight: 58)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: SpotlineStyle.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: SpotlineStyle.cornerRadius).strokeBorder(Color.accentColor.opacity(isFocused ? 0.8 : 0.3)))
        .environment(\.layoutDirection, direction.layoutDirection)
        .focused($isFocused)
        .onAppear {
            // Focus once the card has its editor, then select the word to check (through AppKit,
            // as in the cue list: a SwiftUI selection binding moved the cursor on every keystroke).
            Task { @MainActor in
                isFocused = true
                try? await Task.sleep(for: .milliseconds(80))
                guard case .word = item.kind, let request = editor.wordSelectionRequest, request.cueID == item.cueID,
                      let textView = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
                let range = (textView.string as NSString).range(of: request.word, options: .caseInsensitive)
                if range.location != NSNotFound { textView.setSelectedRange(range) }
            }
        }
        .onChange(of: isFocused) { _, focused in editor.isEditingText = focused }
        // Removed while focused (another card picked): typing is over.
        .onDisappear { if isFocused { editor.isEditingText = false } }
        .onKeyPress(.escape) {
            editor.finishEditingReviewItem()
            return .handled
        }
        .onKeyPress(.return, phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            editor.finishEditingReviewItem()
            return .handled
        }
        .accessibilityIdentifier(AccessibilityID.Review.text(item.id))
    }
}

/// One suggested fix on an issue card: its number, what it does, and for text
/// fixes what the text becomes. The first is the blue one (Return).
private struct SuggestionRow: View {
    let editor: EditorState
    let item: ReviewItem
    let index: Int
    let suggestion: ReviewSuggestion
    let isPicked: Bool
    let direction: TextDirection

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // Radio buttons within a group; the Fix All row, which picks one of two groups each, a check.
            Image(systemName: suggestion.group == .all ? (isPicked ? "checkmark.circle.fill" : "checkmark.circle")
                : isPicked ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isPicked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if index < 9 {
                        Text("\(index + 1)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    Text(suggestion.title)
                    if !suggestion.fixes.isEmpty {
                        Text("fixes \(suggestion.fixes)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if let preview = suggestion.preview {
                    Text(SubtitleText.visibleLines(of: preview).joined(separator: "\n"))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .environment(\.layoutDirection, direction.layoutDirection)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture { editor.decide(item, .suggestion(index)) }
        .help(isPicked ? "Take it back\(index < 9 ? " (\(index + 1))" : "")" : "Try it\(index < 9 ? " (\(index + 1))" : ""); Confirm keeps it")
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(isPicked ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(suggestion.title)
        .accessibilityValue(suggestion.preview ?? "")
        .accessibilityIdentifier(AccessibilityID.Review.suggestion(item.id, index))
        .accessibilityAction { editor.decide(item, .suggestion(index)) }
    }
}

/// A card button, with its key in the tooltip.
private struct CardButton: View {
    let editor: EditorState
    let item: ReviewItem
    let action: AccessibilityID.Review.Action
    let title: String
    let key: String
    var isPrimary = false
    let run: () -> Void

    var body: some View {
        Group {
            if isPrimary {
                Button(title, action: run).buttonStyle(.borderedProminent)
            } else {
                Button(title, action: run)
            }
        }
        .help("\(title) (\(key))")
        .accessibilityIdentifier(AccessibilityID.Review.action(item.id, action))
    }
}

/// One reading of a line: who it assumes ("Beth ♀ to Morty ♂") and its text. A click uses it.
private struct VariantRow: View {
    let editor: EditorState
    let item: ReviewItem
    let index: Int
    let variant: TranslationVariant
    let isChosen: Bool
    let direction: TextDirection

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: isChosen ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isChosen ? Color.aiTint : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    if index < 9 {
                        Text("\(index + 1)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    Text(variant.summary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(SubtitleText.visibleLines(of: variant.text).joined(separator: "\n"))
                    .font(SpotlineStyle.cueFont)
                    .fixedSize(horizontal: false, vertical: true)
                    .environment(\.layoutDirection, direction.layoutDirection)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture { editor.decide(item, .variant(index)) }
        .help(isChosen ? "In the line now; Confirm keeps it" : "Try it (\(index + 1)); Confirm keeps it")
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(variant.summary)
        .accessibilityValue(variant.text)
        .accessibilityIdentifier(AccessibilityID.Review.variant(item.id, index))
        .accessibilityAction { editor.decide(item, .variant(index)) }
    }
}

/// One fix on an AI Review card: how sure the review is, and the line as it would read. A click tries it.
private struct FixRow: View {
    let editor: EditorState
    let item: ReviewItem
    let index: Int
    let fix: ScriptFinding.Fix
    let isTried: Bool
    let direction: TextDirection

    var body: some View {
        let percent = "\(Int((fix.confidence * 100).rounded()))% sure"
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: isTried ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isTried ? Color.aiTint : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    if index < 9 {
                        Text("\(index + 1)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    Text(percent)
                        .monospacedDigit()
                        .foregroundStyle(fix.confidence < 0.75 ? Color.attentionTint : Color.secondary)
                }
                .font(.caption)
                Text(SubtitleText.visibleLines(of: fix.text).joined(separator: "\n"))
                    .font(SpotlineStyle.cueFont)
                    .fixedSize(horizontal: false, vertical: true)
                    .environment(\.layoutDirection, direction.layoutDirection)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture { editor.decide(item, .variant(index)) }
        .help(isTried ? "In the line now; Confirm keeps it" : "Try it (\(index + 1)); Confirm keeps it")
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(isTried ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(percent)
        .accessibilityValue(fix.text)
        .accessibilityIdentifier(AccessibilityID.Review.fix(item.id, index))
        .accessibilityAction { editor.decide(item, .variant(index)) }
    }
}

/// A card already decided, faded, while Show settled is on. Its cue is one click away.
private struct SettledCard: View {
    let editor: EditorState
    let settled: SettledReview

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark").foregroundStyle(.tint)
            Text(settled.outcome)
            Spacer(minLength: 4)
            Text(editor.label(for: settled.item.start))
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .opacity(0.7)
        .contentShape(Rectangle())
        .onTapGesture { editor.select(settled.item.cueID) }
        .accessibilityElement(children: .combine)
        .accessibilityValue(settled.outcome)
        .accessibilityIdentifier(AccessibilityID.Review.settled(settled.id))
    }
}

/// After a decision, for a few seconds: what was decided, and Undo.
private struct UndoNote: View {
    let editor: EditorState
    @State private var hiddenSerial: Int?

    var body: some View {
        if let last = editor.lastSettledReview, last.serial != hiddenSerial, editor.canUndoLastReviewDecision {
            HStack(spacing: 10) {
                Text(last.outcome)
                Button("Undo") { editor.undoLastReviewDecision() }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier(AccessibilityID.Review.undoButton)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            .shadow(radius: 6, y: 2)
            .padding(.bottom, 10)
            .task(id: last.serial) {
                try? await Task.sleep(for: .seconds(4))
                hiddenSerial = last.serial
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Last decision")
            .accessibilityValue(last.outcome)
            .accessibilityIdentifier(AccessibilityID.Review.undoNote)
        }
    }
}

/// At the right end of the title bar: shows and hides the review sidebar
/// (View › Show Review), with an orange count while there is something to review.
struct ReviewToggleButton: View {
    static let size = CGSize(width: 46, height: 30)
    let editor: EditorState

    var body: some View {
        let count = editor.hasAnythingToReview ? editor.reviewCount(in: .all) : 0
        let isOn = editor.isReviewSidebarVisible
        Button {
            editor.perform(.toggleReviewSidebar)
        } label: {
            Image(systemName: "sidebar.right")
                .font(.system(size: 15))
                .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 30, height: 24)
                .overlay(alignment: .topTrailing) {
                    if count > 0 {
                        Text(count > 99 ? "99+" : "\(count)")
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 15, minHeight: 15)
                            .background(Color.attentionTint, in: Capsule())
                            .offset(x: 9, y: -4)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: Self.size.width, height: Self.size.height)
        .help(count > 0 ? "\(EditorCommand.toggleReviewSidebar.title): \(count) to review (\(EditorCommand.toggleReviewSidebar.defaultShortcut?.displayString ?? ""))"
            : "\(EditorCommand.toggleReviewSidebar.title): nothing to review")
        .accessibilityLabel(EditorCommand.toggleReviewSidebar.title)
        .accessibilityValue(count == 0 ? "Nothing to review" : "\(count) to review")
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier(AccessibilityID.Review.toggle)
    }
}

extension ReviewSuggestion.Group {
    /// The group's name over its options on an issue card.
    var title: String {
        switch self {
        case .all: "Fix All"
        case .timing: "Timing"
        case .text: "Lines"
        case .cue: "Cue (instead of the others)"
        }
    }
}

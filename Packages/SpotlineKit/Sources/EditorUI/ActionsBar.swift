import EditorCommands
import SpotlineAccessibility
import SwiftUI

/// The strip above the mini-map: editing buttons on the left (In and Out, add,
/// split, merge, delete, snapping); the analysis status and zoom on the right.
/// Every button runs the same command as its menu item.
struct ActionsBar: View {
    let editor: EditorState

    var body: some View {
        HStack(spacing: 14) {
            group {
                CommandButton(command: .setIn, systemImage: "arrow.right.to.line", editor: editor)
                CommandButton(command: .setOut, systemImage: "arrow.left.to.line", editor: editor)
            }
            group {
                CommandButton(command: .addCue, systemImage: "plus", editor: editor)
                CommandButton(command: .splitCue, systemImage: "scissors", editor: editor)
                CommandButton(command: .mergeWithNext, systemImage: "arrow.right.and.line.vertical.and.arrow.left", editor: editor)
                CommandButton(command: .deleteCue, systemImage: "trash", editor: editor)
            }
            CommandButton(command: .toggleSnapping, systemImage: "arrow.left.and.line.vertical.and.arrow.right", editor: editor)
            Spacer(minLength: 8)
            AnalysisStatusView(editor: editor)
            HStack(spacing: 10) {
                CommandButton(command: .zoomOut, systemImage: "minus.magnifyingglass", editor: editor)
                CommandButton(command: .zoomIn, systemImage: "plus.magnifyingglass", editor: editor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.ActionsBar.root)
    }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .padding(.trailing, 4)
            .overlay(alignment: .trailing) { Divider().frame(height: 16).offset(x: 9) }
    }
}

/// Under the video: the playhead's timecode on the left, the transport in the
/// middle (shot change, frame, play, frame, shot change) and the frame rate on the right.
struct TransportBar: View {
    let editor: EditorState

    var body: some View {
        ZStack {
            HStack {
                TimecodeView(editor: editor)
                Spacer(minLength: 8)
                Text(editor.frameRate.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Frame rate")
                    .accessibilityValue(editor.frameRate.description)
                    .accessibilityIdentifier(AccessibilityID.Transport.frameRate)
            }
            HStack(spacing: 12) {
                CommandButton(command: .previousShotChange, systemImage: "backward.end", editor: editor)
                CommandButton(command: .stepBackward, systemImage: "backward.frame", editor: editor)
                PlayButton(editor: editor)
                    .font(.title3)
                CommandButton(command: .stepForward, systemImage: "forward.frame", editor: editor)
                CommandButton(command: .nextShotChange, systemImage: "forward.end", editor: editor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Transport.root)
    }
}

/// Play/Pause, showing the state the engine reports.
private struct PlayButton: View {
    let editor: EditorState

    var body: some View {
        CommandButton(command: .togglePlay, systemImage: editor.isPlaying ? "pause.fill" : "play.fill", editor: editor)
    }
}

/// The playhead's timecode, in its own view since it changes every frame.
private struct TimecodeView: View {
    let editor: EditorState

    var body: some View {
        let label = editor.showsMilliseconds ? editor.label(for: editor.currentTime) : editor.timecode.description
        Text(label)
            .font(.system(.title3, design: .monospaced))
            .accessibilityLabel("Timecode")
            .accessibilityValue(editor.timecode.description)
            .accessibilityIdentifier(AccessibilityID.Transport.timecode)
    }
}

/// Over the cue list, while there is something to review: a scope per kind,
/// with its count. A scope shows only its cues, each with its review box open,
/// and the scope's "all at once" action; the arrows step through them.
/// Scopes with nothing in them hide, so a clean project shows no bar.
struct ReviewScopeBar: View {
    let editor: EditorState

    var body: some View {
        let scopes = ReviewScope.allCases.filter { $0 == .all || $0 == editor.reviewScope || editor.reviewCount(in: $0) > 0 }
        if scopes.count > 1 {
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    ForEach(scopes, id: \.self) { scope in
                        ScopeButton(editor: editor, scope: scope)
                    }
                    Spacer(minLength: 8)
                    scopeActions
                    HStack(spacing: 6) {
                        CommandButton(command: .previousIssue, systemImage: "chevron.up", editor: editor)
                        CommandButton(command: .nextIssue, systemImage: "chevron.down", editor: editor)
                    }
                    .padding(.leading, 4)
                }
                .font(.callout)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                Divider()
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityID.CueList.reviewBar)
        }
    }

    /// What settles the scope's rest at once, and what it is checked against.
    @ViewBuilder private var scopeActions: some View {
        switch editor.reviewScope {
        case .all:
            EmptyView()
        case .issues:
            Text(editor.qcPreset.name)
                .foregroundStyle(.secondary)
                .help(editor.qcPreset.summary)
                .accessibilityLabel("QC preset")
                .accessibilityValue(editor.qcPreset.name)
                .accessibilityIdentifier(AccessibilityID.Issues.preset)
            if editor.canPerform(.fixOverlaps) { CommandButton(command: .fixOverlaps, editor: editor) }
        case .words:
            CommandButton(command: .confirmRemainingWords, editor: editor)
        case .choices:
            CommandButton(command: .acceptRemainingChoices, editor: editor)
        case .changes:
            CommandButton(command: .rejectAllChanges, editor: editor)
            CommandButton(command: .acceptAllChanges, editor: editor)
                .buttonStyle(.borderedProminent)
        }
    }
}

/// "Issues 3": picks a review scope (again: back to every cue).
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
        .disabled(!isOn && !editor.canPerform(command))
        .help(help)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityLabel(title)
        .accessibilityValue(summary(count))
        .accessibilityIdentifier(identifier)
    }

    /// All shows every cue; each other scope toggles its review.
    private var command: EditorCommand {
        switch scope {
        case .all: .showAllCues
        case .issues: .toggleIssuesPanel
        case .words: .reviewWords
        case .choices: .reviewChoices
        case .changes: .reviewChanges
        }
    }

    private var title: String {
        switch scope {
        case .all: "All"
        case .issues: "Issues"
        case .words: "Words"
        case .choices: "Choices"
        case .changes: "AI Changes"
        }
    }

    /// Orange for what needs the user's check, purple for AI suggestions to decide.
    private var tint: Color {
        switch scope {
        case .all: .secondary
        case .issues, .words: .attentionTint
        case .choices, .changes: .aiTint
        }
    }

    private var help: String {
        switch scope {
        case .all: EditorCommand.showAllCues.title
        case .issues: "Cues that break the \(editor.qcPreset.name) rules"
        case .words: "Words the transcription wasn't sure of"
        case .choices: "Lines the translation could word more than one way"
        case .changes: "Changes \(editor.pendingReview?.title ?? "an AI tool") proposes"
        }
    }

    private func summary(_ count: Int) -> String {
        switch scope {
        case .all: count == 1 ? "1 cue" : "\(count) cues"
        case .issues: count == 0 ? "No cues need review" : count == 1 ? "1 cue needs review" : "\(count) cues need review"
        case .words: count == 1 ? "1 word to check" : "\(count) words to check"
        case .choices: count == 1 ? "1 line to choose" : "\(count) lines to choose"
        case .changes: "\(editor.pendingReview?.title ?? "AI"): \(count == 1 ? "1 change" : "\(count) changes") to review"
        }
    }

    private var identifier: String {
        switch scope {
        case .all: AccessibilityID.CueList.allScope
        case .issues: AccessibilityID.CueList.reviewSummary
        case .words: AccessibilityID.CueList.wordsSummary
        case .choices: AccessibilityID.CueList.choicesSummary
        case .changes: AccessibilityID.CueList.aiReview
        }
    }
}

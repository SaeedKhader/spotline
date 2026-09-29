import EditorCommands
import SpotlineAccessibility
import SwiftUI

/// The strip above the mini-map: transport and editing buttons on the left;
/// the review count, analysis status, timecode and frame rate on the right.
/// Every button runs the same command as its menu item.
struct ActionsBar: View {
    let editor: EditorState

    var body: some View {
        HStack(spacing: 14) {
            group {
                CommandButton(command: .stepBackward, systemImage: "backward.frame", editor: editor)
                PlayButton(editor: editor)
                CommandButton(command: .stepForward, systemImage: "forward.frame", editor: editor)
            }
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
            group {
                CommandButton(command: .toggleSnapping, systemImage: "arrow.left.and.line.vertical.and.arrow.right", editor: editor)
                CommandButton(command: .zoomOut, systemImage: "minus.magnifyingglass", editor: editor)
                CommandButton(command: .zoomIn, systemImage: "plus.magnifyingglass", editor: editor)
            }
            Spacer(minLength: 8)
            ReviewSummary(editor: editor)
            AnalysisStatusView(editor: editor)
            TimecodeView(editor: editor)
            Text(editor.frameRate.description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Frame rate")
                .accessibilityValue(editor.frameRate.description)
                .accessibilityIdentifier(AccessibilityID.Transport.frameRate)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Transport.root)
    }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .padding(.trailing, 4)
            .overlay(alignment: .trailing) { Divider().frame(height: 16).offset(x: 9) }
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

/// "3 cues need review" under the QC preset. View › Show Issues lists them;
/// ⌥⌘↑ and ⌥⌘↓ step through them.
private struct ReviewSummary: View {
    let editor: EditorState

    var body: some View {
        let count = editor.issues.count
        let summary = count == 0 ? "No cues need review" : count == 1 ? "1 cue needs review" : "\(count) cues need review"
        HStack(spacing: 4) {
            Label(summary, systemImage: count == 0 ? "checkmark.circle" : "exclamationmark.triangle.fill")
                .foregroundStyle(count == 0 ? Color.secondary : Color.orange)
                .help(count == 0 ? summary : "\(summary): \(EditorCommand.toggleIssuesPanel.menuHint("View")) lists them")
                .accessibilityValue(summary)
                .accessibilityIdentifier(AccessibilityID.CueList.reviewSummary)
            Text("· \(editor.qcPreset.name)")
                .foregroundStyle(.tertiary)
                .help(editor.qcPreset.summary)
                .accessibilityLabel("QC preset")
                .accessibilityValue(editor.qcPreset.name)
                .accessibilityIdentifier(AccessibilityID.Issues.preset)
        }
        .font(.caption)
        .lineLimit(1)
    }
}

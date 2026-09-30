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

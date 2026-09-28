import EditorCommands
import SpotlineAccessibility
import SubtitleCore
import SwiftUI

/// The editor window: video and inspector on top, transport, timeline and cue list below.
public struct MainWindowView: View {
    let editor: EditorState

    public init(editor: EditorState) {
        self.editor = editor
    }

    public var body: some View {
        VSplitView {
            HSplitView {
                VideoPlaceholderView()
                    .frame(minWidth: 480, minHeight: 270)
                InspectorPlaceholderView()
                    .frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
            }
            VStack(spacing: 0) {
                TransportBar(editor: editor)
                Divider()
                TimelinePlaceholderView()
                Divider()
                CueListView(cues: editor.track.cues, frameRate: editor.frameRate)
            }
            .frame(minHeight: 240)
        }
        .frame(minWidth: 960, minHeight: 640)
        .transaction { transaction in
            if editor.launchOptions.isUITestMode { transaction.disablesAnimations = true }
        }
    }
}

struct VideoPlaceholderView: View {
    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 8) {
                Image(systemName: "film")
                    .font(.largeTitle)
                Text("No Media")
            }
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Video.surface)
    }
}

struct InspectorPlaceholderView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Inspector")
                .font(.headline)
            Text("Select a cue to edit its text and timing.")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Inspector.root)
    }
}

struct TransportBar: View {
    let editor: EditorState

    var body: some View {
        HStack(spacing: 12) {
            CommandButton(command: .stepBackward, systemImage: "backward.frame", editor: editor)
            CommandButton(
                command: .togglePlay,
                systemImage: editor.isPlaying ? "pause.fill" : "play.fill",
                editor: editor
            )
            CommandButton(command: .stepForward, systemImage: "forward.frame", editor: editor)
            Spacer()
            Text(editor.timecode.description)
                .font(.system(.title3, design: .monospaced))
                .accessibilityLabel("Timecode")
                .accessibilityValue(editor.timecode.description)
                .accessibilityIdentifier(AccessibilityID.Transport.timecode)
            Text(editor.frameRate.description)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(AccessibilityID.Transport.frameRate)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Transport.root)
    }
}

/// A toolbar-style button that runs an editor command and is findable by its command ID.
struct CommandButton: View {
    let command: EditorCommand
    let systemImage: String
    let editor: EditorState

    var body: some View {
        Button {
            editor.perform(command)
        } label: {
            Label(command.title, systemImage: systemImage)
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help(command.title)
        .disabled(!editor.canPerform(command))
        .accessibilityIdentifier(AccessibilityID.command(command.id))
    }
}

struct TimelinePlaceholderView: View {
    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(height: 80)
            .overlay(Text("Timeline").foregroundStyle(.secondary))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityID.Timeline.root)
    }
}

struct CueListView: View {
    let cues: [Cue]
    let frameRate: FrameRate

    var body: some View {
        Group {
            if cues.isEmpty {
                ContentUnavailableView(
                    "No Subtitles",
                    systemImage: "captions.bubble",
                    description: Text("Import a subtitle file or add a cue at the playhead.")
                )
            } else {
                Table(cues) {
                    TableColumn("In") { cue in
                        Text(Timecode(time: cue.start, rate: frameRate).description).monospacedDigit()
                    }
                    TableColumn("Out") { cue in
                        Text(Timecode(time: cue.end, rate: frameRate).description).monospacedDigit()
                    }
                    TableColumn("Text", value: \.text)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.CueList.root)
    }
}

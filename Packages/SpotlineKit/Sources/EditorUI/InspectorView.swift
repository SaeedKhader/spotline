import EditorCommands
import SpotlineAccessibility
import SubtitleCore
import SwiftUI

/// The selected cue's timing and text.
struct InspectorView: View {
    let editor: EditorState
    @FocusState private var isTextFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let cue = editor.selectedCue, let index = editor.selectedCueIndex {
                Text("Cue \(index + 1) of \(editor.track.cues.count)")
                    .font(.headline)
                timing(for: cue)
                Divider()
                Text("Text")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextEditor(text: Binding(
                    get: { editor.cue(withID: cue.id)?.text ?? "" },
                    set: { editor.setText($0, forCue: cue.id) }
                ))
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                .frame(minHeight: 72, maxHeight: 140)
                .focused($isTextFocused)
                .onKeyPress(.escape) {
                    isTextFocused = false
                    return .handled
                }
                .accessibilityIdentifier(AccessibilityID.Inspector.text)
                LineLengthsView(text: cue.text)
            } else {
                Text("Inspector")
                    .font(.headline)
                Text("Select a cue to edit its text and timing.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: isTextFocused) { _, focused in
            editor.isEditingText = focused
        }
        .onChange(of: editor.textFocusRequest) {
            isTextFocused = true
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Inspector.root)
    }

    private func timing(for cue: Cue) -> some View {
        let rate = editor.frameRate
        let inPoint = Timecode(frameNumber: cue.start.firstFrame(at: rate), rate: rate).description
        let outPoint = Timecode(frameNumber: cue.end.firstFrame(at: rate), rate: rate).description
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("In").foregroundStyle(.secondary)
                value(inPoint, id: AccessibilityID.Inspector.inPoint, label: "In")
                CommandButton(command: .setIn, systemImage: "arrow.right.to.line", editor: editor)
            }
            GridRow {
                Text("Out").foregroundStyle(.secondary)
                value(outPoint, id: AccessibilityID.Inspector.outPoint, label: "Out")
                CommandButton(command: .setOut, systemImage: "arrow.left.to.line", editor: editor)
            }
            GridRow {
                Text("Duration").foregroundStyle(.secondary)
                value(cue.duration.formattedSeconds + " s", id: AccessibilityID.Inspector.duration, label: "Duration")
            }
        }
    }

    private func value(_ text: String, id: String, label: String) -> some View {
        Text(text)
            .font(.system(.body, design: .monospaced))
            .accessibilityLabel(label)
            .accessibilityValue(text)
            .accessibilityIdentifier(id)
    }
}

/// Characters per line of visible text against the common 2 × 42 guideline.
/// Guidance only; QC enforces client limits in M4.
struct LineLengthsView: View {
    let text: String

    var body: some View {
        let lines = SubtitleText.visibleLines(of: text)
        let limit = SubtitleGuidelines.maxCharactersPerLine
        let summary = lines.map { "\($0.count)/\(limit)" }.joined(separator: " · ")
        // One Text, so automation reads the summary as its value.
        var label = Text("")
        for (index, line) in lines.enumerated() {
            let count = Text("\(line.count)/\(limit)").foregroundStyle(line.count > limit ? .red : .secondary)
            label = index == 0 ? count : Text("\(label)\(Text(" · ").foregroundStyle(.tertiary))\(count)")
        }
        if lines.count > SubtitleGuidelines.maxLines {
            label = Text("\(label)  \(Text("\(Image(systemName: "exclamationmark.triangle.fill")) \(lines.count) lines").foregroundStyle(.orange))")
        }
        return label
            .font(.caption.monospacedDigit())
            .help("Characters per line. Subtitles usually keep to \(SubtitleGuidelines.maxLines) lines of \(limit) characters.")
            .accessibilityLabel("Characters per line")
            .accessibilityValue(summary)
            .accessibilityIdentifier(AccessibilityID.Inspector.lineLengths)
    }
}

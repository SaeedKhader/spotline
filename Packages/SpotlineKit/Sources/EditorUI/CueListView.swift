import EditorCommands
import SpotlineAccessibility
import SubtitleCore
import SwiftUI

/// Every cue in the track. Selecting a row selects the cue and moves the playhead to it.
struct CueListView: View {
    let editor: EditorState

    var body: some View {
        Group {
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
            } else {
                CueTable(editor: editor)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.CueList.root)
    }
}

private struct CueTable: View {
    let editor: EditorState

    private struct Row: Identifiable {
        let number: Int
        let cue: Cue
        var id: Cue.ID { cue.id }
    }

    var body: some View {
        let rate = editor.frameRate
        let rows = editor.track.cues.enumerated().map { Row(number: $0.offset + 1, cue: $0.element) }
        let selection = Binding<Cue.ID?>(get: { editor.selectedCueID }, set: { editor.select($0) })
        ScrollViewReader { proxy in
            Table(rows, selection: selection) {
                TableColumn("#") { row in
                    cell(String(row.number), row, .number).foregroundStyle(.secondary)
                }
                .width(min: 28, ideal: 40, max: 64)
                TableColumn("In") { row in
                    cell(Timecode(frameNumber: row.cue.start.firstFrame(at: rate), rate: rate).description, row, .inPoint)
                }
                .width(min: 90, ideal: 100, max: 120)
                TableColumn("Out") { row in
                    cell(Timecode(frameNumber: row.cue.end.firstFrame(at: rate), rate: rate).description, row, .outPoint)
                }
                .width(min: 90, ideal: 100, max: 120)
                TableColumn("Duration") { row in
                    cell(row.cue.duration.formattedSeconds, row, .duration)
                }
                .width(min: 60, ideal: 70, max: 90)
                TableColumn("Text") { row in
                    cell(SubtitleText.visibleLines(of: row.cue.text).joined(separator: " / "), row, .text)
                        .lineLimit(1)
                }
            }
            .onChange(of: editor.selectedCueID) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private func cell(_ text: String, _ row: Row, _ column: AccessibilityID.CueList.Column) -> some View {
        Text(text)
            .monospacedDigit()
            .accessibilityValue(text)
            .accessibilityIdentifier(AccessibilityID.CueList.cell(row.id, column))
    }
}

extension MediaTime {
    /// Seconds with millisecond precision for display, e.g. "2.000".
    var formattedSeconds: String {
        String(format: "%.3f", seconds)
    }
}

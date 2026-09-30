import AppKit
import EditorCommands
import SpotlineAccessibility
import SwiftUI

/// In the middle of the title bar while an AI tool runs: what it is doing and
/// how far it has got, with a button to stop it. Click it for every step. For a
/// few seconds after the tool finishes, what it did ("640 lines translated · 12 flagged").
struct AIActivityPill: View {
    let editor: EditorState
    @State private var isShowingSteps = false

    var body: some View {
        Group {
            if let task = editor.aiTask {
                HStack(spacing: 8) {
                    Button {
                        isShowingSteps.toggle()
                    } label: {
                        AITaskProgress(task: task)
                            // A fixed size, so the title bar does not re-centre it as the text changes.
                            .frame(width: 380)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $isShowingSteps, arrowEdge: .bottom) {
                        AITaskSteps(editor: editor, task: task)
                    }
                    CommandButton(command: .cancelAITask, systemImage: "stop.circle", editor: editor)
                }
            } else if let summary = editor.aiSummary {
                Label(summary.fullText, systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityLabel("AI summary")
                    .accessibilityValue(summary.fullText)
                    .accessibilityIdentifier(AccessibilityID.CueList.aiSummary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxHeight: .infinity)
        // Toolbar items animate their layout; progress updates must not slide the activity around.
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.CueList.aiBar)
    }
}

/// The popover under the AI activity: every step, the current one marked, and Cancel.
private struct AITaskSteps: View {
    let editor: EditorState
    let task: AITaskStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(task.title).font(.headline)
            ForEach(Array(task.stages.enumerated()), id: \.offset) { index, stage in
                HStack(spacing: 8) {
                    Image(systemName: index < task.stage ? "checkmark.circle.fill" : index == task.stage ? "circle.dotted" : "circle")
                        .foregroundStyle(index <= task.stage ? Color.aiTint : Color.secondary)
                    Text(stage)
                        .fontWeight(index == task.stage ? .medium : .regular)
                        .foregroundStyle(index > task.stage ? .secondary : .primary)
                }
            }
            if !task.detail.isEmpty {
                Text(task.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                CommandButton(command: .cancelAITask, editor: editor)
            }
        }
        .padding(14)
        .frame(minWidth: 280, alignment: .leading)
    }
}

/// The window toolbar's one item: the AI activity, centred in the title bar.
@MainActor
final class AIActivityToolbar: NSObject, NSToolbarDelegate {
    static let item = NSToolbarItem.Identifier("aiActivity")
    let editor: EditorState

    init(editor: EditorState) {
        self.editor = editor
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.item] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.item] }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == Self.item else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        let view = NSHostingView(rootView: AIActivityPill(editor: editor))
        view.sizingOptions = [.intrinsicContentSize]
        item.view = view
        item.label = "AI Activity"
        item.isBordered = false
        return item
    }
}

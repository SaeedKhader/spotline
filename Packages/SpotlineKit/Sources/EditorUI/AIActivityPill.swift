import AppKit
import EditorCommands
import SpotlineAccessibility
import SwiftUI

/// In the middle of the title bar while an AI tool runs: what it is doing and
/// how far it has got, with a button to stop it. Click it for every step. For a
/// few seconds after the tool finishes, what it did ("640 lines translated · 12 flagged").
struct AIActivityPill: View {
    static let size = CGSize(width: 460, height: 34)
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
                            .frame(maxWidth: .infinity)
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
                    // Toolbars show labels as icons only by default.
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityLabel("AI summary")
                    .accessibilityValue(summary.fullText)
                    .accessibilityIdentifier(AccessibilityID.CueList.aiSummary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        // A fixed size (the toolbar item does not follow its content's size), with the content centred in it.
        .frame(width: Self.size.width, height: Self.size.height)
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

/// The window toolbar: the AI activity centred in the title bar, and at its right
/// end the button that shows and hides the review sidebar.
@MainActor
final class EditorToolbar: NSObject, NSToolbarDelegate {
    static let activity = NSToolbarItem.Identifier("aiActivity")
    static let review = NSToolbarItem.Identifier("review")
    let editor: EditorState

    init(editor: EditorState) {
        self.editor = editor
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.activity, .flexibleSpace, Self.review]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.activity:
            return hostedItem(itemIdentifier, AIActivityPill(editor: editor), size: AIActivityPill.size, label: "AI Activity")
        case Self.review:
            return hostedItem(itemIdentifier, ReviewToggleButton(editor: editor), size: ReviewToggleButton.size, label: "Review")
        default:
            return nil
        }
    }

    /// A toolbar item showing a SwiftUI view at a fixed size (the item does not follow its content's size).
    private func hostedItem(_ identifier: NSToolbarItem.Identifier, _ content: some View, size: CGSize, label: String) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        let view = NSHostingView(rootView: content)
        view.sizingOptions = []
        view.frame = NSRect(origin: .zero, size: size)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: size.width),
            view.heightAnchor.constraint(equalToConstant: size.height),
        ])
        item.view = view
        item.label = label
        item.isBordered = false
        return item
    }
}

import AppKit
import EditorCommands
import SubtitleFormats
import UniformTypeIdentifiers

/// The open and save panels and alerts `EditorState` shows. Tests replace them.
@MainActor
enum EditorPanels {
    static func chooseMedia() -> URL? {
        let panel = NSOpenPanel()
        panel.title = EditorCommand.openMedia.title
        panel.allowedContentTypes = [.movie, .audiovisualContent, .audio]
            + ["mkv", "webm", "mxf", "ts", "m2ts"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseSubtitles() -> URL? {
        let panel = NSOpenPanel()
        panel.title = EditorCommand.importSubtitles.title
        panel.allowedContentTypes = SubtitleFormat.allCases.flatMap(\.contentTypes)
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// A save panel with a format menu. The file name's extension follows the chosen format.
    static func chooseExportDestination(suggesting current: SubtitleFileReference?) -> SubtitleFileReference? {
        let panel = NSSavePanel()
        panel.title = EditorCommand.exportSubtitles.title
        panel.canCreateDirectories = true
        let format = FormatChooser(panel: panel, initial: current?.format ?? .srt)
        panel.accessoryView = format.view
        if let current {
            panel.directoryURL = current.url.deletingLastPathComponent()
            panel.nameFieldStringValue = current.url.deletingPathExtension().lastPathComponent
        } else {
            panel.nameFieldStringValue = "Untitled"
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return SubtitleFileReference(url: url, format: format.selected)
    }

    static func showError(_ title: String, _ error: any Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = String(describing: error)
        alert.runModal()
    }

    /// The "Format" pop-up in the export panel.
    @MainActor
    private final class FormatChooser: NSObject {
        let view: NSView
        private let popUp: NSPopUpButton
        private weak var panel: NSSavePanel?

        init(panel: NSSavePanel, initial: SubtitleFormat) {
            self.panel = panel
            popUp = NSPopUpButton(frame: .zero, pullsDown: false)
            popUp.addItems(withTitles: SubtitleFormat.allCases.map(\.displayName))
            popUp.selectItem(at: SubtitleFormat.allCases.firstIndex(of: initial) ?? 0)
            let label = NSTextField(labelWithString: "Format:")
            let stack = NSStackView(views: [label, popUp])
            stack.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
            view = stack
            super.init()
            popUp.target = self
            popUp.action = #selector(formatChanged)
            formatChanged()
        }

        var selected: SubtitleFormat { SubtitleFormat.allCases[max(popUp.indexOfSelectedItem, 0)] }

        @objc private func formatChanged() {
            panel?.allowedContentTypes = selected.contentType.map { [$0] } ?? []
        }
    }
}

extension SubtitleFormat {
    var contentType: UTType? {
        UTType(filenameExtension: fileExtension, conformingTo: .text)
    }

    /// Every file type the format reads, including alternative extensions (.dfxp, .xml).
    var contentTypes: [UTType] {
        ([fileExtension] + alternativeExtensions).compactMap { UTType(filenameExtension: $0) }
    }
}

import AppKit
import EditorCommands
import SwiftUI

/// The few colours, sizes and shapes every view shares, so the cue list, the
/// review bar, the timeline and the mini-map look like one app.
enum SpotlineStyle {
    /// Cue text in the list, proposals and the source column.
    static let cueFont = Font.system(size: 15)
    /// Boxes around text: editors, proposals, source text, suggestions.
    static let cornerRadius: CGFloat = 7
}

/// The app's colours. Besides the system neutrals there are four, each with one meaning:
/// the accent colour marks the selection and focus; `aiTint` marks what an AI tool
/// wrote or suggests; `attentionTint` marks what needs the user's check (QC issues,
/// words to check); red marks errors and deleted text only. Nothing else is coloured.
extension Color {
    /// Text and cues an AI tool wrote, until someone edits them, and AI suggestions to decide.
    static var aiTint: Color { Color(nsColor: .aiTint) }
    /// Something to check: QC warnings, words the transcriber was unsure of, a fast reading speed.
    static var attentionTint: Color { Color(nsColor: .attentionTint) }
    /// Errors (a QC error, an overlap) and deleted text.
    static var errorTint: Color { Color(nsColor: .systemRed) }
}

extension NSColor {
    static var aiTint: NSColor { .systemPurple }
    static var attentionTint: NSColor { .systemOrange }
}

extension KeyShortcut {
    /// The shortcut as menus show it, e.g. "⌃⌘R".
    var displayString: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        switch key {
        case .character(let character): result += character.uppercased()
        case .space: result += "Space"
        case .leftArrow: result += "←"
        case .rightArrow: result += "→"
        case .upArrow: result += "↑"
        case .downArrow: result += "↓"
        case .returnKey: result += "↩"
        case .delete: result += "⌫"
        case .escape: result += "⎋"
        }
        return result
    }
}

extension EditorCommand {
    /// "AI › Transcribe Audio, ⌃⌘R": where to find the command, for hints in empty views.
    func menuHint(_ menu: String) -> String {
        "\(menu) › \(title)" + (defaultShortcut.map { ", \($0.displayString)" } ?? "")
    }
}

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

extension Color {
    /// Text and cues an AI tool wrote, until someone edits them. Distinct from
    /// the accent colour, which marks the selection.
    static var aiTint: Color { Color(nsColor: .aiTint) }
}

extension NSColor {
    static var aiTint: NSColor { .systemPurple }
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

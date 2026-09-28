/// Reading-speed and layout guidance for subtitle text.
///
/// These are the common defaults of professional style guides (e.g. Netflix
/// for most Latin-script languages). The editor shows them as guidance; QC
/// rules with per-client presets enforce them in M4.
public enum SubtitleGuidelines {
    public static let maxLines = 2
    public static let maxCharactersPerLine = 42
}

public enum SubtitleText {
    /// The text as a viewer reads it: lines without inline markup such as
    /// `<i>`, `</b>`, `<v Anna>` or `{\an8}`, and with common entities decoded.
    public static func visibleLines(of text: String) -> [String] {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { line in
            var visible = ""
            var closing: Character?
            for character in line {
                if let end = closing {
                    if character == end { closing = nil }
                } else if character == "<" {
                    closing = ">"
                } else if character == "{", line.contains("}") {
                    closing = "}"
                } else {
                    visible.append(character)
                }
            }
            return decodeEntities(visible)
        }
    }

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text
            .replacing("&lt;", with: "<")
            .replacing("&gt;", with: ">")
            .replacing("&nbsp;", with: "\u{00A0}")
            .replacing("&lrm;", with: "\u{200E}")
            .replacing("&rlm;", with: "\u{200F}")
            .replacing("&amp;", with: "&")
    }
}

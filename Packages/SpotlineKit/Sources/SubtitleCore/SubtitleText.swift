public enum SubtitleText {
    /// Dialogue: two or more lines that each start with a dash, one speaker
    /// per line ("- Rick?\n- What now?"). Bidi marks before the dash don't count.
    public static func isDialogue(_ lines: [String]) -> Bool {
        lines.count > 1 && lines.allSatisfy {
            $0.trimmingCharacters(in: .whitespaces.union(["\u{200F}", "\u{202B}", "\u{200E}"])).hasPrefix("-")
        }
    }

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

    /// True when a viewer would read nothing: no text, or only spaces and markup.
    public static func isBlank(_ text: String) -> Bool {
        // Plain text (most cues) is read as it is; markup and entities are taken out first.
        guard text.contains(where: { $0 == "<" || $0 == "{" || $0 == "&" }) else { return text.allSatisfy(\.isWhitespace) }
        return visibleLines(of: text).joined().allSatisfy(\.isWhitespace)
    }

    /// Decodes the entities SRT and WebVTT text uses (`&amp;`, `&lt;`, `&gt;`, `&nbsp;`, `&lrm;`, `&rlm;`).
    public static func decodeEntities(_ text: String) -> String {
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

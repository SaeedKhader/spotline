import SubtitleCore

/// Cue text markup, shared by the formats that are not SRT or WebVTT.
///
/// Cue text uses SRT's conventions whatever file it came from: `<i>`, `<b>`,
/// `<u>` and `<s>` tags, entities for `<`, `>` and `&`, and ASS override
/// blocks (`{\fs20}`) kept as written. ASS and TTML convert to and from it.
enum Markup {
    enum Token: Equatable {
        case text(String)
        case lineBreak
        /// `<i>`, `</b>`: the tag name in lowercase and whether it closes.
        case tag(name: String, closing: Bool)
        /// Any other `<…>` tag, e.g. `<v Anna>` or `<font color="red">`, as written.
        case otherTag(String)
        /// An ASS override block, as written with its braces.
        case override(String)
    }

    /// The four styling tags cue text uses, in the order they are opened.
    static let styleTags = ["i", "b", "u", "s"]

    /// Splits cue text into text, tags and line breaks. Entities in text are decoded.
    static func tokens(of text: String) -> [Token] {
        var tokens: [Token] = []
        var run = ""
        func flush() {
            if !run.isEmpty { tokens.append(.text(SubtitleText.decodeEntities(run))) }
            run = ""
        }
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isNewline {
                flush()
                tokens.append(.lineBreak)
            } else if character == "<", let close = closing(">", in: text, from: index) {
                flush()
                let inner = text[text.index(after: index)..<close]
                let closing = inner.hasPrefix("/")
                let name = (closing ? inner.dropFirst() : inner).lowercased()
                if styleTags.contains(name) {
                    tokens.append(.tag(name: name, closing: closing))
                } else {
                    tokens.append(.otherTag(String(text[index...close])))
                }
                index = close
            } else if character == "{", let close = closing("}", in: text, from: index) {
                flush()
                tokens.append(.override(String(text[index...close])))
                index = close
            } else {
                run.append(character)
            }
            index = text.index(after: index)
        }
        flush()
        return tokens
    }

    /// The index of `delimiter` after `start` on the same line.
    private static func closing(_ delimiter: Character, in text: String, from start: String.Index) -> String.Index? {
        text[start...].firstIndex { $0 == delimiter || $0.isNewline }.flatMap { text[$0] == delimiter ? $0 : nil }
    }

    /// Text escaped for cue text: `<` and `>` as entities, since they would otherwise read as tags.
    static func escape(_ text: String) -> String {
        guard text.contains(where: { $0 == "<" || $0 == ">" }) else { return text }
        return text.replacing("<", with: "&lt;").replacing(">", with: "&gt;")
    }
}

extension Double {
    /// "20" for whole numbers, else the shortest exact decimal ("62.5").
    var compactDescription: String {
        rounded() == self && abs(self) < 1e15 ? String(Int64(self)) : String(self)
    }
}

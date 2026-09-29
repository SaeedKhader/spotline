import Foundation
import SubtitleCore

/// Timed Text Markup Language (.ttml, .dfxp, .xml), read leniently and written
/// as an IMSC 1.1 Text Profile document, the form Netflix, Apple and Amazon take.
///
/// Reading understands media time expressions (clock times, frames with
/// `ttp:frameRate` and `ttp:frameRateMultiplier`, ticks with `ttp:tickRate`,
/// and offsets such as `2.5s`), `begin`, `end` and `dur` on `body`, `div`, `p`
/// and (when `p` has none) `span`, and whitespace collapsing. Italic, bold and
/// underlined text, whether set inline, through referenced `<style>`s or by
/// inheritance, becomes `<i>`, `<b>` and `<u>`. A `p` whose region sits in the
/// upper half of the picture gets the top position. `xml:lang` on `<tt>` is
/// the track's language.
///
/// Writing is canonical: media time `HH:MM:SS.mmm` clock times, one default
/// style, a `bottom` and a `top` region inside the title-safe area, and `<br/>`
/// and `<span>`s for line breaks and styling.
enum TTML {
    // MARK: Reading

    static func parse(_ text: String) throws(SubtitleParseError) -> SubtitleTrack {
        let root = try XMLTree.parse(text)
        guard root.name == "tt" else {
            throw SubtitleParseError(line: 1, reason: "A TTML file must have a <tt> root element")
        }
        let reader = Reader(root: root)
        var track = SubtitleTrack(cues: reader.cues())
        if let language = root.attributes["lang"], !language.isEmpty { track.languageCode = language }
        return track
    }

    /// A minimal XML tree that keeps whitespace-only text (Foundation's `XMLDocument` drops it,
    /// and in TTML the space between two spans is text). Names are local: prefixes are dropped.
    final class XMLTree: NSObject, XMLParserDelegate {
        final class Element {
            let name: String
            let attributes: [String: String]
            var children: [Node] = []

            init(name: String, attributes: [String: String]) {
                self.name = name
                self.attributes = attributes
            }

            var elements: [Element] {
                children.compactMap { if case .element(let element) = $0 { element } else { nil } }
            }

            func elements(named name: String) -> [Element] { elements.filter { $0.name == name } }

            func descendants(named name: String) -> [Element] {
                elements.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(named: name) }
            }
        }

        enum Node {
            case element(Element)
            case text(String)
        }

        private var stack: [Element] = []
        private var root: Element?

        static func parse(_ text: String) throws(SubtitleParseError) -> Element {
            let text = text.first == "\u{FEFF}" ? String(text.dropFirst()) : text
            let tree = XMLTree()
            let parser = XMLParser(data: Data(text.utf8))
            parser.delegate = tree
            guard parser.parse(), let root = tree.root else {
                throw SubtitleParseError(line: max(parser.lineNumber, 1), reason: "Not valid XML")
            }
            return root
        }

        private static func localName(_ name: String) -> String {
            name.split(separator: ":").last.map(String.init) ?? name
        }

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName: String?, attributes: [String: String] = [:]
        ) {
            var local: [String: String] = [:]
            for (key, value) in attributes where !key.hasPrefix("xmlns") { local[Self.localName(key)] = value }
            let element = Element(name: Self.localName(elementName), attributes: local)
            stack.last?.children.append(.element(element))
            if stack.isEmpty { root = element }
            stack.append(element)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            stack.removeLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard let element = stack.last else { return }
            if case .text(let previous) = element.children.last {
                element.children[element.children.count - 1] = .text(previous + string)
            } else {
                element.children.append(.text(string))
            }
        }

        func parser(_ parser: XMLParser, foundCDATA data: Data) {
            self.parser(parser, foundCharacters: String(decoding: data, as: UTF8.self))
        }
    }

    typealias Element = XMLTree.Element

    private struct Flags: OptionSet {
        let rawValue: Int
        static let italic = Flags(rawValue: 1)
        static let bold = Flags(rawValue: 2)
        static let underline = Flags(rawValue: 4)
        /// In the order tags open.
        static let ordered: [(Flags, String)] = [(.italic, "i"), (.bold, "b"), (.underline, "u")]
    }

    /// Text styling that has been set (the rest inherits).
    private struct TextStyle {
        var set: Flags = []
        var values: Flags = []

        mutating func apply(_ other: TextStyle) {
            values = values.subtracting(other.set).union(other.values)
            set.formUnion(other.set)
        }
    }

    private enum Piece {
        case text(String, Flags)
        case lineBreak
    }

    private final class Reader {
        let root: Element
        var styles: [String: Element] = [:]
        var regions: [String: Element] = [:]
        let frameRate: Int64
        let frameRateMultiplier: (Int64, Int64)
        let tickRate: Int64
        /// The root container's height in pixels, for `px` region coordinates.
        let rootHeight: Double?
        /// Cell rows, for `c` region coordinates.
        let cellRows: Double

        init(root: Element) {
            self.root = root
            let declaredRate = root.attributes["frameRate"].flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
            frameRate = declaredRate ?? 30
            let multiplier = root.attributes["frameRateMultiplier"]?.split(separator: " ").compactMap { Int64($0) } ?? []
            frameRateMultiplier = multiplier.count == 2 && multiplier[0] > 0 && multiplier[1] > 0 ? (multiplier[0], multiplier[1]) : (1, 1)
            let subFrameRate = root.attributes["subFrameRate"].flatMap { Int64($0) } ?? 1
            tickRate = root.attributes["tickRate"].flatMap { Int64($0) } ?? (declaredRate.map { $0 * subFrameRate } ?? 1)
            rootHeight = root.attributes["extent"].flatMap { extent in
                let parts = extent.split(separator: " ")
                return parts.count == 2 && parts[1].hasSuffix("px") ? Double(parts[1].dropLast(2)) : nil
            }
            cellRows = root.attributes["cellResolution"]?.split(separator: " ").last.flatMap { Double($0) } ?? 15
            for head in root.elements(named: "head") {
                for styling in head.elements(named: "styling") {
                    for style in styling.elements(named: "style") {
                        if let id = style.attributes["id"] { styles[id] = style }
                    }
                }
                for layout in head.elements(named: "layout") {
                    for region in layout.elements(named: "region") {
                        if let id = region.attributes["id"] { regions[id] = region }
                    }
                }
            }
        }

        func cues() -> [Cue] {
            var cues: [Cue] = []
            for body in root.elements(named: "body") {
                visit(body, parentBegin: .zero, parentEnd: nil, style: TextStyle(), region: nil, preserve: false, into: &cues)
            }
            return cues.sorted { $0.start < $1.start }
        }

        private func visit(
            _ element: Element, parentBegin: MediaTime, parentEnd: MediaTime?, style inherited: TextStyle,
            region inheritedRegion: String?, preserve inheritedPreserve: Bool, into cues: inout [Cue]
        ) {
            var style = inherited
            style.apply(ownStyle(of: element))
            let region = element.attributes["region"] ?? inheritedRegion
            let preserve = element.attributes["space"].map { $0 == "preserve" } ?? inheritedPreserve
            var begin = parentBegin + (element.attributes["begin"].flatMap(time) ?? .zero)
            var end = element.attributes["end"].flatMap(time).map { parentBegin + $0 }
                ?? element.attributes["dur"].flatMap(time).map { begin + $0 }
                ?? parentEnd

            guard element.name == "p" else {
                for child in element.elements where ["div", "p"].contains(child.name) {
                    visit(child, parentBegin: begin, parentEnd: end, style: style, region: region, preserve: preserve, into: &cues)
                }
                return
            }
            // Some files time the spans inside an untimed paragraph.
            if element.attributes["begin"] == nil, element.attributes["end"] == nil, element.attributes["dur"] == nil {
                let spans = element.descendants(named: "span")
                let spanBegins = spans.compactMap { $0.attributes["begin"].flatMap(time) }
                let spanEnds = spans.compactMap { $0.attributes["end"].flatMap(time) }
                if let first = spanBegins.min(), let last = spanEnds.max() {
                    begin = parentBegin + first
                    end = parentBegin + last
                }
            }
            guard let end, begin < end else { return }
            var pieces: [Piece] = []
            collect(element, style: style, preserve: preserve, into: &pieces)
            cues.append(Cue(start: begin, end: end, text: Self.text(from: pieces), position: position(ofRegion: region)))
        }

        /// The text inside a `p` or `span`, as styled pieces.
        private func collect(_ element: Element, style: TextStyle, preserve: Bool, into pieces: inout [Piece]) {
            for node in element.children {
                switch node {
                case .element(let child):
                    switch child.name {
                    case "br":
                        pieces.append(.lineBreak)
                    case "span":
                        var childStyle = style
                        childStyle.apply(ownStyle(of: child))
                        let childPreserve = child.attributes["space"].map { $0 == "preserve" } ?? preserve
                        collect(child, style: childStyle, preserve: childPreserve, into: &pieces)
                    default:
                        continue  // metadata, set, animation
                    }
                case .text(let value):
                    if preserve {
                        for (index, line) in value.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
                            if index > 0 { pieces.append(.lineBreak) }
                            pieces.append(.text(String(line), style.values))
                        }
                    } else {
                        var collapsed = ""
                        for character in value {
                            if !character.isWhitespace {
                                collapsed.append(character)
                            } else if collapsed.last != " " {
                                collapsed.append(" ")
                            }
                        }
                        pieces.append(.text(collapsed, style.values))
                    }
                }
            }
        }

        /// Cue text from pieces: whitespace trimmed at line ends and tags opened and closed as styling changes.
        private static func text(from pieces: [Piece]) -> String {
            var lines: [[(String, Flags)]] = [[]]
            for piece in pieces {
                switch piece {
                case .lineBreak: lines.append([])
                case .text(let text, let flags): lines[lines.count - 1].append((text, flags))
                }
            }
            var output = ""
            var open: [(Flags, String)] = []
            for (number, line) in lines.enumerated() {
                if number > 0 { output += "\n" }
                // Join the line's runs, collapsing spaces across run boundaries and trimming the ends.
                var runs: [(String, Flags)] = []
                for (text, flags) in line {
                    var text = text
                    if runs.last?.0.last == " " || runs.allSatisfy({ $0.0.isEmpty }) {
                        text = String(text.drop(while: { $0 == " " }))
                    }
                    runs.append((text, flags))
                }
                if let lastIndex = runs.lastIndex(where: { !$0.0.isEmpty }) {
                    runs[lastIndex].0 = String(runs[lastIndex].0.reversed().drop(while: { $0 == " " }).reversed())
                }
                for (text, flags) in runs where !text.isEmpty {
                    if let firstUnwanted = open.firstIndex(where: { !flags.contains($0.0) }) {
                        for (_, tag) in open[firstUnwanted...].reversed() { output += "</\(tag)>" }
                        open.removeSubrange(firstUnwanted...)
                    }
                    for (flag, tag) in Flags.ordered where flags.contains(flag) && !open.contains(where: { $0.0 == flag }) {
                        output += "<\(tag)>"
                        open.append((flag, tag))
                    }
                    output += Markup.escape(text)
                }
            }
            for (_, tag) in open.reversed() { output += "</\(tag)>" }
            return output
        }

        /// The styling an element sets: its referenced styles, then its own attributes.
        private func ownStyle(of element: Element, visited: Set<String> = []) -> TextStyle {
            var style = TextStyle()
            for id in (element.attributes["style"] ?? "").split(separator: " ").map(String.init) where !visited.contains(id) {
                if let referenced = styles[id] { style.apply(ownStyle(of: referenced, visited: visited.union([id]))) }
            }
            func set(_ flag: Flags, _ value: Bool?) {
                guard let value else { return }
                style.set.insert(flag)
                if value { style.values.insert(flag) } else { style.values.remove(flag) }
            }
            set(.italic, element.attributes["fontStyle"].map { $0 == "italic" || $0 == "oblique" })
            set(.bold, element.attributes["fontWeight"].map { $0 == "bold" })
            if let decoration = element.attributes["textDecoration"] {
                if decoration.contains("noUnderline") { set(.underline, false) } else if decoration.contains("underline") { set(.underline, true) }
            }
            return style
        }

        /// A region attribute, set on the region or a style it references.
        private func regionValue(_ name: String, of region: Element) -> String? {
            if let value = region.attributes[name] { return value }
            for id in (region.attributes["style"] ?? "").split(separator: " ") {
                if let style = styles[String(id)], let value = style.attributes[name] { return value }
            }
            return nil
        }

        /// Top when the region sits in the upper half of the picture. No region means the bottom.
        private func position(ofRegion id: String?) -> CuePosition {
            guard let id, let region = regions[id] else { return .bottom }
            let top = regionValue("origin", of: region).flatMap { verticalPercent($0) } ?? 0
            let height = regionValue("extent", of: region).flatMap { verticalPercent($0) } ?? 100
            switch regionValue("displayAlign", of: region) {
            case "after": return top + height <= 50 ? .top : .bottom
            case "before": return top < 50 ? .top : .bottom
            default: return top + height / 2 < 50 ? .top : .bottom
            }
        }

        /// The second of two lengths ("10% 80%", "0px 864px", "0c 12c") as a percentage of the picture's height.
        private func verticalPercent(_ value: String) -> Double? {
            let parts = value.split(separator: " ")
            guard parts.count == 2 else { return nil }
            let length = parts[1]
            if length.hasSuffix("%") { return Double(length.dropLast()) }
            if length.hasSuffix("px"), let pixels = Double(length.dropLast(2)), let rootHeight { return pixels / rootHeight * 100 }
            if length.hasSuffix("c"), let cells = Double(length.dropLast()) { return cells / cellRows * 100 }
            return nil
        }

        /// A time expression: `HH:MM:SS.fff`, `HH:MM:SS:FF` or an offset such as `2.5s`, `40f` or `900t`.
        func time(_ expression: String) -> MediaTime? {
            let expression = expression.trimmingCharacters(in: .whitespaces)
            let parts = expression.split(separator: ":", omittingEmptySubsequences: false)
            if parts.count == 3 { return Timestamp.parse(expression) }
            if parts.count == 4 {
                guard let seconds = Timestamp.parse(parts[0..<3].joined(separator: ":")),
                      let frames = Int64(parts[3].prefix { $0 != "." })
                else { return nil }
                return seconds + frameTime(MediaTime(value: frames, timescale: 1))
            }
            let units: [(String, (MediaTime) -> MediaTime)] = [
                ("ms", { MediaTime(value: $0.value, timescale: $0.timescale * 1000) }),
                ("h", { MediaTime(value: $0.value * 3600, timescale: $0.timescale) }),
                ("m", { MediaTime(value: $0.value * 60, timescale: $0.timescale) }),
                ("s", { $0 }),
                ("f", { self.frameTime($0) }),
                ("t", { [tickRate] in MediaTime(value: $0.value, timescale: $0.timescale * tickRate) }),
            ]
            for (suffix, convert) in units where expression.hasSuffix(suffix) {
                guard let count = decimal(expression.dropLast(suffix.count)) else { return nil }
                return convert(count)
            }
            return nil
        }

        /// A number of frames as time at the document's effective frame rate.
        private func frameTime(_ frames: MediaTime) -> MediaTime {
            MediaTime(value: frames.value * frameRateMultiplier.1, timescale: frames.timescale * frameRate * frameRateMultiplier.0)
        }

        private func decimal(_ text: Substring) -> MediaTime? {
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count), let whole = Int64(parts[0]) else { return nil }
            guard parts.count == 2 else { return MediaTime(value: whole, timescale: 1) }
            let fraction = parts[1]
            guard !fraction.isEmpty, fraction.count <= 9, let digits = Int64(fraction) else { return nil }
            var scale: Int64 = 1
            for _ in 0..<fraction.count { scale *= 10 }
            return MediaTime(value: whole * scale + digits, timescale: scale)
        }
    }

    // MARK: Writing

    static func serialize(_ track: SubtitleTrack) -> String {
        let language = track.languageCode == "und" ? "" : track.languageCode
        var output = """
            <?xml version="1.0" encoding="UTF-8"?>
            <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttp="http://www.w3.org/ns/ttml#parameter" \
            xmlns:tts="http://www.w3.org/ns/ttml#styling" ttp:timeBase="media" \
            ttp:contentProfiles="http://www.w3.org/ns/ttml/profile/imsc1.1/text" xml:lang="\(escape(language))">
              <head>
                <styling>
                  <style xml:id="default" tts:fontFamily="proportionalSansSerif" tts:textAlign="center" tts:color="white"/>
                </styling>
                <layout>
                  <region xml:id="bottom" tts:origin="5% 5%" tts:extent="90% 90%" tts:displayAlign="after"/>
                  <region xml:id="top" tts:origin="5% 5%" tts:extent="90% 90%" tts:displayAlign="before"/>
                </layout>
              </head>
              <body style="default">
                <div>

            """
        for cue in track.cues {
            let begin = Timestamp.format(cue.start, fractionSeparator: ".")
            let end = Timestamp.format(cue.end, fractionSeparator: ".")
            let region = cue.position == .top ? "top" : "bottom"
            output += "      <p begin=\"\(begin)\" end=\"\(end)\" region=\"\(region)\">\(content(cue.text))</p>\n"
        }
        output += "    </div>\n  </body>\n</tt>\n"
        return output
    }

    private static let spanAttributes = [
        "i": "tts:fontStyle=\"italic\"", "b": "tts:fontWeight=\"bold\"",
        "u": "tts:textDecoration=\"underline\"", "s": "tts:textDecoration=\"lineThrough\"",
    ]

    /// Cue text as the content of a `<p>`: `<br/>` between lines, a `<span>` per styling tag.
    static func content(_ text: String) -> String {
        var output = ""
        var open: [String] = []
        for token in Markup.tokens(of: text) {
            switch token {
            case .text(let text): output += escape(text)
            case .lineBreak: output += "<br/>"
            case .tag(let name, closing: false):
                output += "<span \(spanAttributes[name]!)>"
                open.append(name)
            case .tag(let name, closing: true):
                // Close back to the matching span, then reopen the ones that were inside it.
                guard let index = open.lastIndex(of: name) else { continue }
                let reopened = open[(index + 1)...]
                output += String(repeating: "</span>", count: open.count - index)
                for tag in reopened { output += "<span \(spanAttributes[tag]!)>" }
                open.remove(at: index)
            case .otherTag, .override:
                continue
            }
        }
        output += String(repeating: "</span>", count: open.count)
        return output
    }

    static func escape(_ text: String) -> String {
        text.replacing("&", with: "&amp;").replacing("<", with: "&lt;").replacing(">", with: "&gt;").replacing("\"", with: "&quot;")
    }
}

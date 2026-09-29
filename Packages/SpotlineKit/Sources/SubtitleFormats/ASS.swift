import SubtitleCore

/// Advanced SubStation Alpha (.ass, "v4.00+") and its predecessor SubStation Alpha (.ssa, "v4.00").
///
/// Reads `[Script Info]` into the track's properties, `[V4+ Styles]` (or
/// `[V4 Styles]`) into its styles and `Dialogue` lines into cues with their
/// style and speaker (the Name field). Columns are read by the `Format`
/// lines, so files that order or omit fields differently still load.
///
/// Cue text is converted to Spotline's markup (see `Markup`): `\N` becomes a
/// line break, `\h` a no-break space, `{\i1}`…`{\i0}` (and `\b`, `\u`, `\s`)
/// become `<i>`…`</i>`, and the first `{\an8}` (or SSA `{\a6}`) sets the cue's
/// position. Other override tags stay in the text as written.
///
/// Not kept yet: `Comment` lines, layers, per-line margins and effects,
/// and the `[Fonts]`, `[Graphics]` and Aegisub sections.
enum ASS {
    enum Variant {
        /// v4.00+ (.ass)
        case ass
        /// v4.00 (.ssa)
        case ssa
    }

    // MARK: Reading

    static func parse(_ text: String) throws(SubtitleParseError) -> SubtitleTrack {
        var (track, events) = try readSections(text)
        for (fields, line) in events {
            guard let start = fields["start"].flatMap(Timestamp.parse) else {
                throw SubtitleParseError(line: line, reason: "Invalid start time \"\(fields["start"] ?? "")\"")
            }
            guard let end = fields["end"].flatMap(Timestamp.parse) else {
                throw SubtitleParseError(line: line, reason: "Invalid end time \"\(fields["end"] ?? "")\"")
            }
            track.cues.append(cue(from: fields, start: start, end: end, in: track))
        }
        track.cues.sort { $0.start < $1.start }
        return track
    }

    /// The fields of an event as Matroska stores it and FFmpeg's subtitle
    /// decoders return it: a Dialogue line without its times, led by its read order.
    static let embeddedEventFormat = ["readorder", "layer", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]

    /// A track from a header (`[Script Info]` and styles) and events in `embeddedEventFormat`, timed apart.
    static func parse(
        header: String, events: [(start: MediaTime, end: MediaTime, fields: String)]
    ) throws(SubtitleParseError) -> SubtitleTrack {
        var (track, _) = try readSections(header)
        for event in events {
            track.cues.append(cue(from: fields(event.fields, format: embeddedEventFormat), start: event.start, end: event.end, in: track))
        }
        track.cues.sort { $0.start < $1.start }
        return track
    }

    private static func cue(from fields: [String: String], start: MediaTime, end: MediaTime, in track: SubtitleTrack) -> Cue {
        let styleName = fields["style"].map { $0.hasPrefix("*") ? String($0.dropFirst()) : $0 }.flatMap { $0.isEmpty ? nil : $0 }
        let (text, override) = cueText(fromASS: fields["text"] ?? "")
        let position = override ?? track.style(named: styleName)?.position ?? .bottom
        let speaker = fields["name"].flatMap { $0.isEmpty ? nil : $0 }
        return Cue(start: start, end: end, text: text, position: position, style: styleName, speaker: speaker)
    }

    /// The header, styles and the fields of every Dialogue line with its line number.
    private static func readSections(
        _ text: String
    ) throws(SubtitleParseError) -> (SubtitleTrack, [(fields: [String: String], line: Int)]) {
        var track = SubtitleTrack()
        var section = ""
        var isLegacy = false
        var styleFormat: [String]?
        var eventFormat: [String]?
        var sawSection = false
        var events: [(fields: [String: String], line: Int)] = []

        for (index, rawLine) in splitLines(text).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("!:") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = line.dropFirst().dropLast().lowercased()
                if section == "v4 styles" { isLegacy = true }
                sawSection = true
                continue
            }
            guard sawSection else {
                throw SubtitleParseError(line: index + 1, reason: "An ASS or SSA file must start with [Script Info]")
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...].drop(while: { $0 == " " || $0 == "\t" }))
            switch section {
            case "script info":
                if key.caseInsensitiveCompare("ScriptType") == .orderedSame {
                    isLegacy = value.lowercased() == "v4.00"
                } else {
                    track.properties[key] = value
                }
            case "v4+ styles", "v4 styles":
                if key == "Format" {
                    styleFormat = formatNames(value)
                } else if key == "Style" {
                    let format = styleFormat ?? (isLegacy ? ssaStyleFormat : assStyleFormat).map { $0.lowercased() }
                    track.styles.append(style(from: fields(value, format: format), isLegacy: isLegacy))
                }
            case "events":
                if key == "Format" {
                    eventFormat = formatNames(value)
                } else if key == "Dialogue" {
                    let format = eventFormat ?? (isLegacy ? ssaEventFormat : assEventFormat).map { $0.lowercased() }
                    events.append((fields(value, format: format), index + 1))
                }
            default:
                continue
            }
        }

        return (track, events)
    }

    private static func formatNames(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }

    /// A line's comma-separated fields by (lowercased) format name. The last field takes the rest of the line.
    private static func fields(_ value: String, format: [String]) -> [String: String] {
        let parts = value.split(separator: ",", maxSplits: max(format.count - 1, 0), omittingEmptySubsequences: false)
        var result: [String: String] = [:]
        for (name, part) in zip(format, parts) {
            result[name] = name == "text" ? String(part) : part.trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    private static func style(from fields: [String: String], isLegacy: Bool) -> SubtitleStyle {
        var style = SubtitleStyle(name: fields["name"] ?? SubtitleStyle.defaultName)
        func number(_ key: String) -> Double? { fields[key].flatMap { Double($0) } }
        func integer(_ key: String) -> Int? { number(key).map { Int($0) } }
        func flag(_ key: String) -> Bool? { integer(key).map { $0 != 0 } }
        if let value = fields["fontname"] { style.fontName = value }
        if let value = number("fontsize") { style.fontSize = value }
        if let value = fields["primarycolour"].flatMap(color) { style.primaryColor = value }
        if let value = fields["secondarycolour"].flatMap(color) { style.secondaryColor = value }
        if let value = (fields["outlinecolour"] ?? fields["tertiarycolour"]).flatMap(color) { style.outlineColor = value }
        if let value = fields["backcolour"].flatMap(color) { style.backColor = value }
        if let value = flag("bold") { style.isBold = value }
        if let value = flag("italic") { style.isItalic = value }
        style.isUnderline = flag("underline") ?? false
        style.isStrikeOut = flag("strikeout") ?? false
        style.scaleX = number("scalex") ?? 100
        style.scaleY = number("scaley") ?? 100
        style.spacing = number("spacing") ?? 0
        style.angle = number("angle") ?? 0
        if let value = integer("borderstyle") { style.borderStyle = value }
        if let value = number("outline") { style.outline = value }
        if let value = number("shadow") { style.shadow = value }
        if let value = integer("alignment") { style.alignment = isLegacy ? numpadAlignment(legacy: value) : value }
        if let value = integer("marginl") { style.marginLeft = value }
        if let value = integer("marginr") { style.marginRight = value }
        if let value = integer("marginv") { style.marginVertical = value }
        if let value = integer("encoding") { style.encoding = value }
        return style
    }

    /// `&HAABBGGRR` (alpha 0 is opaque), `&HBBGGRR&`, or a decimal BGR number as SSA writes.
    static func color(_ field: String) -> SubtitleColor? {
        var digits = Substring(field.trimmingCharacters(in: .whitespaces))
        let value: UInt32
        if digits.lowercased().hasPrefix("&h") {
            digits = digits.dropFirst(2)
            while digits.hasSuffix("&") { digits = digits.dropLast() }
            guard let hex = UInt32(digits, radix: 16) else { return nil }
            value = hex
        } else {
            guard let decimal = Int64(digits) else { return nil }
            value = UInt32(truncatingIfNeeded: decimal)
        }
        return SubtitleColor(
            red: UInt8(value & 0xFF), green: UInt8(value >> 8 & 0xFF), blue: UInt8(value >> 16 & 0xFF),
            alpha: 255 - UInt8(value >> 24 & 0xFF)
        )
    }

    /// SSA numbers alignments 1 to 3 (bottom), 5 to 7 (top) and 9 to 11 (middle).
    static func numpadAlignment(legacy: Int) -> Int {
        switch legacy {
        case 5...7: legacy + 2
        case 9...11: legacy - 5
        default: legacy
        }
    }

    static func legacyAlignment(numpad: Int) -> Int {
        switch numpad {
        case 7...9: numpad - 2
        case 4...6: numpad + 5
        default: numpad
        }
    }

    /// Converts a Dialogue line's text to cue text, and reads the first alignment override.
    /// A bare `\r` (reset to the line's style) after `\i1` and the like closes them.
    static func cueText(fromASS raw: String) -> (String, CuePosition?) {
        var output = ""
        var position: CuePosition?
        var openStyles: [String] = []
        var index = raw.startIndex
        while index < raw.endIndex {
            let character = raw[index]
            if character == "{", let close = raw[index...].firstIndex(of: "}") {
                let inner = raw[raw.index(after: index)..<close]
                if let firstSlash = inner.firstIndex(of: "\\") {
                    var styleTags = ""
                    var residual = String(inner[..<firstSlash])
                    for tag in overrideTags(inner[firstSlash...]) {
                        if let converted = styleTag(tag) {
                            let name = String(tag.prefix(1))
                            if converted.hasPrefix("</") { openStyles.removeAll { $0 == name } } else { openStyles.append(name) }
                            styleTags += converted
                        } else if tag == "r", !openStyles.isEmpty {
                            styleTags += openStyles.reversed().map { "</\($0)>" }.joined()
                            openStyles = []
                        } else if position == nil, let alignment = alignment(tag) {
                            position = (7...9).contains(alignment) ? .top : .bottom
                        } else {
                            residual += "\\" + tag
                        }
                    }
                    output += styleTags
                    if !residual.isEmpty { output += "{\(residual)}" }
                } else {
                    output += raw[index...close]
                }
                index = raw.index(after: close)
                continue
            }
            let next = raw.index(after: index)
            if character == "\\", next < raw.endIndex, ["N", "n", "h"].contains(raw[next]) {
                output += raw[next] == "h" ? "\u{00A0}" : "\n"
                index = raw.index(after: next)
                continue
            }
            output += Markup.escape(String(character))
            index = next
        }
        return (output, position)
    }

    /// The tags of an override block after its first backslash, e.g. `\i1\t(\fs20)` gives `i1`, `t(\fs20)`.
    private static func overrideTags(_ block: Substring) -> [String] {
        var tags: [String] = []
        var current = ""
        var depth = 0
        for character in block {
            if character == "\\", depth == 0 {
                if !current.isEmpty { tags.append(current) }
                current = ""
                continue
            }
            if character == "(" { depth += 1 }
            if character == ")" { depth = max(depth - 1, 0) }
            current.append(character)
        }
        if !current.isEmpty { tags.append(current) }
        return tags
    }

    /// `<i>` for `i1`, `</i>` for `i0` or `i`, and the same for b (any weight), u and s.
    private static func styleTag(_ tag: String) -> String? {
        guard let name = tag.first.map(String.init), Markup.styleTags.contains(name) else { return nil }
        let argument = tag.dropFirst()
        guard argument.allSatisfy({ $0.isASCII && $0.isNumber }), name == "b" || argument.count <= 1 else { return nil }
        return argument.isEmpty || argument == "0" ? "</\(name)>" : "<\(name)>"
    }

    /// The numpad alignment of an `\anN` or legacy `\aN` tag.
    private static func alignment(_ tag: String) -> Int? {
        if tag.hasPrefix("an"), tag.count == 3, let value = Int(tag.dropFirst(2)), (1...9).contains(value) { return value }
        if tag.hasPrefix("a"), let value = Int(tag.dropFirst()), (1...11).contains(value) { return numpadAlignment(legacy: value) }
        return nil
    }

    // MARK: Writing

    static let assStyleFormat = [
        "Name", "Fontname", "Fontsize", "PrimaryColour", "SecondaryColour", "OutlineColour", "BackColour",
        "Bold", "Italic", "Underline", "StrikeOut", "ScaleX", "ScaleY", "Spacing", "Angle",
        "BorderStyle", "Outline", "Shadow", "Alignment", "MarginL", "MarginR", "MarginV", "Encoding",
    ]
    static let ssaStyleFormat = [
        "Name", "Fontname", "Fontsize", "PrimaryColour", "SecondaryColour", "TertiaryColour", "BackColour",
        "Bold", "Italic", "BorderStyle", "Outline", "Shadow", "Alignment", "MarginL", "MarginR", "MarginV",
        "AlphaLevel", "Encoding",
    ]
    static let assEventFormat = ["Layer", "Start", "End", "Style", "Name", "MarginL", "MarginR", "MarginV", "Effect", "Text"]
    static let ssaEventFormat = ["Marked", "Start", "End", "Style", "Name", "MarginL", "MarginR", "MarginV", "Effect", "Text"]

    /// Script Info keys written first, in this order; others follow sorted.
    private static let propertyOrder = ["Title", "Original Script", "WrapStyle", "ScaledBorderAndShadow", "YCbCr Matrix", "PlayResX", "PlayResY"]

    /// The header for tracks that come from formats without one: a 1920×1080 script.
    static let standardProperties = [
        "WrapStyle": "0", "ScaledBorderAndShadow": "yes", "YCbCr Matrix": "None", "PlayResX": "1920", "PlayResY": "1080",
    ]

    static func serialize(_ track: SubtitleTrack, variant: Variant) -> String {
        let properties = track.properties.isEmpty ? standardProperties : track.properties
        let styles = track.styles.isEmpty ? [SubtitleStyle.standard] : track.styles
        var output = "[Script Info]\n"
        if let title = properties["Title"] { output += "Title: \(title)\n" }
        output += "ScriptType: \(variant == .ass ? "v4.00+" : "v4.00")\n"
        let ordered = propertyOrder.dropFirst().filter { properties[$0] != nil }
        let others = properties.keys.filter { !propertyOrder.contains($0) }.sorted()
        for key in ordered + others { output += "\(key): \(properties[key]!)\n" }

        output += variant == .ass ? "\n[V4+ Styles]\n" : "\n[V4 Styles]\n"
        output += "Format: \((variant == .ass ? assStyleFormat : ssaStyleFormat).joined(separator: ", "))\n"
        for style in styles { output += "Style: \(styleFields(style, variant: variant).joined(separator: ","))\n" }

        output += "\n[Events]\n"
        output += "Format: \((variant == .ass ? assEventFormat : ssaEventFormat).joined(separator: ", "))\n"
        let defaultStyle = styles.first { $0.name == SubtitleStyle.defaultName } ?? styles[0]
        for cue in track.cues {
            let style = cue.style.flatMap { name in styles.first { $0.name == name } } ?? defaultStyle
            let fields = [
                variant == .ass ? "0" : "Marked=0",
                timestamp(cue.start), timestamp(cue.end),
                cue.style ?? style.name,
                (cue.speaker ?? "").replacing(",", with: " "),
                "0", "0", "0", "",
                assText(cue.text, override: cue.position == style.position ? nil : cue.position, variant: variant),
            ]
            output += "Dialogue: \(fields.joined(separator: ","))\n"
        }
        return output
    }

    private static func styleFields(_ style: SubtitleStyle, variant: Variant) -> [String] {
        func flag(_ value: Bool) -> String { value ? "-1" : "0" }
        func color(_ color: SubtitleColor) -> String {
            variant == .ass ? assColor(color) : String(Int(color.blue) << 16 | Int(color.green) << 8 | Int(color.red))
        }
        let head = [style.name, style.fontName, style.fontSize.compactDescription,
                    color(style.primaryColor), color(style.secondaryColor), color(style.outlineColor), color(style.backColor),
                    flag(style.isBold), flag(style.isItalic)]
        let margins = [String(style.marginLeft), String(style.marginRight), String(style.marginVertical)]
        switch variant {
        case .ass:
            return head + [flag(style.isUnderline), flag(style.isStrikeOut),
                           style.scaleX.compactDescription, style.scaleY.compactDescription,
                           style.spacing.compactDescription, style.angle.compactDescription,
                           String(style.borderStyle), style.outline.compactDescription, style.shadow.compactDescription,
                           String(style.alignment)] + margins + [String(style.encoding)]
        case .ssa:
            return head + [String(style.borderStyle), style.outline.compactDescription, style.shadow.compactDescription,
                           String(legacyAlignment(numpad: style.alignment))] + margins + ["0", String(style.encoding)]
        }
    }

    static func assColor(_ color: SubtitleColor) -> String {
        "&H" + [255 - color.alpha, color.blue, color.green, color.red].map { byte in
            let hex = String(byte, radix: 16, uppercase: true)
            return hex.count == 1 ? "0" + hex : hex
        }.joined()
    }

    /// `H:MM:SS.cc`, rounded to the nearest centisecond.
    static func timestamp(_ time: MediaTime) -> String {
        let centiseconds = (2 * max(time.value, 0) * 100 + time.timescale) / (2 * time.timescale)
        let seconds = centiseconds / 100
        func two(_ value: Int64) -> String { value < 10 ? "0\(value)" : "\(value)" }
        return "\(seconds / 3600):\(two(seconds / 60 % 60)):\(two(seconds % 60)).\(two(centiseconds % 100))"
    }

    /// Cue text as a Dialogue line's text, with an alignment override when the
    /// cue's position differs from its style's.
    static func assText(_ text: String, override: CuePosition?, variant: Variant) -> String {
        var output = ""
        if let override {
            let numpad = override == .top ? 8 : 2
            output += variant == .ass ? "{\\an\(numpad)}" : "{\\a\(legacyAlignment(numpad: numpad))}"
        }
        for token in Markup.tokens(of: text) {
            switch token {
            case .text(let text): output += text.replacing("\u{00A0}", with: "\\h")
            case .lineBreak: output += "\\N"
            case .tag(let name, let closing): output += "{\\\(name)\(closing ? 0 : 1)}"
            case .otherTag: continue
            case .override(let block): output += block
            }
        }
        return output
    }
}

/// A named text style, as ASS/SSA files define them in `[V4+ Styles]`.
///
/// Sizes and margins are in the script's own resolution (`PlayResX` and
/// `PlayResY` in the track's properties).
public struct SubtitleStyle: Hashable, Sendable, Codable, Identifiable {
    public var id: String { name }
    public var name: String
    public var fontName: String
    public var fontSize: Double
    public var primaryColor: SubtitleColor
    /// The karaoke fill color.
    public var secondaryColor: SubtitleColor
    public var outlineColor: SubtitleColor
    /// Shadow, or the box behind the text with `borderStyle` 3.
    public var backColor: SubtitleColor
    public var isBold: Bool
    public var isItalic: Bool
    public var isUnderline: Bool
    public var isStrikeOut: Bool
    /// Horizontal and vertical scale in percent.
    public var scaleX: Double
    public var scaleY: Double
    /// Extra space between letters, in pixels.
    public var spacing: Double
    /// Rotation in degrees.
    public var angle: Double
    /// 1: outline and drop shadow; 3: opaque box.
    public var borderStyle: Int
    public var outline: Double
    public var shadow: Double
    /// Where text sits, as on a numeric keypad: 1 to 3 bottom, 4 to 6 middle, 7 to 9 top.
    public var alignment: Int
    public var marginLeft: Int
    public var marginRight: Int
    public var marginVertical: Int
    /// The font's character set (1 is the default, 178 Arabic).
    public var encoding: Int

    public init(
        name: String,
        fontName: String = "Arial",
        fontSize: Double = 64,
        primaryColor: SubtitleColor = .white,
        secondaryColor: SubtitleColor = SubtitleColor(red: 255, green: 0, blue: 0),
        outlineColor: SubtitleColor = .black,
        backColor: SubtitleColor = SubtitleColor(red: 0, green: 0, blue: 0, alpha: 128),
        isBold: Bool = false,
        isItalic: Bool = false,
        isUnderline: Bool = false,
        isStrikeOut: Bool = false,
        scaleX: Double = 100,
        scaleY: Double = 100,
        spacing: Double = 0,
        angle: Double = 0,
        borderStyle: Int = 1,
        outline: Double = 3,
        shadow: Double = 0,
        alignment: Int = 2,
        marginLeft: Int = 96,
        marginRight: Int = 96,
        marginVertical: Int = 54,
        encoding: Int = 1
    ) {
        self.name = name
        self.fontName = fontName
        self.fontSize = fontSize
        self.primaryColor = primaryColor
        self.secondaryColor = secondaryColor
        self.outlineColor = outlineColor
        self.backColor = backColor
        self.isBold = isBold
        self.isItalic = isItalic
        self.isUnderline = isUnderline
        self.isStrikeOut = isStrikeOut
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.spacing = spacing
        self.angle = angle
        self.borderStyle = borderStyle
        self.outline = outline
        self.shadow = shadow
        self.alignment = alignment
        self.marginLeft = marginLeft
        self.marginRight = marginRight
        self.marginVertical = marginVertical
        self.encoding = encoding
    }

    public static let defaultName = "Default"

    /// White text with a black outline, bottom center, sized for a 1920×1080
    /// script with margins at the title-safe area (5% of the picture).
    public static let standard = SubtitleStyle(name: defaultName)

    /// Top for alignments 7 to 9, else bottom.
    public var position: CuePosition { (7...9).contains(alignment) ? .top : .bottom }
}

/// An 8-bit RGB color with opacity (255 is opaque).
public struct SubtitleColor: Hashable, Sendable, Codable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8
    public var alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let white = SubtitleColor(red: 255, green: 255, blue: 255)
    public static let black = SubtitleColor(red: 0, green: 0, blue: 0)
}

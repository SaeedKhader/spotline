import Foundation

/// What the AI script review found wrong with a transcribed line: the words it
/// doubts, one or more fixed lines with how sure it is of each, and why. Nothing
/// is applied until the user tries a fix and confirms it, or keeps the line.
public struct ScriptFinding: Hashable, Sendable, Codable {
    /// One way to fix the line: the whole line as it would read.
    public struct Fix: Hashable, Sendable, Codable {
        public var text: String
        /// 0 to 1.
        public var confidence: Double

        public init(text: String, confidence: Double) {
            self.text = text
            self.confidence = confidence
        }
    }

    /// The words it doubts, as the line has them ("Aron").
    public var words: [String]
    /// Most likely first.
    public var fixes: [Fix]
    /// Why, in a line: "The brief spells him Arlan, and he is named 12 times".
    public var reason: String
    /// The line as it was reviewed, to go back to when a tried fix is not kept.
    public var original: String
    /// The fix in the line now, while it is being tried.
    public var tried: Int?

    public init(words: [String] = [], fixes: [Fix], reason: String, original: String, tried: Int? = nil) {
        self.words = words
        self.fixes = fixes
        self.reason = reason
        self.original = original
        self.tried = tried
    }

    /// How sure the review is of its best fix.
    public var confidence: Double { fixes.map(\.confidence).max() ?? 0 }
}

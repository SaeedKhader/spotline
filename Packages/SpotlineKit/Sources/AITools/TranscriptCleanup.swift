import Foundation
import SubtitleCore

/// What a subtitler leaves out of a transcript: hesitations ("um", "uh"),
/// stutters ("I... I", "w-what"), cues that are only an interjection ("Oh.",
/// "Hmm."), and words the transcriber stretched over music. The professional
/// subtitles of the akotsk review had none of these; Spotline's had one short
/// cue in fifteen made of them (docs/ARCHITECTURE.md, 7a).
public enum TranscriptCleanup {
    /// Hesitation sounds, dropped wherever they are.
    static let hesitations: Set<String> = ["um", "umm", "uh", "uhh", "er", "erm", "hmm", "hmmm", "hm", "mm", "mmm", "mmmm"]
    /// Sounds that make no cue of their own; inside a sentence they stay ("Oh, I see").
    static let interjections: Set<String> = hesitations.union([
        "oh", "ah", "aah", "ahh", "huh", "whoa", "ooh", "oof", "ugh", "aw", "eh", "woo", "whoo", "ha", "haha", "phew", "argh", "ow", "mhm",
    ])
    /// Short words said twice on purpose ("No, no"), never taken for a stutter.
    static let repeatedOnPurpose: Set<String> = ["no", "yes", "go", "hey", "oh", "ha", "run", "now", "yeah", "hi", "bye", "ho", "na", "la", "oi", "yay"]

    /// A word lasts at most this long, plus a little per letter: a longer one
    /// is the transcriber stretching it over music or noise.
    static let maxWordSeconds = 0.5
    static let secondsPerLetter = 0.12

    /// The words without hesitations or stutters, and with stretched words shortened.
    public static func words(_ words: [TranscribedWord]) -> [TranscribedWord] {
        var result: [TranscribedWord] = []
        for (index, word) in words.enumerated() {
            let key = letters(word.text)
            let next = index + 1 < words.count ? words[index + 1] : nil
            if hesitations.contains(key) {
                // Its closing punctuation goes to the word before ("so, um." → "so.").
                if let mark = closingMark(word.text), var last = result.popLast() {
                    if closingMark(last.text) == nil { last.text = last.text.trimmingCharacters(in: [","]) + mark }
                    result.append(last)
                }
                continue
            }
            if let next, isStutter(word.text, before: next.text) { continue }
            var word = word
            if let hyphen = word.text.firstIndex(of: "-"), isStutteredStart(word.text, hyphen: hyphen) {
                var rest = String(word.text[word.text.index(after: hyphen)...])
                if word.text.first?.isUppercase == true, let first = rest.first { rest = first.uppercased() + rest.dropFirst() }
                word.text = rest
            }
            let longest = maxWordSeconds + secondsPerLetter * Double(max(key.count, 1))
            if (word.end - word.start).seconds > longest {
                word.end = word.start + MediaTime(value: Int64((longest * 1000).rounded()), timescale: 1000)
            }
            result.append(word)
        }
        return result
    }

    /// True when the cue is only interjections and punctuation.
    public static func isOnlyInterjections(_ text: String) -> Bool {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0 == "-" }).map { letters(String($0)) }.filter { !$0.isEmpty }
        return !words.isEmpty && words.allSatisfy(interjections.contains)
    }

    /// "I," before "I", "the..." before "the", "D-" before "Duncan".
    static func isStutter(_ word: String, before next: String) -> Bool {
        let key = letters(word), nextKey = letters(next)
        guard !key.isEmpty else { return false }
        let trimmed = word.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("-") || trimmed.hasSuffix("—") { return nextKey.hasPrefix(key) }
        guard key == nextKey, key.count <= 3, !repeatedOnPurpose.contains(key) else { return false }
        return trimmed.hasSuffix(",") || trimmed.hasSuffix("...") || trimmed.hasSuffix("…")
    }

    /// "w-what", "I-I": a letter or two, a hyphen, then the word they begin.
    static func isStutteredStart(_ word: String, hyphen: String.Index) -> Bool {
        let head = letters(String(word[..<hyphen])), rest = letters(String(word[word.index(after: hyphen)...]))
        return !head.isEmpty && head.count <= 2 && rest.count > head.count && rest.hasPrefix(head)
    }

    static func closingMark(_ word: String) -> String? {
        guard let last = word.trimmingCharacters(in: .whitespaces).last, ".?!…".contains(last) else { return nil }
        return String(last)
    }

    /// Lowercased letters and apostrophes only.
    static func letters(_ word: String) -> String {
        String(word.lowercased().filter { $0.isLetter || $0 == "'" })
    }
}

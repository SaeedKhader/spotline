import Foundation
import QualityControl
import SubtitleCore

/// A word a transcriber heard, with when it was said.
public struct TranscribedWord: Sendable, Equatable, Codable {
    public var text: String
    public var start: MediaTime
    public var end: MediaTime

    public init(text: String, start: MediaTime, end: MediaTime) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// Groups transcribed words into cues that already follow the QC preset: line
/// length and count, duration, gaps, and starts and ends on nearby shot changes.
/// This is Spotline's own code, not the model's (docs/ARCHITECTURE.md, 7a).
public struct CueSegmenter: Sendable {
    public var preset: QCPreset
    public var frameRate: FrameRate
    /// Shot changes as frame numbers.
    public var shotChanges: [Int64]
    /// A pause this long always starts a new cue.
    public var pauseSeconds = 0.8
    /// How long a cue stays up after its last word, room permitting.
    public var lingerSeconds = 0.5

    public init(preset: QCPreset, frameRate: FrameRate, shotChanges: [Int64] = []) {
        self.preset = preset
        self.frameRate = frameRate
        self.shotChanges = shotChanges
    }

    var maxLineLength: Int { preset.maxCharactersPerLine ?? 42 }
    var maxLines: Int { preset.maxLines ?? 2 }
    var maxDuration: Double { preset.maximumDuration?.seconds ?? 7 }
    var minDuration: Double { preset.minimumDuration?.seconds ?? 5.0 / 6 }

    /// Cues for the words, in order. Words must be in time order.
    public func cues(from words: [TranscribedWord]) -> [Cue] {
        let groups = group(words.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty })
        var frames: [(start: Int64, end: Int64, text: String)] = groups.map { group in
            (group.first!.start.firstFrame(at: frameRate), group.last!.end.firstFrame(at: frameRate), Self.layout(group.map(\.text), maxLineLength: maxLineLength))
        }
        time(&frames)
        return frames.map { Cue(start: MediaTime(frame: $0.start, rate: frameRate), end: MediaTime(frame: $0.end, rate: frameRate), text: $0.text) }
    }

    /// Splits the words where a cue has to end: a long pause, the text or
    /// duration limit, or (once a cue has some text) the end of a sentence.
    func group(_ words: [TranscribedWord]) -> [[TranscribedWord]] {
        let maxCharacters = maxLineLength * maxLines
        var groups: [[TranscribedWord]] = []
        var current: [TranscribedWord] = []
        for word in words {
            if let last = current.last, let first = current.first {
                let text = Self.join(current.map(\.text) + [word.text])
                let pause = (word.start - last.end).seconds
                let tooLong = text.count > maxCharacters || (word.end - first.start).seconds > maxDuration
                let sentenceEnded = Self.endsSentence(last.text) && Self.join(current.map(\.text)).count >= maxLineLength / 2
                // Two lines of text never fit one line's layout when a line would overflow.
                let unbreakable = Self.layout(current.map(\.text) + [word.text], maxLineLength: maxLineLength)
                    .split(separator: "\n").contains { $0.count > maxLineLength }
                if pause >= pauseSeconds || tooLong || sentenceEnded || unbreakable {
                    groups.append(current)
                    current = []
                }
            }
            current.append(word)
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    /// Word lists are joined with spaces, except before punctuation.
    static func join(_ words: [String]) -> String {
        var text = ""
        for word in words.map({ $0.trimmingCharacters(in: .whitespaces) }) where !word.isEmpty {
            if !text.isEmpty, let first = word.first, !",.!?;:…%)»”".contains(first) { text += " " }
            text += word
        }
        return text
    }

    static func endsSentence(_ word: String) -> Bool {
        guard let last = word.trimmingCharacters(in: .whitespaces).last else { return false }
        return ".?!…。？！؟".contains(last)
    }

    /// One line when it fits, else two lines broken at the space that best
    /// balances them, preferring a break after punctuation (a bottom-heavy pyramid).
    static func layout(_ words: [String], maxLineLength: Int) -> String {
        let text = join(words)
        guard text.count > maxLineLength else { return text }
        let spaces = text.indices.filter { text[$0] == " " }
        guard !spaces.isEmpty else { return text }
        let best = spaces.min { score(text, at: $0) < score(text, at: $1) }!
        return String(text[..<best]) + "\n" + String(text[text.index(after: best)...])
    }

    private static func score(_ text: String, at space: String.Index) -> Double {
        let first = text.distance(from: text.startIndex, to: space)
        let second = text.count - first - 1
        var score = Double(abs(first - second))
        // Prefer a shorter top line, and a break after a comma or full stop.
        if first > second { score += 2 }
        if space > text.startIndex, ",.;:!?؟،".contains(text[text.index(before: space)]) { score -= 6 }
        return score
    }

    /// Ends cues a little after their last word, stretches short ones to the
    /// minimum duration, keeps the minimum gap and snaps to nearby shot changes.
    func time(_ cues: inout [(start: Int64, end: Int64, text: String)]) {
        let gap = preset.minimumGapFrames
        let linger = Int64((lingerSeconds * frameRate.framesPerSecond).rounded())
        let minimum = Int64((minDuration * frameRate.framesPerSecond).rounded(.up))
        let maximum = Int64((maxDuration * frameRate.framesPerSecond).rounded(.down))
        let snap = preset.shotChangeFrames ?? 0
        for index in cues.indices {
            var start = cues[index].start
            var end = max(cues[index].end, start + 1) + linger
            let previousEnd = index > 0 ? cues[index - 1].end : Int64.min
            let nextStart = index + 1 < cues.count ? cues[index + 1].start : Int64.max
            if snap > 0 {
                if let shot = shotChanges.first(where: { abs($0 - start) < snap && $0 >= previousEnd + gap }), shot < end {
                    start = shot
                }
                if let shot = shotChanges.first(where: { $0 > start && abs($0 - end) < snap }) {
                    end = max(shot - gap, start + 1)
                }
            }
            end = max(end, start + minimum)
            end = min(end, start + maximum, nextStart - gap)
            end = max(end, start + 1)
            cues[index].start = start
            cues[index].end = end
        }
    }
}

/// Builds cues while words are still arriving, so a transcription can be
/// reviewed as it goes. A cue is shown once the word after it has been heard
/// (only then is it complete); each keeps its ID as more words arrive, so a
/// cue accepted early is not proposed again. Safe to call from any thread.
public final class TranscriptAccumulator: @unchecked Sendable {
    private let segmenter: CueSegmenter
    private let lock = NSLock()
    private var words: [TranscribedWord] = []
    /// IDs by start frame, kept between calls.
    private var ids: [Int64: Cue.ID] = [:]

    public init(segmenter: CueSegmenter) {
        self.segmenter = segmenter
    }

    /// Adds words (in time order) and returns the cues complete so far.
    public func add(_ new: [TranscribedWord]) -> [Cue] {
        lock.withLock {
            words += new
            words.sort { $0.start < $1.start }
            return identified(Array(segmenter.cues(from: words).dropLast()))
        }
    }

    /// Every cue, once all words are in.
    public func finish(with all: [TranscribedWord]? = nil) -> [Cue] {
        lock.withLock {
            if let all { words = all.sorted { $0.start < $1.start } }
            return identified(segmenter.cues(from: words))
        }
    }

    private func identified(_ cues: [Cue]) -> [Cue] {
        cues.map { cue in
            let frame = cue.start.firstFrame(at: segmenter.frameRate)
            let id = ids[frame] ?? cue.id
            ids[frame] = id
            return Cue(id: id, start: cue.start, end: cue.end, text: cue.text)
        }
    }
}

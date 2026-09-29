import Foundation
import QualityControl
import SubtitleCore

/// A word a transcriber heard, with when it was said.
public struct TranscribedWord: Sendable, Equatable, Codable {
    public var text: String
    public var start: MediaTime
    public var end: MediaTime
    /// Who said it ("speaker_0"), when the transcriber tells speakers apart.
    public var speaker: String?

    public init(text: String, start: MediaTime, end: MediaTime, speaker: String? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.speaker = speaker
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
    /// A sentence shorter than this never ends a cue (see `endsCue`).
    public var sentenceCharacters = 8
    /// How long a cue stays up after its last word, room permitting.
    public var lingerSeconds = 0.5
    /// A gap shorter than this to the next cue closes to the preset's minimum
    /// gap (chaining), so cues do not flash off and on between lines.
    public var chainSeconds = 0.5
    /// How far after the first word a cue may start to land on a shot change.
    public var maxLateStartSeconds = 0.15

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
            (group.first!.start.firstFrame(at: frameRate), group.last!.end.firstFrame(at: frameRate), text(of: group))
        }
        time(&frames)
        return zip(frames, groups).map { frame, group in
            Cue(
                start: MediaTime(frame: frame.start, rate: frameRate), end: MediaTime(frame: frame.end, rate: frameRate), text: frame.text,
                voices: Self.voices(of: group)
            )
        }
    }

    /// Who says the words, one label per turn, nil when the transcriber did not tell voices apart.
    static func voices(of words: [TranscribedWord]) -> [String]? {
        let voices = turns(words).compactMap { $0.first(where: { $0.speaker != nil })?.speaker }
        return voices.isEmpty ? nil : voices
    }

    /// A cue's text: two balanced lines at most, or, when two people speak
    /// in it, a line for each starting with a dash ("- Hi.\n- Hello.").
    func text(of words: [TranscribedWord]) -> String {
        let turns = Self.turns(words)
        guard turns.count == 2 else { return Self.layout(words.map(\.text), maxLineLength: maxLineLength) }
        return turns.map { "- " + Self.join($0.map(\.text)) }.joined(separator: "\n")
    }

    /// The words split where the speaker changes. Words without a speaker belong to the one before.
    static func turns(_ words: [TranscribedWord]) -> [[TranscribedWord]] {
        var turns: [[TranscribedWord]] = []
        for word in words {
            if let speaker = word.speaker, let previous = turns.last?.last(where: { $0.speaker != nil })?.speaker, speaker != previous {
                turns.append([word])
            } else if turns.isEmpty {
                turns.append([word])
            } else {
                turns[turns.count - 1].append(word)
            }
        }
        return turns
    }

    /// Splits the words where a cue has to end: a long pause, the text or
    /// duration limit, (once a cue has some text) the end of a sentence, or a
    /// new speaker who does not fit a two-line dialogue cue.
    func group(_ words: [TranscribedWord]) -> [[TranscribedWord]] {
        let maxCharacters = maxLineLength * maxLines
        // A dialogue line starts with "- ".
        let maxDialogueLine = maxLineLength - 2
        var groups: [[TranscribedWord]] = []
        var current: [TranscribedWord] = []
        for word in words {
            if let last = current.last, let first = current.first {
                let turns = Self.turns(current + [word])
                let pause = (word.start - last.end).seconds
                let tooLong: Bool
                let unbreakable: Bool
                let sentenceEnded: Bool
                if turns.count > 1 {
                    // A dialogue cue: two speakers, a line each.
                    tooLong = turns.count > 2 || (word.end - first.start).seconds > maxDuration
                    unbreakable = turns.contains { Self.join($0.map(\.text)).count > maxDialogueLine }
                    let newSpeaker = turns.count == 2 && turns[1].count == 1
                    sentenceEnded = (Self.endsSentence(last.text) || newSpeaker) && endsCue(current, before: word, speakerChanges: newSpeaker)
                } else {
                    tooLong = Self.join(current.map(\.text) + [word.text]).count > maxCharacters || (word.end - first.start).seconds > maxDuration
                    // Two lines of text never fit one line's layout when a line would overflow.
                    unbreakable = Self.layout(current.map(\.text) + [word.text], maxLineLength: maxLineLength)
                        .split(separator: "\n").contains { $0.count > maxLineLength }
                    sentenceEnded = Self.endsSentence(last.text) && endsCue(current, before: word)
                }
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

    /// Whether a finished sentence makes a cue of its own: a long one always,
    /// a short one when it can be read in the time until the next word (so
    /// splitting does not make cues too fast or too short). Before a new
    /// speaker, only when it can be read: else the two make a dialogue cue.
    func endsCue(_ words: [TranscribedWord], before next: TranscribedWord, speakerChanges: Bool = false) -> Bool {
        let characters = Self.join(words.map(\.text)).count
        if characters >= maxLineLength / 2, !speakerChanges { return true }
        guard characters >= sentenceCharacters else { return false }
        let seconds = (next.start - words[0].start).seconds - Double(preset.minimumGapFrames) / frameRate.framesPerSecond
        // A new speaker gets a cue of their own whenever the line before can stay up the minimum time.
        let speed = speakerChanges ? .infinity : preset.maxCharactersPerSecond ?? .infinity
        return seconds >= minDuration && Double(characters) / seconds <= speed
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

    /// Ends cues a little after their last word, or long enough to be read at
    /// the preset's reading speed, stretches short ones to the minimum
    /// duration, closes short gaps (chaining), keeps the minimum gap and snaps
    /// to nearby shot changes.
    func time(_ cues: inout [(start: Int64, end: Int64, text: String)]) {
        let rate = frameRate.framesPerSecond
        let gap = preset.minimumGapFrames
        let linger = Int64((lingerSeconds * rate).rounded())
        let chain = Int64((chainSeconds * rate).rounded())
        let minimum = Int64((minDuration * rate).rounded(.up))
        let maximum = Int64((maxDuration * rate).rounded(.down))
        let snap = preset.shotChangeFrames ?? 0
        let lateStart = Int64((maxLateStartSeconds * rate).rounded())
        for index in cues.indices {
            var start = cues[index].start
            var end = max(cues[index].end, start + 1) + linger
            let previousEnd = index > 0 ? cues[index - 1].end : Int64.min
            let nextStart = index + 1 < cues.count ? cues[index + 1].start : Int64.max
            // A cue may start early on a shot change, but only a little late: text after the voice reads as lag.
            if snap > 0, let shot = shotChanges.first(where: { $0 - start < lateStart && start - $0 < snap && $0 >= previousEnd + gap }),
               shot < end {
                start = shot
            }
            end = max(end, start + minimum)
            if let speed = preset.maxCharactersPerSecond, speed > 0 {
                let characters = cues[index].text.filter { !$0.isNewline }.count
                end = max(end, start + Int64((Double(characters) / speed * rate).rounded(.up)))
            }
            if nextStart != Int64.max, nextStart - gap - end < chain { end = max(end, nextStart - gap) }
            end = min(end, start + maximum, nextStart - gap)
            // Last, the end moves onto a nearby shot change (the minimum gap before it).
            if snap > 0, let shot = shotChanges.first(where: { $0 - gap > start && abs($0 - gap - end) < snap }) {
                end = min(shot - gap, nextStart - gap)
            }
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
    private let pipeline: TranscriptionPipeline
    private let lock = NSLock()
    private var words: [TranscribedWord] = []
    /// IDs by start frame, kept between calls.
    private var ids: [Int64: Cue.ID] = [:]

    public init(pipeline: TranscriptionPipeline) {
        self.pipeline = pipeline
    }

    /// Adds words (in time order) and returns the cues complete so far.
    public func add(_ new: [TranscribedWord]) -> [Cue] {
        lock.withLock {
            words += new
            words.sort { $0.start < $1.start }
            return identified(Array(pipeline.cues(from: words).dropLast()))
        }
    }

    /// Every cue, once all words are in.
    public func finish(with all: [TranscribedWord]? = nil) -> [Cue] {
        lock.withLock {
            if let all { words = all.sorted { $0.start < $1.start } }
            return identified(pipeline.cues(from: words))
        }
    }

    private func identified(_ cues: [Cue]) -> [Cue] {
        cues.map { cue in
            let frame = cue.start.firstFrame(at: pipeline.segmenter.frameRate)
            let id = ids[frame] ?? cue.id
            ids[frame] = id
            return Cue(id: id, start: cue.start, end: cue.end, text: cue.text, voices: cue.voices)
        }
    }
}

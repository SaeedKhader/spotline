import AITools
import SubtitleCore

/// Where a cue could be split in two: at a pause the transcript's word times show,
/// best at a cut, a change of speaker or the end of a sentence.
public struct PauseSplit: Hashable, Sendable {
    /// The first half's end (through the pause, the minimum gap before the second) and the
    /// second half's start (the next word, or a cut in the pause), a frame boundary each.
    public var firstEnd: MediaTime
    public var secondStart: MediaTime
    /// Each half's words, as one line (rebalanced later to fit).
    public var first: String
    public var second: String
    /// The word the first half ends with.
    public var after: String
    /// How long the speaker pauses there; nil without word times.
    public var pause: MediaTime?
    public var isAtCut: Bool
    public var isSpeakerChange: Bool
}

enum PauseSplitter {
    /// Split points for a cue, best first: every gap between two words, scored by how long
    /// the pause is, whether a cut or a change of speaker falls in it, whether a sentence or
    /// clause ends there, and how even the halves are. With no word times for the cue's words
    /// (a translation, a file imported without a transcript), gaps after punctuation only,
    /// with the time shared out by characters.
    static func splits(
        of cue: Cue, words transcript: [TranscribedWord], rate: FrameRate, shotChanges: [Int64], gapFrames: Int64
    ) -> [PauseSplit] {
        let lines = SubtitleText.visibleLines(of: cue.text)
        // Markup and dialogue keep their own lines: not split here.
        guard lines.joined(separator: "\n") == cue.text, !SubtitleText.isDialogue(lines) else { return [] }
        let words = cue.text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count > 1 else { return [] }
        let times = wordTimes(words, in: transcript.filter { $0.end > cue.start - .oneSecond && $0.start < cue.end + .oneSecond })
        let total = words.reduce(0) { $0 + $1.count }
        let gap = MediaTime(frame: gapFrames, rate: rate)
        var scored: [(PauseSplit, Double)] = []
        var before = 0
        for index in 0..<(words.count - 1) {
            before += words[index].count
            let word = words[index]
            let ending = word.last.map { ".?!…".contains($0) ? 3.0 : ",;:—–-".contains($0) ? 1.5 : 0 } ?? 0
            let balance = -2.0 * abs(Double(before) / Double(total) - 0.5)
            var split: PauseSplit
            var score = ending + balance
            if let times, let this = times[index], let next = times[index + 1] {
                let pause = next.start > this.end ? next.start - this.end : .zero
                let cut = shotChanges.first { MediaTime(frame: $0, rate: rate) > this.end && MediaTime(frame: $0, rate: rate) <= next.start }
                let speakerChange = this.speaker != nil && next.speaker != nil && this.speaker != next.speaker
                // The second half starts with the next word (or at a cut in the pause); the first
                // stays up through the pause, until the minimum gap before it.
                let secondStart = cut.map { MediaTime(frame: $0, rate: rate) } ?? frame(next.start, rate)
                let firstEnd = secondStart - gap
                guard firstEnd > cue.start, secondStart < cue.end else { continue }
                score += pause.seconds * 10 + (cut != nil ? 5 : 0) + (speakerChange ? 10 : 0)
                split = PauseSplit(
                    firstEnd: firstEnd, secondStart: secondStart, first: words[...index].joined(separator: " "),
                    second: words[(index + 1)...].joined(separator: " "), after: word, pause: pause, isAtCut: cut != nil,
                    isSpeakerChange: speakerChange
                )
            } else {
                // No word times: only at punctuation, the time shared out by characters.
                guard times == nil, ending > 0 else { continue }
                let at = cue.start + MediaTime(seconds: cue.duration.seconds * Double(before) / Double(total))
                let secondStart = frame(at, rate)
                let firstEnd = secondStart - gap
                guard firstEnd > cue.start, secondStart < cue.end else { continue }
                split = PauseSplit(
                    firstEnd: firstEnd, secondStart: secondStart, first: words[...index].joined(separator: " "),
                    second: words[(index + 1)...].joined(separator: " "), after: word, pause: nil, isAtCut: false, isSpeakerChange: false
                )
            }
            scored.append((split, score))
        }
        return scored.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// The split at the gap between words nearest `time` (Cue › Split Cue at the playhead):
    /// nil without word times for the cue's words.
    static func split(
        of cue: Cue, words transcript: [TranscribedWord], near time: MediaTime, rate: FrameRate, shotChanges: [Int64], gapFrames: Int64
    ) -> PauseSplit? {
        let words = cue.text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let times = wordTimes(words, in: transcript.filter { $0.end > cue.start - .oneSecond && $0.start < cue.end + .oneSecond }) else { return nil }
        func distance(_ split: PauseSplit) -> Double {
            guard let index = words.indices.dropLast().first(where: { words[...$0].joined(separator: " ") == split.first }),
                  let this = times[index], let next = times[index + 1]
            else { return .infinity }
            if time < this.end { return (this.end - time).seconds }
            if time > next.start { return (time - next.start).seconds }
            return 0
        }
        return splits(of: cue, words: transcript, rate: rate, shotChanges: shotChanges, gapFrames: gapFrames)
            .filter { $0.pause != nil }
            .min { distance($0) < distance($1) }
    }

    /// The transcript's times for each of the cue's words, matched in order by their letters;
    /// nil when too few match to trust (the cue is not the transcript's words).
    static func wordTimes(_ words: [String], in transcript: [TranscribedWord]) -> [TranscribedWord?]? {
        func key(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        var result: [TranscribedWord?] = []
        var next = 0
        for word in words {
            let wanted = key(word)
            // Look a few words ahead: the transcript may have words the cue leaves out.
            if let found = transcript[next...].prefix(4).firstIndex(where: { key($0.text) == wanted }), !wanted.isEmpty {
                result.append(transcript[found])
                next = found + 1
            } else {
                result.append(nil)
            }
        }
        let matched = result.compactMap { $0 }.count
        return matched * 10 >= words.count * 7 ? result : nil
    }

    private static func frame(_ time: MediaTime, _ rate: FrameRate) -> MediaTime {
        MediaTime(frame: time.firstFrame(at: rate), rate: rate)
    }
}

extension MediaTime {
    /// Words a little outside a cue still belong to it (cues are timed by hand, or rounded).
    static let oneSecond = MediaTime(value: 1, timescale: 1)
}

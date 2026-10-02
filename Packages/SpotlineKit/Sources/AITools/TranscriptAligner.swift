import Foundation
import SubtitleCore

/// What listening to the audio adds to a subtitle file's cues: for each cue, the
/// transcriber's words that are its words (when each is said, and who says it), what
/// was heard there instead when the two differ, and whether the whole file runs early,
/// late or at another speed than the audio.
public struct TranscriptAlignment: Sendable, Equatable {
    /// One cue against the audio.
    public struct CueMatch: Sendable, Equatable {
        public var cueID: Cue.ID
        /// The cue's words (sound descriptions and speaker labels left out), and for
        /// each the transcriber's word it is, nil when it was not heard.
        public var words: [String]
        public var heardAs: [TranscribedWord?]
        /// Everything the transcriber heard between the words before and after this cue's.
        public var heard: [TranscribedWord]

        /// How many of the cue's words were heard.
        public var matched: Int { heardAs.count(where: { $0 != nil }) }

        /// From the first word heard to the last; nil when none was.
        public var spoken: (start: MediaTime, end: MediaTime)? {
            let found = heardAs.compactMap(\.self)
            guard let first = found.first, let last = found.last else { return nil }
            return (first.start, last.end)
        }
    }

    public var cues: [CueMatch]
    /// How many words the transcriber heard (sound descriptions left out).
    public var heardCount: Int
    /// The same shift and speed for every cue that puts the file on the audio; nil
    /// when it is on it already, or no one correction fits.
    public var sync: SubtitleSync?

    /// The share of the cues' words that were heard, 0 to 1.
    public var matchedShare: Double {
        let total = cues.reduce(0) { $0 + $1.words.count }
        return total == 0 ? 0 : Double(cues.reduce(0) { $0 + $1.matched }) / Double(total)
    }

    /// The share of what was heard that the cues have, 0 to 1: high for a subtitle
    /// file of this video, low for a few cues typed by hand or another video's file.
    public var heardShare: Double {
        heardCount == 0 ? 0 : Double(cues.reduce(0) { $0 + $1.matched }) / Double(heardCount)
    }

    /// Whether the cues are this audio's subtitles: they have most of what is said.
    public var coversAudio: Bool { heardShare >= 0.5 }
}

/// A correction of a whole subtitle file's timing: every time becomes `time × speed + offset`.
public struct SubtitleSync: Sendable, Equatable {
    /// Seconds added to every time; negative when the subtitles are late.
    public var offset: Double
    /// 1 unless the file was timed to another frame rate (25 fps subtitles on a 23.976 fps video).
    public var speed: Double
    /// How many cues it was worked out from.
    public var samples: Int

    public init(offset: Double, speed: Double = 1, samples: Int = 0) {
        self.offset = offset
        self.speed = speed
        self.samples = samples
    }

    public func corrected(_ time: MediaTime, rate: FrameRate) -> MediaTime {
        let seconds = max(0, time.seconds * speed + offset)
        return MediaTime(frame: MediaTime(seconds: seconds).nearestFrame(at: rate), rate: rate)
    }

    /// "The subtitles are 1.2 s late." / "… drift: 2.1 s early at the start, 4.0 s late by the end."
    public func summary(over duration: Double) -> String {
        func side(_ seconds: Double) -> String {
            String(format: "%.1f s %@", abs(seconds), seconds < 0 ? "late" : "early")
        }
        guard speed != 1 else { return "The subtitles are \(side(offset))." }
        let end = duration * (speed - 1) + offset
        return "The subtitles drift against the audio: \(side(offset)) at the start, \(side(end)) by the end."
    }
}

/// Lines a real subtitle file up with a transcriber's words, by the words themselves:
/// the file's timing may be off, and it leaves out or rewords some of what is said.
public enum TranscriptAligner {
    /// How long before its first word a cue usually comes up (subtitles lead the voice a little,
    /// on purpose): a synced file keeps that lead.
    static let usualLead = 0.15
    /// A shift smaller than this is left alone.
    static let smallestOffset = 0.3
    /// The corrected file must sit this close to the audio for most cues, or no one correction fits.
    static let largestSpread = 0.5
    /// Words closer together than this are said in one go.
    static let pauseSeconds = 0.8
    /// Frame-rate mix-ups: the speed is one of these when it is close to one.
    static let knownSpeeds: [Double] = [25.0 / 23.976, 23.976 / 25.0, 24.0 / 23.976, 23.976 / 24.0, 25.0 / 24.0, 24.0 / 25.0]

    /// `words` in time order. Cues in time order.
    public static func align(_ cues: [Cue], to words: [TranscribedWord]) -> TranscriptAlignment {
        let heard = words.filter { !key($0.text).isEmpty && !TranscriptionPipeline.isSoundDescription($0.text) }
        // Every cue word in one sequence, each knowing its cue.
        var cueWords: [[String]] = []
        var tokens: [String] = []
        var owners: [(cue: Int, word: Int)] = []
        for (index, cue) in cues.enumerated() {
            let spoken = self.words(of: cue.text)
            cueWords.append(spoken)
            for (position, word) in spoken.enumerated() {
                tokens.append(key(word))
                owners.append((index, position))
            }
        }
        let pairs = matches(tokens, heard.map { key($0.text) })
        var heardAs = cueWords.map { [Int?](repeating: nil, count: $0.count) }
        var taken = Set<Int>()
        for (token, word) in pairs {
            heardAs[owners[token].cue][owners[token].word] = word
            taken.insert(word)
        }
        // What was heard at a cue: its own words' stretch of the transcript, and where the cue
        // begins or ends with words that were not heard, what was said right before or after
        // (without a pause) that no other cue has.
        var result: [TranscriptAlignment.CueMatch] = []
        var previous = -1
        let firsts = heardAs.map { $0.compactMap(\.self).first }
        for (index, cue) in cues.enumerated() {
            let own = heardAs[index].compactMap(\.self)
            var between: [TranscribedWord] = []
            if var from = own.first, var to = own.last {
                let next = firsts[(index + 1)...].compactMap(\.self).first ?? heard.count
                if heardAs[index].first.flatMap(\.self) == nil {
                    while from - 1 > previous, heard[from].start.seconds - heard[from - 1].end.seconds < pauseSeconds { from -= 1 }
                }
                if heardAs[index].last.flatMap(\.self) == nil {
                    while to + 1 < next, heard[to + 1].start.seconds - heard[to].end.seconds < pauseSeconds { to += 1 }
                }
                between = Array(heard[from...to])
                previous = to
            } else {
                // Nothing matched: what was heard while the cue is up that no other cue has.
                between = heard.enumerated().filter {
                    $0.offset > previous && !taken.contains($0.offset) && $0.element.start < cue.end && cue.start < $0.element.end
                }.map(\.element)
            }
            result.append(TranscriptAlignment.CueMatch(
                cueID: cue.id, words: cueWords[index], heardAs: heardAs[index].map { $0.map { heard[$0] } }, heard: between
            ))
        }
        return TranscriptAlignment(cues: result, heardCount: heard.count, sync: sync(of: cues, matches: result))
    }

    /// A cue's spoken words: no markup, sound descriptions, speaker labels or dialogue dashes.
    static func words(of text: String) -> [String] {
        let spoken = CleanupTool.withoutSoundDescriptions(SubtitleText.visibleLines(of: text).joined(separator: "\n"))
        return spoken.split(whereSeparator: \.isWhitespace).map(String.init).filter { !key($0).isEmpty }
    }

    /// What two spellings of a word share: its letters and digits, in lower case.
    static func key(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    // MARK: Voices

    /// Who says a cue, from the voices of its words: one voice a line for a dialogue cue
    /// (lines starting with a dash), else every voice with a fair share of the words, in order.
    public static func voices(of match: TranscriptAlignment.CueMatch, text: String) -> [String]? {
        let lines = SubtitleText.visibleLines(of: text)
        if SubtitleText.isDialogue(lines) {
            var voices: [String] = []
            var next = 0
            for line in lines {
                let count = words(of: line).count
                let spoken = match.heardAs[min(next, match.heardAs.count)..<min(next + count, match.heardAs.count)].compactMap { $0?.speaker }
                next += count
                if let voice = mostCommon(spoken) { voices.append(voice) }
            }
            if voices.count == lines.count { return voices }
        }
        let spoken = match.heardAs.compactMap { $0?.speaker }
        guard !spoken.isEmpty else { return nil }
        var order: [String] = []
        for voice in spoken where !order.contains(voice) { order.append(voice) }
        // One stray word in another voice is the transcriber's slip, not a second speaker.
        let kept = order.filter { voice in
            let count = spoken.count(where: { $0 == voice })
            return count * 4 >= spoken.count && (count > 1 || spoken.count <= 2)
        }
        return kept.isEmpty ? mostCommon(spoken).map { [$0] } : kept
    }

    private static func mostCommon(_ voices: [String]) -> String? {
        var counts: [String: Int] = [:]
        for voice in voices { counts[voice, default: 0] += 1 }
        // The earlier voice on a tie.
        return voices.max { counts[$0, default: 0] < counts[$1, default: 0] }.flatMap { best in
            voices.first { counts[$0] == counts[best] }
        }
    }

    // MARK: Lines that differ

    /// What was heard, as a line, for a cue whose words are mostly not what is said (another
    /// cut of the video, a line in the wrong place), and how sure the transcriber was of it.
    /// Nil when the cue has enough of what is said: subtitles shorten and reword all the time.
    public static func heardInstead(of match: TranscriptAlignment.CueMatch) -> (text: String, confidence: Double)? {
        guard match.words.count >= 4, match.matched * 3 <= match.words.count, match.heard.count - match.matched >= 3 else { return nil }
        // A name the transcriber spelled its own way ("Stephen Fossaway" for Steffon Fossoway) is the same word said.
        let own = Set(match.heardAs.compactMap { $0.map { key($0.text) } })
        let others = match.heard.map { key($0.text) }.filter { !own.contains($0) }
        let alike = zip(match.words, match.heardAs).count { word, heard in
            heard == nil && others.contains { soundsAlike(key(word), $0) }
        }
        guard (match.matched + alike) * 3 <= match.words.count else { return nil }
        let confidences = match.heard.compactMap(\.confidence)
        let confidence = confidences.isEmpty ? 0.5 : confidences.reduce(0, +) / Double(confidences.count)
        return (CueSegmenter.join(match.heard.map(\.text)), confidence)
    }

    /// Two spellings close enough to be one word heard two ways: at most half the letters differ.
    static func soundsAlike(_ a: String, _ b: String) -> Bool {
        let a = Array(a), b = Array(b)
        guard a.count > 1, b.count > 1, abs(a.count - b.count) * 2 <= max(a.count, b.count) else { return false }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return row[b.count] * 2 <= max(a.count, b.count)
    }

    // MARK: Sync

    /// The correction that puts the cues on the audio, from the cues whose first word
    /// was heard: how far each starts from that word.
    static func sync(of cues: [Cue], matches: [TranscriptAlignment.CueMatch]) -> SubtitleSync? {
        var samples: [(cue: Double, heard: Double)] = []
        for (cue, match) in zip(cues, matches) {
            // A cue mostly heard, starting with a word that was.
            guard match.words.count >= 2, match.matched * 2 >= match.words.count, let first = match.heardAs.first.flatMap(\.self) else { continue }
            samples.append((cue.start.seconds, first.start.seconds))
        }
        guard samples.count >= 12 else { return nil }
        samples.sort { $0.cue < $1.cue }
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        }
        // The speed, from how the difference grows between the first and last quarter of the file.
        let quarter = max(samples.count / 4, 3)
        let head = Array(samples.prefix(quarter)), tail = Array(samples.suffix(quarter))
        let span = median(tail.map(\.cue)) - median(head.map(\.cue))
        let growth = median(tail.map { $0.heard - $0.cue }) - median(head.map { $0.heard - $0.cue })
        var speed = 1.0
        if span > 60, abs(growth) >= smallestOffset {
            speed = 1 + growth / span
            if let known = knownSpeeds.first(where: { abs($0 - speed) < 0.0015 }) {
                speed = known
            } else if abs(growth) < 1 {
                // Too small a drift to tell from scatter, and no frame rate explains it.
                speed = 1
            }
        }
        let offset = median(samples.map { $0.heard - $0.cue * speed }) - usualLead
        let spread = median(samples.map { abs($0.heard - usualLead - ($0.cue * speed + offset)) })
        guard spread <= largestSpread else { return nil }
        guard speed != 1 || abs(offset) >= smallestOffset else { return nil }
        return SubtitleSync(offset: (offset * 1000).rounded() / 1000, speed: speed, samples: samples.count)
    }

    // MARK: Matching

    /// Index pairs (a, b) of the words the two sequences share, in order: stretches of
    /// words found once in both anchor the rest (as patience diff does lines), and what
    /// lies between two anchors is matched the same way, or word by word when it is short.
    static func matches(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        var pairs: [(Int, Int)] = []
        match(a, b, a.startIndex..<a.endIndex, b.startIndex..<b.endIndex, into: &pairs)
        return pairs
    }

    /// Stretches this small are matched word by word (longest common subsequence).
    static let smallestCells = 60_000

    private static func match(_ a: [String], _ b: [String], _ rangeA: Range<Int>, _ rangeB: Range<Int>, into pairs: inout [(Int, Int)]) {
        var rangeA = rangeA, rangeB = rangeB
        // The same words at both ends match as they are.
        while !rangeA.isEmpty, !rangeB.isEmpty, a[rangeA.lowerBound] == b[rangeB.lowerBound] {
            pairs.append((rangeA.lowerBound, rangeB.lowerBound))
            rangeA = (rangeA.lowerBound + 1)..<rangeA.upperBound
            rangeB = (rangeB.lowerBound + 1)..<rangeB.upperBound
        }
        var tail: [(Int, Int)] = []
        while !rangeA.isEmpty, !rangeB.isEmpty, a[rangeA.upperBound - 1] == b[rangeB.upperBound - 1] {
            tail.append((rangeA.upperBound - 1, rangeB.upperBound - 1))
            rangeA = rangeA.lowerBound..<(rangeA.upperBound - 1)
            rangeB = rangeB.lowerBound..<(rangeB.upperBound - 1)
        }
        defer { pairs += tail.reversed() }
        guard !rangeA.isEmpty, !rangeB.isEmpty else { return }
        if rangeA.count * rangeB.count <= smallestCells {
            pairs += longestCommon(a, b, rangeA, rangeB)
            return
        }
        for length in [3, 2, 1] {
            let anchors = anchors(a, b, rangeA, rangeB, length: length)
            guard !anchors.isEmpty else { continue }
            var startA = rangeA.lowerBound, startB = rangeB.lowerBound
            for (indexA, indexB) in anchors {
                match(a, b, startA..<indexA, startB..<indexB, into: &pairs)
                pairs.append((indexA, indexB))
                startA = indexA + 1
                startB = indexB + 1
            }
            match(a, b, startA..<rangeA.upperBound, startB..<rangeB.upperBound, into: &pairs)
            return
        }
        // A long stretch with nothing in common: another scene, or not this video's subtitles.
    }

    /// Word pairs from runs of `length` words that occur once in each range, kept where they are in the same order in both.
    private static func anchors(_ a: [String], _ b: [String], _ rangeA: Range<Int>, _ rangeB: Range<Int>, length: Int) -> [(Int, Int)] {
        guard rangeA.count >= length, rangeB.count >= length else { return [] }
        func runs(_ words: [String], _ range: Range<Int>) -> [String: Int] {
            // -1 marks a run seen more than once.
            var found: [String: Int] = [:]
            for start in range.lowerBound...(range.upperBound - length) {
                let run = words[start..<(start + length)].joined(separator: " ")
                found[run] = found[run] == nil ? start : -1
            }
            return found
        }
        let inA = runs(a, rangeA), inB = runs(b, rangeB)
        var candidates: [(Int, Int)] = []
        for (run, start) in inA where start >= 0 {
            if let other = inB[run], other >= 0 { candidates.append((start, other)) }
        }
        candidates.sort { $0.0 < $1.0 }
        let ordered = longestIncreasing(candidates)
        // Each run's words, skipping those an overlapping run before it paired already.
        var result: [(Int, Int)] = []
        var lastA = rangeA.lowerBound - 1, lastB = rangeB.lowerBound - 1
        for (startA, startB) in ordered {
            for step in 0..<length where startA + step > lastA && startB + step > lastB {
                result.append((startA + step, startB + step))
                lastA = startA + step
                lastB = startB + step
            }
        }
        return result
    }

    /// The longest run of pairs (sorted by their first index) whose second index also rises.
    private static func longestIncreasing(_ pairs: [(Int, Int)]) -> [(Int, Int)] {
        var tails: [Int] = []
        var before = [Int](repeating: -1, count: pairs.count)
        for index in pairs.indices {
            var low = 0, high = tails.count
            while low < high {
                let middle = (low + high) / 2
                if pairs[tails[middle]].1 < pairs[index].1 { low = middle + 1 } else { high = middle }
            }
            if low > 0 { before[index] = tails[low - 1] }
            if low == tails.count { tails.append(index) } else { tails[low] = index }
        }
        var result: [(Int, Int)] = []
        var index = tails.last ?? -1
        while index >= 0 {
            result.append(pairs[index])
            index = before[index]
        }
        return result.reversed()
    }

    private static func longestCommon(_ a: [String], _ b: [String], _ rangeA: Range<Int>, _ rangeB: Range<Int>) -> [(Int, Int)] {
        let rows = rangeA.count, columns = rangeB.count
        var lengths = [Int32](repeating: 0, count: (rows + 1) * (columns + 1))
        for row in stride(from: rows - 1, through: 0, by: -1) {
            for column in stride(from: columns - 1, through: 0, by: -1) {
                lengths[row * (columns + 1) + column] = a[rangeA.lowerBound + row] == b[rangeB.lowerBound + column]
                    ? lengths[(row + 1) * (columns + 1) + column + 1] + 1
                    : max(lengths[(row + 1) * (columns + 1) + column], lengths[row * (columns + 1) + column + 1])
            }
        }
        var result: [(Int, Int)] = []
        var row = 0, column = 0
        while row < rows, column < columns {
            if a[rangeA.lowerBound + row] == b[rangeB.lowerBound + column] {
                result.append((rangeA.lowerBound + row, rangeB.lowerBound + column))
                row += 1
                column += 1
            } else if lengths[(row + 1) * (columns + 1) + column] >= lengths[row * (columns + 1) + column + 1] {
                row += 1
            } else {
                column += 1
            }
        }
        return result
    }
}

import SubtitleCore

/// A reason a cue is not ready for delivery under a preset.
public struct QCIssue: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case empty
        /// Still showing when the next cue in the same position starts.
        case overlapsNext
        /// Fewer frames before the next cue in the same position than the preset's minimum gap.
        case gapTooShort(frames: Int64)
        case readingSpeed(Double)
        /// A line (0-based) with too many characters.
        case lineTooLong(line: Int, characters: Int)
        case tooManyLines(Int)
        case tooShort(MediaTime)
        case tooLong(MediaTime)
        /// Starts this many frames after (positive) or before (negative) a shot change.
        case startNearShotChange(frames: Int64)
        /// Ends this many frames after (positive) or before (negative) a shot change.
        case endNearShotChange(frames: Int64)
        /// In translation mode: the source cue has text, this one has none.
        case notTranslated
        /// In translation mode: the source uses a glossary term, the target not its agreed translation.
        case glossaryTermNotUsed(source: String, target: String)
    }

    public enum Severity: Int, Comparable, Sendable {
        case warning
        /// Always wrong for delivery: no text, or two cues on screen in the same place.
        case error

        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var kind: Kind
    public var message: String

    public var severity: Severity {
        switch kind {
        case .empty, .overlapsNext, .notTranslated: .error
        default: .warning
        }
    }

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }
}

public enum QualityControl {
    /// What checks need beyond the cues: the frame rate, and shot changes when known.
    public struct Context: Sendable {
        public var frameRate: FrameRate
        /// Shot changes as frame numbers, sorted.
        public var shotChanges: [Int64]

        public init(frameRate: FrameRate, shotChanges: [Int64] = []) {
            self.frameRate = frameRate
            self.shotChanges = shotChanges
        }
    }

    /// The issues of each cue that has any, for cues sorted by start time.
    public static func check(_ cues: [Cue], preset: QCPreset, context: Context) -> [Cue.ID: [QCIssue]] {
        var result: [Cue.ID: [QCIssue]] = [:]
        for (index, cue) in cues.enumerated() {
            // A top cue (a sign) may run alongside bottom dialogue; only the same position counts.
            let next = cues[(index + 1)...].first(where: { $0.position == cue.position })
            let issues = issues(of: cue, nextStart: next?.start, preset: preset, context: context)
            if !issues.isEmpty { result[cue.id] = issues }
        }
        return result
    }

    /// One cue's issues. They depend on the cue itself and on when the next cue in the same
    /// position starts (`nextStart`, nil for the last), so a caller can keep them until either changes.
    public static func issues(of cue: Cue, nextStart: MediaTime?, preset: QCPreset, context: Context) -> [QCIssue] {
        let rate = context.frameRate
        var issues: [QCIssue] = []
        func add(_ kind: QCIssue.Kind, _ message: String) { issues.append(QCIssue(kind: kind, message: message)) }

        let lines = SubtitleText.visibleLines(of: cue.text)
        if lines.allSatisfy({ $0.allSatisfy(\.isWhitespace) }) {
            add(.empty, "No text")
        } else {
            if let max = preset.maxLines, lines.count > max {
                add(.tooManyLines(lines.count), "\(lines.count) lines (max \(max))")
            }
            if let max = preset.maxCharactersPerLine {
                for (number, line) in lines.enumerated() where line.count > max {
                    add(.lineTooLong(line: number, characters: line.count), "Line \(number + 1) has \(line.count) characters (max \(max))")
                }
            }
            // A speed the user accepted stays accepted until the cue reads faster.
            if let max = preset.maxCharactersPerSecond {
                let seconds = cue.duration.seconds
                let speed = seconds > 0 ? Double(lines.reduce(0) { $0 + $1.count }) / seconds : 0
                if speed > max, cue.acceptedReadingSpeed.map({ speed > $0 + 0.005 }) ?? true {
                    add(.readingSpeed(speed), "Reading speed \(Int(speed.rounded())) c/s (max \(max.compact))")
                }
            }
        }
        if let minimum = preset.minimumDuration, cue.duration < minimum {
            add(.tooShort(cue.duration), "Shown for \(cue.duration.shortSeconds) (min \(minimum.shortSeconds))")
        }
        if let maximum = preset.maximumDuration, cue.duration > maximum {
            add(.tooLong(cue.duration), "Shown for \(cue.duration.shortSeconds) (max \(maximum.shortSeconds))")
        }
        if let nextStart {
            if nextStart < cue.end {
                add(.overlapsNext, "Overlaps the next cue")
            } else {
                let gap = nextStart.firstFrame(at: rate) - cue.end.firstFrame(at: rate)
                if gap < preset.minimumGapFrames {
                    add(.gapTooShort(frames: gap), "\(frames(gap)) before the next cue (min \(preset.minimumGapFrames))")
                }
            }
        }
        if let threshold = preset.shotChangeFrames, !context.shotChanges.isEmpty {
            let start = cue.start.firstFrame(at: rate)
            if let shot = nearest(to: start, in: context.shotChanges), shot != start, abs(start - shot) < threshold {
                let offset = start - shot
                add(.startNearShotChange(frames: offset), "Starts \(frames(abs(offset))) \(offset > 0 ? "after" : "before") a shot change")
            }
            let end = cue.end.firstFrame(at: rate)
            if let shot = nearest(to: end, in: context.shotChanges), shot != end, shot - end != preset.minimumGapFrames,
               abs(end - shot) < threshold
            {
                let offset = end - shot
                add(.endNearShotChange(frames: offset), "Ends \(frames(abs(offset))) \(offset > 0 ? "after" : "before") a shot change")
            }
        }
        return issues
    }

    private static func frames(_ count: Int64) -> String {
        count == 1 ? "1 frame" : "\(count) frames"
    }

    /// The value in a sorted array closest to `frame`.
    static func nearest(to frame: Int64, in sorted: [Int64]) -> Int64? {
        var low = 0, high = sorted.count
        while low < high {
            let middle = (low + high) / 2
            if sorted[middle] < frame { low = middle + 1 } else { high = middle }
        }
        let candidates = [low - 1, low].filter { sorted.indices.contains($0) }.map { sorted[$0] }
        return candidates.min { abs($0 - frame) < abs($1 - frame) }
    }
}

extension Double {
    /// "20" rather than "20.0".
    var compact: String { rounded() == self ? String(Int(self)) : String(self) }
}

extension MediaTime {
    /// Seconds to two decimals, e.g. "0.83 s".
    public var shortSeconds: String {
        let hundredths = Int((seconds * 100).rounded())
        let fraction = hundredths % 100
        let decimals = fraction == 0 ? "" : fraction % 10 == 0 ? ".\(fraction / 10)" : fraction < 10 ? ".0\(fraction)" : ".\(fraction)"
        return "\(hundredths / 100)\(decimals) s"
    }
}

import Foundation
import SubtitleCore

/// A one-click fix for a cue's QC issues: the cue as it would be afterwards
/// (timing, text), or a change to the cues around it.
public struct QCFix: Hashable, Sendable {
    public enum Purpose: Hashable, Sendable {
        /// Ends later (reading speed, too short).
        case extendEnd
        /// Starts earlier (reading speed, too short).
        case startEarlier
        /// Ends as late and starts as early as needed (reading speed).
        case extendBoth
        /// Ends before the next cue, with the minimum gap (overlap, short gap).
        case trimEnd
        /// Ends at the longest a cue may show (too long).
        case trimToMaximum
        /// Moves the next cue's start, leaving the minimum gap (overlap, short gap).
        case moveNextStart
        /// Starts at the shot change it is close to.
        case snapStart
        /// Ends at the shot change it is close to.
        case snapEnd
        /// Ends the minimum gap before the shot change it is close to.
        case endBeforeCut
        /// Ends the preset's distance after the shot change it is close to (Netflix: 12 frames).
        case endAfterCut
        /// The same words broken into lines that fit (a line too long, too many lines).
        case rebalance
        /// Joined with the next cue (reading speed); `text` is the joined text, its lines rebalanced when needed.
        case mergeWithNext
        /// Split in two (too long, too many lines).
        case split
        /// Removed (no text).
        case delete
    }

    public var purpose: Purpose
    /// The cue's start, end and text after the fix (unchanged for merge, split and delete).
    public var start: MediaTime
    public var end: MediaTime
    public var text: String
    /// For `moveNextStart`: where the next cue in the same position starts.
    public var nextStart: MediaTime?
    /// The cue's issues this fix clears (all of them for merge, split and delete are not checked: empty).
    public var clears: [QCIssue.Kind] = []
}

extension QualityControl {
    /// Fixes for the issues of `cues[index]`, those leaving the fewest issues first.
    /// Timing fixes go only as far as the rule needs. Each one shown
    /// clears an issue of the cue without adding a new kind of issue to it or to
    /// the next cue (merge, split and delete are offered as they are).
    /// `speaker` says who speaks a cue, when known: merging two people's lines makes a dialogue cue.
    public static func fixes(
        for index: Int, in cues: [Cue], preset: QCPreset, context: Context, speaker: (Cue) -> String? = defaultSpeaker
    ) -> [QCFix] {
        guard cues.indices.contains(index) else { return [] }
        let cue = cues[index]
        let rate = context.frameRate
        let gap = MediaTime(frame: preset.minimumGapFrames, rate: rate)
        let previousIndex = cues[..<index].lastIndex { $0.position == cue.position }
        let nextIndex = cues[(index + 1)...].firstIndex { $0.position == cue.position }
        let earliestStart = previousIndex.map { cues[$0].end + gap } ?? .zero
        let latestEnd = nextIndex.map { cues[$0].start - gap }
        let window = max(0, (previousIndex ?? index) - 1)..<min(cues.count, (nextIndex ?? index) + 2)
        let before = check(Array(cues[window]), preset: preset, context: context)
        let issues = before[cue.id] ?? []
        guard !issues.isEmpty else { return [] }

        func frames(_ count: Int64) -> MediaTime { MediaTime(frame: count, rate: rate) }
        func snapped(_ time: MediaTime) -> MediaTime { frames(time.firstFrame(at: rate)) }
        func retimed(_ purpose: QCFix.Purpose, start: MediaTime = cue.start, end: MediaTime = cue.end) -> QCFix {
            QCFix(purpose: purpose, start: snapped(start), end: snapped(end), text: cue.text)
        }

        let threshold = preset.shotChangeFrames ?? 0
        let cuts = threshold > 0 ? context.shotChanges : []
        /// An end at least `end`, clear of cuts: on a cut just after it, or the preset's distance
        /// after a cut just before it, rather than a few frames either side of one.
        func endsClearOfCuts(_ end: MediaTime) -> [MediaTime] {
            let frame = end.firstFrame(at: rate)
            if let cut = cuts.first(where: { $0 >= frame }), cut - frame < threshold { return [frames(cut)] }
            if let cut = cuts.last(where: { $0 < frame }), frame - cut < threshold { return [frames(cut + threshold)] }
            return [end]
        }
        /// A start at most `start`, clear of cuts: on a cut just before it, or the preset's
        /// distance before a cut just after it.
        func startsClearOfCuts(_ start: MediaTime) -> [MediaTime] {
            let frame = start.firstFrame(at: rate)
            if let cut = cuts.last(where: { $0 <= frame }), frame - cut < threshold { return [frames(cut)] }
            if let cut = cuts.first(where: { $0 > frame }), cut - frame < threshold, cut >= threshold { return [frames(cut - threshold)] }
            return [start]
        }
        var candidates: [QCFix] = []
        for issue in issues {
            switch issue.kind {
            case .readingSpeed:
                guard let maximum = preset.maxCharactersPerSecond, maximum > 0 else { break }
                let characters = SubtitleText.visibleLines(of: cue.text).reduce(0) { $0 + $1.count }
                let fps = Double(rate.numerator) / Double(rate.denominator)
                let needed = frames(Int64((Double(characters) / maximum * fps).rounded(.up)))
                for end in endsClearOfCuts(cue.start + needed) { candidates.append(retimed(.extendEnd, end: end)) }
                if cue.end > needed {
                    for start in startsClearOfCuts(cue.end - needed) { candidates.append(retimed(.startEarlier, start: start)) }
                }
                // Both ends, when the next cue leaves too little room to extend alone: still over
                // the cue's own time, never moved away from when the line is said.
                if let latestEnd, latestEnd > needed, latestEnd - needed >= earliestStart, latestEnd - needed <= cue.start {
                    candidates.append(retimed(.extendBoth, start: latestEnd - needed, end: latestEnd))
                }
                // Merging is for speech that runs on: the next cue starts within half a second.
                if index + 1 < cues.count, (cues[index + 1].start - cue.end).seconds <= 0.5 {
                    let next = cues[index + 1]
                    let text = mergedText(cue, next, preset: preset, speaker: speaker)
                    candidates.append(QCFix(purpose: .mergeWithNext, start: cue.start, end: max(cue.end, next.end), text: text))
                }
            case .tooShort:
                guard let minimum = preset.minimumDuration else { break }
                for end in endsClearOfCuts(cue.start + minimum) { candidates.append(retimed(.extendEnd, end: end)) }
                if cue.end > minimum {
                    for start in startsClearOfCuts(cue.end - minimum) { candidates.append(retimed(.startEarlier, start: start)) }
                }
            case .tooLong:
                guard let maximum = preset.maximumDuration else { break }
                candidates.append(retimed(.trimToMaximum, end: cue.start + maximum))
                candidates.append(QCFix(purpose: .split, start: cue.start, end: cue.end, text: cue.text))
            case .overlapsNext, .gapTooShort:
                guard let nextIndex else { break }
                let next = cues[nextIndex]
                if next.start > gap { candidates.append(retimed(.trimEnd, end: next.start - gap)) }
                var moved = QCFix(purpose: .moveNextStart, start: cue.start, end: cue.end, text: cue.text)
                moved.nextStart = snapped(cue.end + gap)
                candidates.append(moved)
            case .startNearShotChange(let offset):
                candidates.append(retimed(.snapStart, start: frames(cue.start.firstFrame(at: rate) - offset)))
            case .endNearShotChange(let offset):
                let shot = cue.end.firstFrame(at: rate) - offset
                candidates.append(retimed(.snapEnd, end: frames(shot)))
                candidates.append(retimed(.endBeforeCut, end: frames(shot - preset.minimumGapFrames)))
                if offset > 0, let threshold = preset.shotChangeFrames {
                    candidates.append(retimed(.endAfterCut, end: frames(shot + threshold)))
                }
            case .lineTooLong, .tooManyLines:
                if let text = rebalanced(cue.text, preset: preset) {
                    candidates.append(QCFix(purpose: .rebalance, start: cue.start, end: cue.end, text: text))
                }
                if case .tooManyLines = issue.kind {
                    candidates.append(QCFix(purpose: .split, start: cue.start, end: cue.end, text: cue.text))
                }
            case .empty:
                candidates.append(QCFix(purpose: .delete, start: cue.start, end: cue.end, text: cue.text))
            case .notTranslated, .glossaryTermNotUsed:
                break
            }
        }

        var seen = Set<QCFix>()
        var left: [QCFix: Int] = [:]
        var cleared: [QCFix: [QCIssue.Kind]] = [:]
        let kept = candidates.filter { fix in
            guard seen.insert(fix).inserted else { return false }
            switch fix.purpose {
            case .split, .delete: return true
            default: break
            }
            var changed = cues
            if fix.purpose == .mergeWithNext {
                changed.remove(at: index + 1)
                changed[index].end = fix.end
                changed[index].text = fix.text
            } else {
                guard fix.start < fix.end, fix.start >= .zero else { return false }
                changed[index].start = fix.start
                changed[index].end = fix.end
                changed[index].text = fix.text
                if let nextStart = fix.nextStart, let nextIndex {
                    guard nextStart < cues[nextIndex].end else { return false }
                    changed[nextIndex].start = nextStart
                }
            }
            let range = window.clamped(to: 0..<changed.count)
            let after = check(Array(changed[range].sorted { $0.start < $1.start }), preset: preset, context: context)
            // A neighbour merged away has no issues left to compare.
            let neighbours = [previousIndex, nextIndex].compactMap { $0 }.map { cues[$0].id }
            let remaining = Set((after[cue.id] ?? []).map(\.kind.category))
            left[fix] = remaining.count
            cleared[fix] = issues.map(\.kind).filter { !remaining.contains($0.category) }
            return improves(before[cue.id] ?? [], after[cue.id] ?? [])
                && neighbours.allSatisfy { adds(nothingTo: before[$0] ?? [], after[$0] ?? []) }
        }
        // The fix that leaves the fewest issues first; merge, split and delete last among equals.
        let ranked = kept.enumerated().sorted {
            (left[$0.element] ?? .max, $0.offset) < (left[$1.element] ?? .max, $1.offset)
        }.map { entry in
            var fix = entry.element
            fix.clears = cleared[fix] ?? (fix.purpose == .delete ? [.empty] : [])
            return fix
        }
        // Too fast to read is too short to read: a fix that only makes the cue longer than the
        // minimum, and no easier to read, fixes nothing that matters.
        let tooFast = issues.contains { if case .readingSpeed = $0.kind { true } else { false } }
        // A fix another of its kind outdoes (clearing all it clears, and more) is left out.
        return ranked.filter { fix in
            let clears = Set(fix.clears.map(\.category))
            if tooFast, clears.isSubset(of: [QCIssue.Kind.tooShort(.zero).category]) { return false }
            return !ranked.contains { other in
                other != fix && other.purpose.changesTiming == fix.purpose.changesTiming
                    && clears.isStrictSubset(of: Set(other.clears.map(\.category)))
            }
        }
    }

    /// Who speaks a cue as the cue itself says: its speaker (ASS Name), or its one transcriber voice.
    public static func defaultSpeaker(_ cue: Cue) -> String? {
        cue.speaker ?? (cue.voices?.count == 1 ? cue.voices?.first : nil)
    }

    /// The text of two cues merged. Two people's lines become dialogue, a line each starting
    /// with a dash; else the lines stack, rebalanced when there are more than the preset allows.
    public static func mergedText(_ cue: Cue, _ next: Cue, preset: QCPreset, speaker: (Cue) -> String? = defaultSpeaker) -> String {
        if let first = speaker(cue), let second = speaker(next), first != second, !cue.text.isEmpty, !next.text.isEmpty,
           !SubtitleText.isDialogue(SubtitleText.visibleLines(of: cue.text)), !SubtitleText.isDialogue(SubtitleText.visibleLines(of: next.text)) {
            func line(_ text: String) -> String {
                let words = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
                return words.hasPrefix("-") ? words : "- \(words)"
            }
            return "\(line(cue.text))\n\(line(next.text))"
        }
        let joined = [cue.text, next.text].filter { !$0.isEmpty }.joined(separator: "\n")
        let lines = SubtitleText.visibleLines(of: joined).count
        return lines > (preset.maxLines ?? .max) ? rebalanced(joined, preset: preset) ?? joined : joined
    }

    /// Fewer kinds of issue, and none new.
    private static func improves(_ before: [QCIssue], _ after: [QCIssue]) -> Bool {
        let old = Set(before.map(\.kind.category)), new = Set(after.map(\.kind.category))
        return new.isSubset(of: old) && new.count < old.count
    }

    private static func adds(nothingTo before: [QCIssue], _ after: [QCIssue]) -> Bool {
        Set(after.map(\.kind.category)).isSubset(of: Set(before.map(\.kind.category)))
    }

    /// The text's words broken into as few lines as fit the preset, the lines as
    /// even as they can be (the bottom one the longer). Nil for text with markup,
    /// dialogue (a line per speaker), or when no break fits.
    public static func rebalanced(_ text: String, preset: QCPreset) -> String? {
        let lines = SubtitleText.visibleLines(of: text)
        guard lines.joined(separator: "\n") == text, !SubtitleText.isDialogue(lines) else { return nil }
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return nil }
        let maxLines = preset.maxLines ?? 2
        let maxLength = preset.maxCharactersPerLine ?? .max
        let joined = words.joined(separator: " ")
        if joined.count <= maxLength { return joined == text ? nil : joined }
        guard maxLines >= 2, words.count > 1 else { return nil }
        var best: (String, Int)?
        for split in 1..<words.count {
            let top = words[..<split].joined(separator: " "), bottom = words[split...].joined(separator: " ")
            guard top.count <= maxLength, bottom.count <= maxLength else { continue }
            // Even lines first; on a tie, the longer line at the bottom.
            let score = abs(top.count - bottom.count) * 2 + (top.count > bottom.count ? 1 : 0)
            if best.map({ score < $0.1 }) ?? true { best = ("\(top)\n\(bottom)", score) }
        }
        return best.flatMap { $0.0 == text ? nil : $0.0 }
    }
}

extension QCFix.Purpose {
    /// Fixes that move the cue's own start or end.
    public var changesTimingOfCue: Bool {
        switch self {
        case .rebalance, .mergeWithNext, .split, .delete, .moveNextStart: false
        default: true
        }
    }

    /// Timing fixes compete with each other; line and cue fixes with theirs.
    var changesTiming: Bool {
        switch self {
        case .rebalance, .mergeWithNext, .split, .delete: false
        default: true
        }
    }
}

extension QCIssue.Kind {
    /// The rule broken, whatever the numbers.
    var category: Int {
        switch self {
        case .empty: 0
        case .overlapsNext: 1
        case .gapTooShort: 2
        case .readingSpeed: 3
        case .lineTooLong: 4
        case .tooManyLines: 5
        case .tooShort: 6
        case .tooLong: 7
        case .startNearShotChange: 8
        case .endNearShotChange: 9
        case .notTranslated: 10
        case .glossaryTermNotUsed: 11
        }
    }
}

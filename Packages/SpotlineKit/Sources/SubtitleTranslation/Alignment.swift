import SubtitleCore

/// Pairs target cues with the source cues they translate.
public enum Alignment {
    /// For each target cue, the source cue it translates: the one it links to
    /// (`sourceCueID`), else the source cue it overlaps most in time. A target
    /// cue joined from several (`joinedSourceCueIDs`) gets their text as one cue.
    public static func sourceCues(for target: [Cue], in source: [Cue]) -> [Cue.ID: Cue] {
        let byID = Dictionary(source.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let finder = OverlapFinder(source)
        var result: [Cue.ID: Cue] = [:]
        for cue in target {
            if let id = cue.sourceCueID, let linked = byID[id] {
                let joined = (cue.joinedSourceCueIDs ?? []).compactMap { byID[$0] }
                result[cue.id] = joined.isEmpty ? linked : combined([linked] + joined)
            } else if let overlapping = finder.bestOverlap(for: cue) {
                result[cue.id] = overlapping
            }
        }
        return result
    }

    /// Links every target cue to the source cue it overlaps most, keeping existing links.
    public static func link(_ target: [Cue], to source: [Cue]) -> [Cue] {
        let ids = Set(source.map(\.id))
        let finder = OverlapFinder(source)
        return target.map { cue in
            var cue = cue
            if cue.sourceCueID.map({ !ids.contains($0) }) ?? true {
                cue.sourceCueID = finder.bestOverlap(for: cue)?.id
            }
            return cue
        }
    }

    /// Source cues read as one: the first's ID and position, their span, their
    /// lines (a line each, as dialogue when they are), voices and unsure words.
    static func combined(_ cues: [Cue]) -> Cue {
        var cue = cues[0]
        for next in cues.dropFirst() {
            cue.end = max(cue.end, next.end)
            cue.text += "\n" + next.text
            let voices = (cue.voices ?? []) + (next.voices ?? []).filter { !(cue.voices ?? []).contains($0) }
            cue.voices = voices.isEmpty ? nil : voices
            let unsure = (cue.unsureWords ?? []) + (next.unsureWords ?? [])
            cue.unsureWords = unsure.isEmpty ? nil : unsure
        }
        return cue
    }

    /// Empty target cues with the source's timing and position, linked to it: the
    /// starting point of a translation.
    public static func template(from source: [Cue]) -> [Cue] {
        source.map { Cue(start: $0.start, end: $0.end, text: "", position: $0.position, sourceCueID: $0.id) }
    }

}

/// Finds overlapping source cues by binary search, so pairing a feature's
/// cues stays fast while typing.
struct OverlapFinder {
    private let sorted: [Cue]
    private let longest: MediaTime

    init(_ source: [Cue]) {
        sorted = source.sorted { $0.start < $1.start }
        longest = source.map(\.duration).max() ?? .zero
    }

    /// The source cue sharing the most time with `cue` (in the same position when
    /// several overlap), nil when none overlaps.
    func bestOverlap(for cue: Cue) -> Cue? {
        // No cue starting before this can reach the cue.
        let earliest = cue.start - longest
        var low = 0, high = sorted.count
        while low < high {
            let middle = (low + high) / 2
            if sorted[middle].start < earliest { low = middle + 1 } else { high = middle }
        }
        var best: (cue: Cue, overlap: MediaTime, samePosition: Bool)?
        for candidate in sorted[low...] {
            guard candidate.start < cue.end else { break }
            guard cue.start < candidate.end else { continue }
            let overlap = min(candidate.end, cue.end) - max(candidate.start, cue.start)
            let samePosition = candidate.position == cue.position
            if let current = best,
               current.samePosition && !samePosition || current.samePosition == samePosition && current.overlap >= overlap
            {
                continue
            }
            best = (candidate, overlap, samePosition)
        }
        return best?.cue
    }
}

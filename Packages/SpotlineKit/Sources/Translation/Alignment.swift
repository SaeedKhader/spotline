import SubtitleCore

/// Pairs target cues with the source cues they translate.
public enum Alignment {
    /// For each target cue, the source cue it translates: the one it links to
    /// (`sourceCueID`), else the source cue it overlaps most in time.
    public static func sourceCues(for target: [Cue], in source: [Cue]) -> [Cue.ID: Cue] {
        let byID = Dictionary(source.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [Cue.ID: Cue] = [:]
        for cue in target {
            if let id = cue.sourceCueID, let linked = byID[id] {
                result[cue.id] = linked
            } else if let overlapping = bestOverlap(for: cue, in: source) {
                result[cue.id] = overlapping
            }
        }
        return result
    }

    /// Links every target cue to the source cue it overlaps most, keeping existing links.
    public static func link(_ target: [Cue], to source: [Cue]) -> [Cue] {
        let ids = Set(source.map(\.id))
        return target.map { cue in
            var cue = cue
            if cue.sourceCueID.map({ !ids.contains($0) }) ?? true {
                cue.sourceCueID = bestOverlap(for: cue, in: source)?.id
            }
            return cue
        }
    }

    /// Empty target cues with the source's timing and position, linked to it: the
    /// starting point of a translation.
    public static func template(from source: [Cue]) -> [Cue] {
        source.map { Cue(start: $0.start, end: $0.end, text: "", position: $0.position, sourceCueID: $0.id) }
    }

    /// The source cue sharing the most time with `cue` (in the same position when
    /// several overlap), nil when none overlaps.
    static func bestOverlap(for cue: Cue, in source: [Cue]) -> Cue? {
        var best: (cue: Cue, overlap: MediaTime, samePosition: Bool)?
        for candidate in source where candidate.start < cue.end && cue.start < candidate.end {
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

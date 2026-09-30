import SubtitleCore

/// What the cue list shows: every cue, or only the cues with one kind of thing
/// to review, each with its review box open (the scope bar over the list).
public enum ReviewScope: String, CaseIterable, Sendable {
    case all
    /// QC issues under the preset.
    case issues
    /// Words the transcriber was unsure of.
    case words
    /// Lines AI translation could word more than one way.
    case choices
    /// Changes an AI tool proposes (cleanup), to accept or reject.
    case changes
}

extension EditorState {
    /// The cues with something to review in `scope`; in `.all`, in any.
    public func cueIDsToReview(in scope: ReviewScope) -> Set<Cue.ID> {
        switch scope {
        case .all:
            ReviewScope.allCases.dropFirst().reduce(into: Set()) { $0.formUnion(cueIDsToReview(in: $1)) }
        case .issues:
            Set(issues.keys)
        case .words:
            Set(cuesToCheck.map(\.id))
        case .choices:
            Set(cuesToChoose.map(\.id))
        case .changes:
            Set(pendingReview?.changes.map(\.cueID) ?? [])
        }
    }

    /// How many things the scope bar counts for `scope`: cues with issues, words to
    /// check, lines to choose, changes to decide; every cue for `.all`.
    public func reviewCount(in scope: ReviewScope) -> Int {
        switch scope {
        case .all: track.cues.count
        case .issues: issues.count
        case .words: wordsToCheckCount
        case .choices: cuesToChoose.count
        case .changes: pendingReview?.changes.count ?? 0
        }
    }

    /// The cues the list shows in the current scope (not `.all`), in the order it
    /// shows them. The selected cue stays while it is being fixed, so it does not
    /// jump away mid-typing once its issue is gone.
    public var reviewListCues: [Cue] {
        switch reviewScope {
        case .all:
            return track.cues
        case .issues:
            return track.cues.filter { issues[$0.id] != nil || $0.id == selectedCueID }
        case .words:
            return reviewedWordCues
        case .choices:
            return cuesToChoose
        case .changes:
            let ids = cueIDsToReview(in: .changes)
            return track.cues.filter { ids.contains($0.id) }
        }
    }

    /// Shows only the cues with proposed changes, or every cue again.
    func toggleChangeReview() {
        reviewScope = reviewScope == .changes ? .all : .changes
        if reviewScope == .changes, let first = pendingReview?.changes.min(by: { $0.cue.start < $1.cue.start }),
           selectedCueID.flatMap({ pendingReview?.change(forCue: $0) }) == nil {
            select(first.cueID)
        }
    }
}

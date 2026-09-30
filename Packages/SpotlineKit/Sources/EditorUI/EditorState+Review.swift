import AITools
import EditorCommands
import QualityControl
import SubtitleCore

/// What the review sidebar lists: everything to review, or one kind of it (its filter chips).
public enum ReviewScope: String, CaseIterable, Sendable {
    case all
    /// QC issues under the preset, but those of frames (below).
    case issues
    /// QC issues counted in frames: too close to a shot change, too short a gap to the next cue.
    case frames
    /// Words the transcriber was unsure of.
    case words
    /// Lines AI translation could word more than one way.
    case choices
    /// Changes an AI tool proposes (cleanup), to accept or reject.
    case changes
}

/// One thing to decide in the review sidebar: a cue's QC issues, one word to
/// check, a line to choose, or a proposed change. The sidebar shows one card each.
public struct ReviewItem: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case change
        case choice
        /// The n-th unsure word of the cue.
        case word(Int)
        case issues
        /// The cue's frame issues (shot changes, gaps), apart from its other issues.
        case frames

        var scope: ReviewScope {
            switch self {
            case .change: .changes
            case .choice: .choices
            case .word: .words
            case .issues: .issues
            case .frames: .frames
            }
        }

        /// Cards of one cue go in this order.
        fileprivate var rank: Int {
            switch self {
            case .change: 0
            case .choice: 1
            case .word(let index): 2 + index
            case .issues: 1000
            case .frames: 1001
            }
        }
    }

    public let cueID: Cue.ID
    public let kind: Kind
    /// The cue's start, for the sidebar's time order.
    public let start: MediaTime
    /// A word card's word, so confirming one word does not make the next look like it.
    public var word: String?

    public init(cueID: Cue.ID, kind: Kind, start: MediaTime, word: String? = nil) {
        self.cueID = cueID
        self.kind = kind
        self.start = start
        self.word = word
    }

    /// Stable while the item is open: "<cue id>.choice", "<cue id>.word.1.Duncan".
    public var id: String {
        let suffix = switch kind {
        case .change: "change"
        case .choice: "choice"
        case .word(let index): "word.\(index).\(word ?? "")"
        case .issues: "issues"
        case .frames: "frames"
        }
        return "\(cueID.uuidString).\(suffix)"
    }

    /// Time order, then the kind's order within a cue.
    fileprivate func precedes(_ other: ReviewItem) -> Bool {
        (start, kind.rank) < (other.start, other.kind.rank)
    }

    fileprivate func isAtOrAfter(_ other: ReviewItem) -> Bool {
        !precedes(other)
    }
}

/// How a review card was settled, for "Show settled" and the Undo note.
public struct SettledReview: Identifiable, Equatable, Sendable {
    public let item: ReviewItem
    /// "Word confirmed", "Change accepted".
    public let outcome: String
    /// Counts decisions, so the same card settled again is a new note.
    public let serial: Int
    /// The undo history right after the decision; nil when confirming changed nothing (the fix was in already).
    var history: Int?
    /// A card confirmed while being tried, to list again as it was if the confirmation is undone.
    var trial: ReviewTrial?
    public var id: String { item.id }
}

/// What a card's buttons and keys do.
public enum ReviewDecision: Equatable, Sendable {
    /// The card's blue button (Return): confirm what the card shows (the reading or fix
    /// picked), confirm the word, accept the change.
    case primary
    /// Reject a proposed change (Delete).
    case reject
    /// Try the n-th reading of a line (1 to 9): it goes in, the card stays until confirmed.
    case variant(Int)
    /// Try the n-th suggested fix of an issue card (1 to 9): applied, the card stays until confirmed.
    case suggestion(Int)
    /// Accept a reading speed no fix can bring down (an issue card's Ignore).
    case ignoreReadingSpeed
}

/// A card whose options are being tried: what they were when the first was
/// picked, the cues before it, and what is applied now.
public struct ReviewTrial: Equatable, Sendable {
    public let item: ReviewItem
    /// The cues when the first option was tried.
    let before: [Cue]
    /// The options in place, by `ReviewSuggestion.key`: at most one a group.
    var picks: Set<String> = []
    /// The cues the tried fix put in the track, and those it took out (merged, deleted).
    var result: [Cue] = []
    var removed: Set<Cue.ID> = []
}

/// A one-click fix on an issue card: "Extend to 00:00:02:20", "Rebalance lines".
public struct ReviewSuggestion: Hashable, Sendable {
    public enum Action: Hashable, Sendable {
        case fix(QCFix)
        /// In translation mode: the source's text as the translation.
        case copySource(String)
        /// In translation mode: the best translation memory match.
        case useMemory(String)
        /// Split in two where the speaker pauses; each half's text as it will read.
        case splitAt(PauseSplit, first: String, second: String)
    }

    /// What an option changes. One option a group can be in place at a time; options of
    /// different groups apply together, except that a Cue option (merge, split, delete) stands alone.
    public enum Group: Int, Hashable, Sendable {
        /// A Fix All row: one timing and one text option that together clear every issue.
        case all
        case timing
        /// The words or their lines: rebalance, the source, a memory match.
        case text
        /// The cue as a whole: merge, split, delete.
        case cue
    }

    public var title: String
    /// What the text becomes, for fixes that change it.
    public var preview: String?
    public var action: Action
    /// Which issues it fixes, in a few words: "reading speed, too short".
    public var fixes: String = ""
    /// The same, one name an issue: what `fixes` is made of.
    public var clears: [String] = []
    /// For a Fix All row: the options (by index in the card's list) it picks.
    public var parts: [Int] = []
    /// Names the option across updates of the list: "extendEnd#0", "copySource#0".
    public var key: String = ""

    public var group: Group {
        if !parts.isEmpty { return .all }
        switch action {
        case .copySource, .useMemory: return .text
        case .splitAt: return .cue
        case .fix(let fix):
            switch fix.purpose {
            case .rebalance: return .text
            case .mergeWithNext, .split, .delete: return .cue
            default: return .timing
            }
        }
    }
}

extension EditorState {
    /// Everything to review, or one kind of it, in time order.
    public func reviewItems(in scope: ReviewScope) -> [ReviewItem] {
        // Nothing shows until the episode brief is confirmed, so it is all reviewed with the brief in place.
        guard !isReviewHeldForBrief else { return [] }
        var items: [ReviewItem] = []
        for cue in track.cues {
            if scope == .all || scope == .changes, pendingReview?.change(forCue: cue.id) != nil {
                items.append(ReviewItem(cueID: cue.id, kind: .change, start: cue.start))
            }
            if scope == .all || scope == .choices, cue.flag?.isResolved == false {
                items.append(ReviewItem(cueID: cue.id, kind: .choice, start: cue.start))
            }
            if scope == .all || scope == .words, let words = cue.unsureWords {
                items += words.enumerated().map { ReviewItem(cueID: cue.id, kind: .word($0.offset), start: cue.start, word: $0.element.text) }
            }
            let cueIssues = issues[cue.id] ?? []
            if scope == .all || scope == .issues, cueIssues.contains(where: { !$0.kind.isFrameIssue }) {
                items.append(ReviewItem(cueID: cue.id, kind: .issues, start: cue.start))
            }
            if scope == .all || scope == .frames, cueIssues.contains(where: \.kind.isFrameIssue) {
                items.append(ReviewItem(cueID: cue.id, kind: .frames, start: cue.start))
            }
        }
        // Cues a tool proposes to add are not in the track yet.
        if scope == .all || scope == .changes {
            items += proposedInserts.map { ReviewItem(cueID: $0.cueID, kind: .change, start: $0.cue.start) }
        }
        return items.sorted { $0.precedes($1) }
    }

    /// What the sidebar lists under its filter.
    public var reviewItems: [ReviewItem] { reviewItems(in: reviewScope) }

    /// The cues with something to review in `scope`; in `.all`, in any.
    public func cueIDsToReview(in scope: ReviewScope) -> Set<Cue.ID> {
        Set(reviewItems(in: scope).map(\.cueID))
    }

    /// How many things a filter chip counts: cues with issues, words to check,
    /// lines to choose, changes to decide; everything for `.all`.
    public func reviewCount(in scope: ReviewScope) -> Int {
        reviewItems(in: scope).count
    }

    /// The card the sidebar marks: the one last picked while its cue is selected,
    /// else the first card of the selected cue.
    public var currentReviewItem: ReviewItem? {
        // A card being tried stays current while its cue is selected (or once the fix deleted it).
        if let id = reviewItemID, let trial = reviewTrials[id],
           selectedCueID == trial.item.cueID || cue(withID: trial.item.cueID) == nil { return trial.item }
        guard let selectedCueID else { return nil }
        let items = reviewCards.filter { $0.cueID == selectedCueID }
        return items.first { $0.id == reviewItemID } ?? items.first
    }

    /// Whether the sidebar is on screen (the title bar button and View › Show Review).
    public var isReviewSidebarVisible: Bool { wantsReviewSidebar }

    /// Whether any card would show, without building them.
    var hasAnythingToReview: Bool {
        guard !isReviewHeldForBrief else { return false }
        return pendingReview != nil || !issues.isEmpty
            || track.cues.contains { $0.flag?.isResolved == false || $0.unsureWords?.isEmpty == false }
    }

    /// Selects a card and its cue (the list, video and timeline go there).
    public func selectReviewItem(_ item: ReviewItem) {
        if reviewEditingItem.map({ $0.id != item.id }) ?? false { reviewEditingItem = nil }
        reviewItemID = item.id
        let wasSelected = selectedCueID == item.cueID
        select(item.cueID)
        // Selecting the same cue again does not seek; a card always goes to its cue.
        if wasSelected, hasMedia, let start = cue(withID: item.cueID)?.start ?? proposedChange(forCue: item.cueID)?.cue.start {
            playback.seek(toFrame: start.firstFrame(at: frameRate), rate: frameRate)
        }
    }

    /// Selects the next (or previous) card under the filter. Returns false when there is none that way.
    @discardableResult
    func stepReviewItem(forward: Bool) -> Bool {
        let items = reviewCards
        let next: ReviewItem?
        if let current = currentReviewItem, let index = items.firstIndex(of: current) {
            let target = index + (forward ? 1 : -1)
            next = items.indices.contains(target) ? items[target] : nil
        } else if let selected = selectedCue {
            next = forward ? items.first { $0.start > selected.start } : items.last { $0.start < selected.start }
        } else {
            next = forward ? items.first : items.last
        }
        guard let next else { return false }
        selectReviewItem(next)
        return true
    }

    /// Settles a card as asked, as one undoable edit, and moves on to the next card.
    public func decide(_ item: ReviewItem, _ decision: ReviewDecision) {
        let history = historySerial
        let trial = reviewTrials[item.id]
        let outcome: String
        switch (item.kind, decision) {
        case (.change, .primary):
            acceptChanges(to: [item.cueID])
            outcome = "Change accepted"
        case (.change, .reject):
            rejectChanges(to: [item.cueID])
            outcome = "Change rejected"
        case (.choice, .variant(let index)):
            guard let flag = cue(withID: item.cueID)?.flag, flag.variants.indices.contains(index) else { return }
            if currentReviewItem != item { selectReviewItem(item) }
            startTrial(of: item)
            if flag.chosen != index || !flag.isResolved { chooseVariant(index, forCue: item.cueID) }
            return
        case (.choice, .primary):
            guard let flag = cue(withID: item.cueID)?.flag else { return }
            let original = reviewTrials[item.id].map { $0.before.first { $0.id == item.cueID }?.flag?.chosen } ?? flag.chosen
            if !flag.isResolved { chooseVariant(flag.chosen, forCue: item.cueID) }
            outcome = original == flag.chosen ? "Reading kept" : "Other reading used"
        case (.issues, .suggestion(let index)), (.frames, .suggestion(let index)):
            guard index < reviewSuggestions(for: item).count else { return }
            tryFix(index, of: item)
            return
        case (.issues, .ignoreReadingSpeed):
            guard canIgnoreReadingSpeed(item), let index = track.cues.firstIndex(where: { $0.id == item.cueID }) else { return }
            let speed = track.cues[index].readingSpeed
            edit("Ignore Reading Speed") { track in track.cues[index].acceptedReadingSpeed = speed }
            outcome = "Reading speed \(Int(speed.rounded())) c/s accepted"
        case (.issues, .primary), (.frames, .primary):
            // Nothing tried yet: the first option goes in to be seen; the next Return confirms it.
            let picked = pickedSuggestions(of: item)
            guard !picked.isEmpty else {
                if suggestions(forCue: item.cueID).isEmpty { return }
                tryFix(0, of: item)
                return
            }
            let options = reviewSuggestions(for: item)
            outcome = options.first { !$0.parts.isEmpty && Set($0.parts) == picked }?.title
                ?? picked.sorted().compactMap { options[safe: $0]?.title }.joined(separator: " + ")
        case (.word(let index), .primary):
            let word = cue(withID: item.cueID)?.unsureWords?[safe: index]?.text ?? "Word"
            confirmUnsureWord(index, forCue: item.cueID)
            outcome = "“\(word)” confirmed"
        default:
            return
        }
        reviewTrials[item.id] = nil
        settledReviews.removeAll { $0.id == item.id }
        var settled = SettledReview(item: item, outcome: outcome, serial: (lastSettledReview?.serial ?? settledReviews.count) + 1)
        settled.history = historySerial == history ? nil : historySerial
        settled.trial = trial
        lastSettledHistory = historySerial
        settledReviews.append(settled)
        lastSettledReview = settledReviews.last
        // The next card: the first at or after the settled one (a cue's next word takes its place).
        let cards = reviewCards
        if let next = cards.first(where: { $0.isAtOrAfter(item) }) ?? cards.first {
            selectReviewItem(next)
        }
    }

    /// What the sidebar lists: the cards under the filter, and the cards being tried or
    /// edited even once their issue is gone, until they are confirmed.
    public var reviewCards: [ReviewItem] {
        var cards = reviewItems
        let pinned = reviewTrials.values.map(\.item) + [reviewEditingItem].compactMap { $0 }
        for item in pinned where (reviewScope == .all || item.kind.scope == reviewScope) && !cards.contains(where: { $0.id == item.id }) {
            cards.append(item)
        }
        return cards.sorted { $0.precedes($1) }
    }

    /// Whether the card offers Ignore: the cue reads too fast and no option fixes that.
    public func canIgnoreReadingSpeed(_ item: ReviewItem) -> Bool {
        guard item.kind == .issues, cardIssues(item).contains(where: { if case .readingSpeed = $0.kind { true } else { false } }) else { return false }
        let name = QCIssue.Kind.readingSpeed(0).shortName
        return !reviewSuggestions(for: item).contains { $0.clears.contains(name) && $0.parts.isEmpty }
    }

    /// The issues a card shows: the cue's frame issues on its Frames card, the others on its Issues card.
    public func cardIssues(_ item: ReviewItem) -> [QCIssue] {
        let all = issues[item.cueID] ?? []
        switch item.kind {
        case .issues: return all.filter { !$0.kind.isFrameIssue }
        case .frames: return all.filter(\.kind.isFrameIssue)
        default: return []
        }
    }

    /// Who speaks a cue, when known: its speaker, or its one voice (the source cue's when translating,
    /// else the transcript's words under it).
    func speaker(of cue: Cue) -> String? {
        cue.speaker ?? sourceCues[cue.id]?.speaker ?? voices(for: cue).flatMap { $0.count == 1 ? $0.first : nil }
    }

    /// The fixes an issue card offers, kept up to date with the cues around it: worked out
    /// from the cue as it was before any of its options was tried.
    public func reviewSuggestions(for item: ReviewItem) -> [ReviewSuggestion] {
        let all = reviewTrials[item.id].map { suggestions(forCue: item.cueID, in: base(of: $0)) } ?? suggestions(forCue: item.cueID)
        // Those picked, and those that fix an issue the card shows (saying only which): an option
        // for an issue already fixed, or for the cue's other card, would only confuse.
        let open = Set(cardIssues(item).map(\.kind.shortName))
        var kept: [Int] = []
        for index in all.indices {
            let option = all[index]
            let inPlace = option.parts.isEmpty ? isInPlace(option, of: item) : option.parts.allSatisfy { isInPlace(all[$0], of: item) }
            if inPlace || !open.isDisjoint(with: option.clears) {
                kept.append(index)
            }
        }
        return kept.compactMap { index -> ReviewSuggestion? in
            var option = all[index]
            if !option.parts.isEmpty {
                // A Fix All row keeps its parts, or goes.
                let parts = option.parts.compactMap { kept.firstIndex(of: $0) }
                guard parts.count == option.parts.count else { return nil }
                option.parts = parts
            } else if !isInPlace(option, of: item) {
                option.fixes = option.clears.filter(open.contains).joined(separator: ", ")
            }
            return option
        }
    }

    /// The cues as they are, with those the card's options changed as they were before.
    /// Once the cue was changed by hand after an option went in, it is taken as it is.
    private func base(of trial: ReviewTrial) -> [Cue] {
        if isEditedSince(trial) { return track.cues }
        let touched = Set(trial.result.map(\.id)).union(trial.removed).union([trial.item.cueID])
        return (track.cues.filter { !touched.contains($0.id) } + trial.before.filter { touched.contains($0.id) })
            .sorted { $0.start < $1.start }
    }

    /// The options (by index) picked on the card and still in place: none once undone or edited
    /// over, and not an option whose values changed since (the room after a cue grew).
    public func pickedSuggestions(of item: ReviewItem) -> Set<Int> {
        let options = reviewSuggestions(for: item)
        return Set(options.indices.filter { options[$0].parts.isEmpty && isInPlace(options[$0], of: item) })
    }

    /// Whether the card's n-th option shows as picked (a Fix All row: while its parts are).
    public func isPicked(_ index: Int, of item: ReviewItem) -> Bool {
        let options = reviewSuggestions(for: item)
        guard let option = options[safe: index] else { return false }
        if !option.parts.isEmpty { return option.parts.allSatisfy { options.indices.contains($0) && isInPlace(options[$0], of: item) } }
        return isInPlace(option, of: item)
    }

    private func isInPlace(_ option: ReviewSuggestion, of item: ReviewItem) -> Bool {
        guard let trial = reviewTrials[item.id], trial.picks.contains(option.key) else { return false }
        let now = cue(withID: item.cueID)
        switch option.action {
        case .copySource(let text), .useMemory(let text):
            return now?.text == text
        case .splitAt(let split, let first, _):
            return now?.text == first && now?.end == split.firstEnd
        case .fix(let fix):
            switch option.group {
            case .timing: return now?.start == fix.start && now?.end == fix.end
            case .text: return now?.text == fix.text
            default: return trial.result.allSatisfy { cue(withID: $0.id) == $0 } && trial.removed.allSatisfy { cue(withID: $0) == nil }
            }
        }
    }

    /// Whether the cues an option put in were changed since (typed over, retimed by hand).
    private func isEditedSince(_ trial: ReviewTrial) -> Bool {
        trial.result.contains { result in cue(withID: result.id).map { $0 != result } ?? false }
            || trial.result.isEmpty && trial.removed.isEmpty && cue(withID: trial.item.cueID) != trial.before.first { $0.id == trial.item.cueID }
    }

    /// Keeps the card listed until it is confirmed.
    private func startTrial(of item: ReviewItem) {
        reviewItemID = item.id
        guard reviewTrials[item.id] == nil else { return }
        reviewTrials[item.id] = ReviewTrial(item: item, before: track.cues)
    }

    /// Picks the card's n-th option (or takes it back if picked): with the options picked
    /// in other groups, in place of the one picked in its group, as one undoable edit.
    /// Only the cues the options touch change; edits elsewhere (other cards' fixes) stay.
    private func tryFix(_ index: Int, of item: ReviewItem) {
        if currentReviewItem?.id != item.id { selectReviewItem(item) }
        startTrial(of: item)
        // Changed by hand since: what is there now is where the options start from, and nothing is picked.
        if let trial = reviewTrials[item.id], isEditedSince(trial) {
            reviewTrials[item.id] = ReviewTrial(item: item, before: track.cues)
        }
        guard var trial = reviewTrials[item.id] else { return }
        let options = reviewSuggestions(for: item)
        guard let suggestion = options[safe: index] else { return }
        let current = pickedSuggestions(of: item)
        let picks: Set<Int>
        if !suggestion.parts.isEmpty {
            picks = Set(suggestion.parts)
        } else if current.contains(index) {
            picks = current.subtracting([index])
        } else if suggestion.group == .cue {
            picks = [index]
        } else {
            picks = current.filter { options[$0].group != suggestion.group && options[$0].group != .cue }.union([index])
        }
        guard picks != current else { return }
        let base = base(of: trial)
        // Cue options first, then timing, then text: text last so a timing option does not put the old words back.
        let applied = picks.sorted { (options[$0].group.rawValue, $0) < (options[$1].group.rawValue, $1) }
            .reduce(base) { cues, pick in applying(options[pick], toCue: item.cueID, in: cues) }
        // What the options change, and what the ones tried before changed (put back as it was).
        let appliedByID = Dictionary(applied.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let baseIDs = Set(base.map(\.id))
        let changed = Set(base.filter { appliedByID[$0.id] != $0 }.map(\.id)).union(appliedByID.keys.filter { !baseIDs.contains($0) })
        let touched = changed.union(trial.result.map(\.id)).union(trial.removed).union([item.cueID])
        let putBack = applied.filter { touched.contains($0.id) }
        edit(picks.isEmpty ? "Take Back \(suggestion.title)" : suggestion.title) { track in
            track.cues = track.cues.filter { !touched.contains($0.id) } + putBack
        }
        trial.picks = Set(picks.map { options[$0].key })
        trial.result = applied.filter { changed.contains($0.id) }.compactMap { cue(withID: $0.id) }
        trial.removed = changed.subtracting(appliedByID.keys)
        reviewTrials[item.id] = trial
        reviewItemID = item.id
    }

    /// `cues` with the suggestion applied to the cue.
    func applying(_ suggestion: ReviewSuggestion, toCue id: Cue.ID, in cues: [Cue]) -> [Cue] {
        guard let index = cues.firstIndex(where: { $0.id == id }) else { return cues }
        var cues = cues
        switch suggestion.action {
        case .copySource(let text), .useMemory(let text):
            cues[index].text = text
        case .splitAt(let split, let first, let second):
            guard var (head, tail) = halves(of: cues[index], at: split.secondStart) else { return cues }
            head.end = split.firstEnd
            head.text = first
            head.unsureWords = Self.words(cues[index].unsureWords, in: first)
            tail.text = second
            tail.unsureWords = Self.words(cues[index].unsureWords, in: second)
            cues[index] = head
            cues.insert(tail, at: index + 1)
        case .fix(let fix):
            switch fix.purpose {
            case .mergeWithNext:
                guard index + 1 < cues.count else { return cues }
                cues[index] = Self.merged(cues[index], with: cues[index + 1], text: fix.text)
                cues.remove(at: index + 1)
            case .split:
                guard let (first, second) = halves(of: cues[index], at: nil) else { return cues }
                cues[index] = first
                cues.insert(second, at: index + 1)
            case .delete:
                cues.remove(at: index)
            case .rebalance:
                cues[index].text = fix.text
            default:
                // Timing only, so it combines with a text option.
                let next = cues[(index + 1)...].firstIndex { $0.position == cues[index].position }
                cues[index].start = fix.start
                cues[index].end = fix.end
                if let start = fix.nextStart, let next { cues[next].start = start }
            }
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// One-click fixes for a cue's QC issues, the likeliest first: a memory match or
    /// the source for an untranslated cue, then timing, line and cue fixes.
    public func suggestions(forCue id: Cue.ID, in base: [Cue]? = nil) -> [ReviewSuggestion] {
        let cues = base ?? track.cues
        guard let index = cues.firstIndex(where: { $0.id == id }) else { return [] }
        let cue = cues[index]
        let context = QualityControl.Context(frameRate: frameRate, shotChanges: shotChangeFrames)
        var issues = self.issues[id] ?? []
        if base != nil {
            let window = max(0, index - 2)..<min(cues.count, index + 3)
            issues = (QualityControl.check(Array(cues[window]), preset: qcPreset, context: context)[id] ?? [])
                + issues.filter { $0.kind == .notTranslated }
        }
        guard !issues.isEmpty else { return [] }
        var result: [ReviewSuggestion] = []
        if issues.contains(where: { $0.kind == .notTranslated || $0.kind == .empty }), let source = sourceCues[id], !source.text.isEmpty {
            if let match = memoryMatches(for: id).first {
                result.append(ReviewSuggestion(title: "Use Memory Match (\(match.percent))", preview: match.entry.target, action: .useMemory(match.entry.target), fixes: "not translated", clears: ["not translated"]))
            }
            result.append(ReviewSuggestion(title: "Copy the Source", preview: source.text, action: .copySource(source.text), fixes: "not translated", clears: ["not translated"]))
        }
        let spoken = spokenSpan(of: cue)
        for fix in QualityControl.fixes(for: index, in: cues, preset: qcPreset, context: context, speaker: speaker(of:)) {
            // An untranslated cue is filled, not removed.
            if fix.purpose == .delete, !result.isEmpty { continue }
            // Timing stays over the words: never starting after the first or ending before the last.
            if fix.purpose.changesTimingOfCue, let spoken, fix.start > spoken.start || fix.end < spoken.end { continue }
            var names: [String] = []
            for kind in fix.clears where !names.contains(kind.shortName) { names.append(kind.shortName) }
            let changesText = fix.purpose == .rebalance || (fix.purpose == .mergeWithNext && fix.text.contains("\n") && fix.text != cue.text)
            result.append(ReviewSuggestion(
                title: title(of: fix, for: cue), preview: changesText ? fix.text : nil, action: .fix(fix),
                fixes: names.joined(separator: ", "), clears: names
            ))
        }
        // Splitting where the speaker pauses comes before retiming the cue.
        if let split = pauseSplit(forCueAt: index, in: cues, issues: issues) { result.insert(split, at: 0) }
        // Keys name each option across updates: its kind, and which of that kind.
        var counts: [String: Int] = [:]
        for position in result.indices {
            let kind = switch result[position].action {
            case .splitAt: "splitAtPause"
            case .copySource: "copySource"
            case .useMemory: "useMemory"
            case .fix(let fix): "\(fix.purpose)"
            }
            result[position].key = "\(kind)#\(counts[kind, default: 0])"
            counts[kind, default: 0] += 1
        }
        return withFixAll(result, forCueAt: index, in: cues)
    }

    /// When the cue's words are said, from the transcript's word times (first word's start,
    /// last word's end); nil without them.
    func spokenSpan(of cue: Cue) -> (start: MediaTime, end: MediaTime)? {
        guard !isTranslating, let transcript = storedTranscripts.last?.words, !transcript.isEmpty else { return nil }
        let words = cue.text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let times = PauseSplitter.wordTimes(words, in: transcript.filter { $0.end > cue.start - .oneSecond && $0.start < cue.end + .oneSecond }),
              let first = times.compactMap({ $0 }).first, let last = times.compactMap({ $0 }).last
        else { return nil }
        return (first.start, last.end)
    }

    /// Splitting where the speaker pauses, for a cue too fast, too long or with too many or long
    /// lines: the best split point whose halves clear an issue and add none.
    private func pauseSplit(forCueAt index: Int, in cues: [Cue], issues: [QCIssue]) -> ReviewSuggestion? {
        let cue = cues[index]
        let splittable = issues.contains {
            switch $0.kind {
            case .readingSpeed, .tooLong, .tooManyLines, .lineTooLong: true
            default: false
            }
        }
        guard splittable else { return nil }
        let words = isTranslating ? [] : storedTranscripts.last?.words ?? []
        let context = QualityControl.Context(frameRate: frameRate, shotChanges: shotChangeFrames)
        let before = Set(issues.map(\.kind.shortName))
        let window = max(0, index - 2)..<min(cues.count, index + 3)
        let neighbours = QualityControl.check(Array(cues[window]), preset: qcPreset, context: context)
            .filter { $0.key != cue.id }.values.reduce(0) { $0 + $1.count }
        let splits = PauseSplitter.splits(of: cue, words: words, rate: frameRate, shotChanges: shotChangeFrames, gapFrames: qcPreset.minimumGapFrames)
        for split in splits.prefix(6) {
            let first = QualityControl.rebalanced(split.first, preset: qcPreset) ?? split.first
            let second = QualityControl.rebalanced(split.second, preset: qcPreset) ?? split.second
            var option = ReviewSuggestion(
                title: split.isSpeakerChange ? "Split Between the Speakers"
                    : split.isAtCut ? "Split at the Cut After “\(split.after)”"
                    : split.pause.map { "Split at the Pause After “\(split.after)” (\($0.shortSeconds))" } ?? "Split After “\(split.after)”",
                preview: "\(first.replacing("\n", with: " "))\n\(second.replacing("\n", with: " "))",
                action: .splitAt(split, first: first, second: second)
            )
            let result = applying(option, toCue: cue.id, in: cues)
            guard let at = result.firstIndex(where: { $0.id == cue.id }) else { continue }
            let range = max(0, at - 2)..<min(result.count, at + 4)
            let after = QualityControl.check(Array(result[range]), preset: qcPreset, context: context)
            let halves = [result[at].id, result[at + 1].id]
            let left = Set(halves.flatMap { after[$0] ?? [] }.map(\.kind.shortName))
            let others = after.filter { !halves.contains($0.key) }.values.reduce(0) { $0 + $1.count }
            guard left.isSubset(of: before), left.count < before.count, others <= neighbours else { continue }
            option.clears = before.subtracting(left).sorted()
            option.fixes = option.clears.joined(separator: ", ")
            return option
        }
        return nil
    }

    /// The options in groups (each group where its best option ranks), with a Fix All row
    /// first when one timing and one text option together clear every issue of the cue.
    private func withFixAll(_ options: [ReviewSuggestion], forCueAt index: Int, in track: [Cue]) -> [ReviewSuggestion] {
        let order = options.map(\.group).reduce(into: [ReviewSuggestion.Group]()) { if !$0.contains($1) { $0.append($1) } }
        var sorted = options.enumerated().sorted {
            (order.firstIndex(of: $0.element.group)!, $0.offset) < (order.firstIndex(of: $1.element.group)!, $1.offset)
        }.map(\.element)
        let id = track[index].id
        let context = QualityControl.Context(frameRate: frameRate, shotChanges: shotChangeFrames)
        let window = max(0, index - 2)..<min(track.count, index + 3)
        let neighbourIssues = QualityControl.check(Array(track[window]), preset: qcPreset, context: context)
            .filter { $0.key != id }.values.reduce(0) { $0 + $1.count }
        for timing in sorted.indices where sorted[timing].group == .timing {
            for text in sorted.indices where sorted[text].group == .text {
                let cues = applying(sorted[text], toCue: id, in: applying(sorted[timing], toCue: id, in: track))
                guard let at = cues.firstIndex(where: { $0.id == id }) else { continue }
                let range = max(0, at - 2)..<min(cues.count, at + 3)
                let after = QualityControl.check(Array(cues[range]), preset: qcPreset, context: context)
                guard after[id] == nil, after.values.reduce(0, { $0 + $1.count }) <= neighbourIssues else { continue }
                var all = ReviewSuggestion(
                    title: "Fix All: \(sorted[timing].title) + \(sorted[text].title)", preview: sorted[text].preview,
                    action: sorted[timing].action, fixes: "everything",
                    clears: Array(Set(sorted[timing].clears + sorted[text].clears))
                )
                all.parts = [timing + 1, text + 1]
                all.key = "fixAll#0"
                sorted.insert(all, at: 0)
                return sorted
            }
        }
        return sorted
    }

    private func title(of fix: QCFix, for cue: Cue) -> String {
        switch fix.purpose {
        case .extendEnd: "Extend to \(label(for: fix.end))"
        case .startEarlier: "Start at \(label(for: fix.start))"
        case .extendBoth: "Show \(label(for: fix.start)) – \(label(for: fix.end))"
        case .trimEnd, .trimToMaximum: "End at \(label(for: fix.end))"
        case .moveNextStart: "Start the Next Cue at \(label(for: fix.nextStart ?? fix.end))"
        case .snapStart: "Start at the Cut (\(label(for: fix.start)))"
        case .snapEnd: "End at the Cut (\(label(for: fix.end)))"
        case .endBeforeCut: "End \(qcPreset.minimumGapFrames) Frames Before the Cut"
        case .endAfterCut: "End \(qcPreset.shotChangeFrames ?? 0) Frames After the Cut (\(label(for: fix.end)))"
        case .rebalance: "Rebalance Lines"
        case .mergeWithNext: "Merge with the Next Cue"
        case .split: "Split in Two"
        case .delete: "Delete the Cue"
        }
    }

    /// Settled cards whose item is not open again (an undo reopens it), in time order.
    public var settledReviewsToShow: [SettledReview] {
        let open = Set(reviewItems(in: .all).map(\.id))
        return settledReviews.filter { !open.contains($0.id) && ($0.item.kind.scope == reviewScope || reviewScope == .all) }
            .sorted { $0.item.precedes($1.item) }
    }

    /// Undoes the last decision (the sidebar's Undo note).
    public func undoLastReviewDecision() {
        guard let last = lastSettledReview, canUndoLastReviewDecision else { return }
        // A decision that was an edit is undone; one that only confirmed what was in place reopens the card.
        if last.history != nil { perform(.undo) }
        if let trial = last.trial { reviewTrials[last.id] = trial }
        settledReviews.removeAll { $0.id == last.id }
        lastSettledReview = nil
        if let item = reviewCards.first(where: { $0.id == last.id }) { selectReviewItem(item) }
    }

    /// Whether the Undo note still applies: nothing has been done or undone since the decision.
    public var canUndoLastReviewDecision: Bool {
        guard let last = lastSettledReview else { return false }
        return last.history.map { $0 == historySerial } ?? (last.serial == settledReviews.last?.serial && lastSettledHistory == historySerial)
    }

    /// Opens the card's cue for editing right in the card: its text (a word to
    /// check comes selected, to type over it), and its timing for issues.
    public func editReviewItem(_ item: ReviewItem) {
        reviewItemID = item.id
        select(item.cueID)
        reviewEditingItem = item
        if case .word(let index) = item.kind, let word = cue(withID: item.cueID)?.unsureWords?[safe: index] {
            wordSelectionRequest = WordSelectionRequest(cueID: item.cueID, word: word.text, serial: (wordSelectionRequest?.serial ?? 0) + 1)
        }
    }

    /// Ends editing in the card (⌘Return, Esc, Done). If the edit settled the card,
    /// the next card is picked; the sidebar takes the keys again.
    public func finishEditingReviewItem() {
        guard let item = reviewEditingItem else { return }
        reviewEditingItem = nil
        isEditingText = false
        let items = reviewItems
        if !items.contains(where: { $0.id == item.id }), let next = items.first(where: { $0.isAtOrAfter(item) }) ?? items.first {
            selectReviewItem(next)
        }
        reviewFocusRequest += 1
    }

    /// Plays the card's word, or its whole cue, then pauses.
    public func playReviewItem(_ item: ReviewItem) {
        if case .word(let index) = item.kind, cue(withID: item.cueID)?.unsureWords?[safe: index]?.start != nil {
            playUnsureWord(index, forCue: item.cueID)
            return
        }
        guard hasMedia, let cue = cue(withID: item.cueID) ?? proposedChange(forCue: item.cueID)?.cue else { return }
        playback.seek(toFrame: cue.start.firstFrame(at: frameRate), rate: frameRate)
        playbackStopTime = cue.end
        playback.play(rate: 1)
    }

    /// Whether the sidebar is showing `scope`'s cards (the filter commands' check marks).
    func isShowingReview(_ scope: ReviewScope) -> Bool {
        isReviewSidebarVisible && reviewScope == scope
    }

    /// Shows the sidebar with `scope`'s cards, or everything again if that filter is showing.
    func toggleReviewFilter(_ scope: ReviewScope) {
        if isReviewSidebarVisible, reviewScope == scope {
            reviewScope = .all
        } else {
            showReview(scope)
        }
    }

    /// Shows the sidebar with `scope`'s cards, the first of them selected unless the selected cue has one.
    func showReview(_ scope: ReviewScope) {
        reviewScope = scope
        wantsReviewSidebar = true
        if currentReviewItem == nil, let first = reviewItems.first { selectReviewItem(first) }
    }
}

extension QCIssue.Kind {
    /// Counted in frames: close to a shot change, or too short a gap before the next cue.
    var isFrameIssue: Bool {
        switch self {
        case .startNearShotChange, .endNearShotChange, .gapTooShort: true
        default: false
        }
    }

    /// The rule, in a word or two, for "Fixes …" under a suggestion.
    var shortName: String {
        switch self {
        case .empty: "no text"
        case .overlapsNext: "overlap"
        case .gapTooShort: "gap"
        case .readingSpeed: "reading speed"
        case .lineTooLong: "line length"
        case .tooManyLines: "too many lines"
        case .tooShort: "too short"
        case .tooLong: "too long"
        case .startNearShotChange, .endNearShotChange: "near a cut"
        case .notTranslated: "not translated"
        case .glossaryTermNotUsed: "glossary term"
        }
    }
}

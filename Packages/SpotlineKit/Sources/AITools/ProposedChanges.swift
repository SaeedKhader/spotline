import Foundation
import SubtitleCore

/// What an AI tool proposes: new cues, changed cues and cues to remove, plus
/// speakers for the cast list. Nothing is applied until the user accepts it,
/// per cue or all at once (docs/ARCHITECTURE.md, 7a: AI proposes, the editor disposes).
public struct ProposedChangeSet: Sendable, Equatable {
    /// "Transcription", "Translation"… for the review bar and undo.
    public var title: String
    public var changes: [ProposedChange]
    /// Speakers the changes refer to that the track does not have yet.
    public var newSpeakers: [Speaker]

    public init(title: String, changes: [ProposedChange], newSpeakers: [Speaker] = []) {
        self.title = title
        self.changes = changes
        self.newSpeakers = newSpeakers
    }

    public var isEmpty: Bool { changes.isEmpty }

    /// The change to a cue, by the cue's ID.
    public func change(forCue id: Cue.ID) -> ProposedChange? {
        changes.first { $0.cueID == id }
    }
}

/// One proposed change to one cue.
public struct ProposedChange: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        /// A new cue (transcription).
        case insert
        /// A cue with changed text, timing, speaker or addressee.
        case update(before: Cue)
        /// A cue to remove (cleanup that leaves no text).
        case delete
    }

    public var id: Cue.ID { cue.id }
    public var kind: Kind
    /// The cue as it would be after the change (for `.delete`, the cue as it is).
    public var cue: Cue
    /// Why, when the tool can say: "Profanity masked", "Guess: spoken to a woman".
    public var note: String?

    public init(kind: Kind, cue: Cue, note: String? = nil) {
        self.kind = kind
        self.cue = cue
        self.note = note
    }

    public var cueID: Cue.ID { cue.id }

    /// True for a new cue, or an update that changes the text.
    public var changesText: Bool {
        switch kind {
        case .insert: true
        case .update(let before): before.text != cue.text
        case .delete: false
        }
    }

    public var before: Cue? {
        if case .update(let before) = kind { return before }
        if case .delete = kind { return cue }
        return nil
    }

    /// An update, or nil when `after` does not differ from `before`.
    public static func update(from before: Cue, to after: Cue, note: String? = nil) -> ProposedChange? {
        before == after ? nil : ProposedChange(kind: .update(before: before), cue: after, note: note)
    }
}

extension ProposedChangeSet {
    /// Applies the changes (all of them, or those for `cueIDs`) to a track. Updates
    /// and deletes whose cue is gone are skipped; speakers the applied cues use are
    /// added to the cast list, and speakers the user confirmed keep their gender.
    public func apply(to track: inout SubtitleTrack, only cueIDs: Set<Cue.ID>? = nil) {
        let chosen = changes.filter { cueIDs?.contains($0.cueID) ?? true }
        for change in chosen {
            switch change.kind {
            case .insert:
                if !track.cues.contains(where: { $0.id == change.cueID }) { track.cues.append(change.cue) }
            case .update:
                if let index = track.cues.firstIndex(where: { $0.id == change.cueID }) {
                    var cue = change.cue
                    // A tag the user confirmed wins over a new guess.
                    if track.cues[index].addressee?.source == .confirmed { cue.addressee = track.cues[index].addressee }
                    track.cues[index] = cue
                }
            case .delete:
                track.cues.removeAll { $0.id == change.cueID }
            }
        }
        let used = Set(chosen.compactMap(\.cue.speakerID))
        for speaker in newSpeakers where used.contains(speaker.id) && !track.speakers.contains(where: { $0.id == speaker.id }) {
            track.speakers.append(speaker)
        }
        track.cues.sort { $0.start < $1.start }
    }

    /// The set without the changes for `cueIDs`.
    public func removing(_ cueIDs: Set<Cue.ID>) -> ProposedChangeSet {
        var copy = self
        copy.changes.removeAll { cueIDs.contains($0.cueID) }
        return copy
    }
}

/// Word-level differences between two texts, for showing a proposed text change.
public enum TextDiff {
    public enum Part: Equatable, Sendable {
        case same(String)
        case removed(String)
        case added(String)
    }

    /// Splits both texts into words (keeping spaces and line breaks with them)
    /// and returns the longest common subsequence as unchanged parts.
    public static func words(from old: String, to new: String) -> [Part] {
        let a = tokens(old), b = tokens(new)
        var lengths = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lengths[i][j] = a[i] == b[j] ? lengths[i + 1][j + 1] + 1 : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }
        var parts: [Part] = []
        func add(_ part: Part) {
            switch (parts.last, part) {
            case (.same(let x)?, .same(let y)): parts[parts.count - 1] = .same(x + y)
            case (.removed(let x)?, .removed(let y)): parts[parts.count - 1] = .removed(x + y)
            case (.added(let x)?, .added(let y)): parts[parts.count - 1] = .added(x + y)
            default: parts.append(part)
            }
        }
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                add(.same(a[i])); i += 1; j += 1
            } else if i < a.count, j == b.count || lengths[i + 1][j] >= lengths[i][j + 1] {
                // Removed words come before the words that replace them.
                add(.removed(a[i])); i += 1
            } else {
                add(.added(b[j])); j += 1
            }
        }
        return parts
    }

    /// Words with the whitespace after them.
    static func tokens(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inSpace = false
        for character in text {
            let space = character.isWhitespace
            if inSpace, !space {
                result.append(current)
                current = ""
            }
            current.append(character)
            inSpace = space
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

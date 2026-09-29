import Foundation

/// Grammatical gender, as far as a language's agreement needs it.
public enum Gender: String, Hashable, Sendable, Codable, CaseIterable {
    case male
    case female
    /// A group of men and women.
    case mixed
    case unknown
}

/// How many people a line speaks to. Arabic has a dual, so two is not many.
public enum ListenerCount: String, Hashable, Sendable, Codable, CaseIterable {
    case one
    case two
    case many
    case unknown
}

/// A person in the episode as the AI translator came to know them: a name
/// from the dialogue, a gender, and the transcriber's voice labels for their
/// lines. Nobody types these in; picking a variant confirms what it assumes
/// about the people in it, and the translator then treats that as fact.
public struct CastMember: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var name: String
    public var gender: Gender
    /// True once a variant the user picked settled the gender.
    public var isConfirmed: Bool
    /// The transcriber's labels for this person's voice ("speaker_1").
    public var voices: [String]

    public init(id: UUID = UUID(), name: String, gender: Gender = .unknown, isConfirmed: Bool = false, voices: [String] = []) {
        self.id = id
        self.name = name
        self.gender = gender
        self.isConfirmed = isConfirmed
        self.voices = voices
    }

    /// Names match ignoring case and surrounding spaces.
    public func isNamed(_ other: String) -> Bool {
        name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(other.trimmingCharacters(in: .whitespaces)) == .orderedSame
    }
}

/// One way to translate a line, with who it assumes speaks and is spoken to.
public struct TranslationVariant: Hashable, Sendable, Codable {
    public var text: String
    /// The speaker's name, when the translator could tell.
    public var speaker: String?
    /// The speaker's gender, for first-person agreement.
    public var speakerGender: Gender
    /// Who is spoken to, by name, when the translator could tell.
    public var listeners: [String]
    public var listenerGender: Gender
    public var listenerCount: ListenerCount

    public init(
        text: String, speaker: String? = nil, speakerGender: Gender = .unknown, listeners: [String] = [],
        listenerGender: Gender = .unknown, listenerCount: ListenerCount = .unknown
    ) {
        self.text = text
        self.speaker = speaker
        self.speakerGender = speakerGender
        self.listeners = listeners
        self.listenerGender = listenerGender
        self.listenerCount = listenerCount
    }

    /// False when the variant assumes something a confirmed cast member contradicts:
    /// a man speaking where the speaker is a woman, a woman spoken to where the listener is a man.
    public func fits(_ cast: [CastMember]) -> Bool {
        let confirmed = cast.filter(\.isConfirmed)
        func gender(of name: String) -> Gender? {
            confirmed.first { $0.isNamed(name) }.map(\.gender).flatMap { $0 == .unknown ? nil : $0 }
        }
        if let speaker, let known = gender(of: speaker), speakerGender != .unknown, speakerGender != known { return false }
        let known = listeners.compactMap(gender(of:))
        guard !known.isEmpty, known.count == listeners.count, listenerGender != .unknown else { return true }
        if listeners.count == 1 { return listenerGender == known[0] }
        // A group: all women is feminine; any man makes it male or mixed.
        return known.allSatisfy { $0 == .female } ? listenerGender == .female : listenerGender != .female
    }
}

/// A line that can be translated more than one way ("you" for a man, a woman
/// or a group; gendered verbs and adjectives; an unclear speaker). The translator
/// writes every valid variant, puts its recommendation in the cue, and says why.
/// The flag stays with the cue (and in the project) until the user picks a
/// variant or accepts the rest.
public struct TranslationFlag: Hashable, Sendable, Codable {
    /// What makes the line ambiguous.
    public enum Reason: String, Hashable, Sendable, Codable, CaseIterable {
        /// "You": the listener's gender or number.
        case listener
        /// Verbs, adjectives or pronouns that agree with someone's gender.
        case genderedWords
        /// It is not clear who says the line.
        case speaker
    }

    public var reasons: [Reason]
    /// Every valid translation, best first once re-ranked.
    public var variants: [TranslationVariant]
    /// The variant the cue's text is now.
    public var chosen: Int
    /// 0 to 1: how sure the translator was of its recommendation.
    public var confidence: Double
    /// Why the recommendation, in one line: "Beth is talking to Morty".
    public var note: String
    /// True once the user picked a variant, accepted the rest, or edited the text.
    public var isResolved: Bool

    public init(reasons: [Reason], variants: [TranslationVariant], chosen: Int = 0, confidence: Double, note: String, isResolved: Bool = false) {
        self.reasons = reasons
        self.variants = variants
        self.chosen = min(max(chosen, 0), max(variants.count - 1, 0))
        self.confidence = confidence
        self.note = note
        self.isResolved = isResolved
    }

    public var chosenVariant: TranslationVariant? {
        variants.indices.contains(chosen) ? variants[chosen] : nil
    }

    /// Puts the variants that fit the confirmed cast first. When the chosen one
    /// no longer fits, the best one that does is chosen; when only one fits,
    /// the flag is settled. Resolved flags are left alone. Returns true when the
    /// chosen variant changed.
    @discardableResult
    public mutating func rerank(with cast: [CastMember]) -> Bool {
        guard !isResolved, variants.count > 1, cast.contains(where: \.isConfirmed) else { return false }
        let fitting = variants.indices.filter { variants[$0].fits(cast) }
        guard !fitting.isEmpty, fitting.count < variants.count else { return false }
        let current = variants[chosen]
        let order = fitting + variants.indices.filter { !fitting.contains($0) }
        variants = order.map { variants[$0] }
        let changed = !current.fits(cast)
        chosen = changed ? 0 : variants.firstIndex(of: current) ?? 0
        if fitting.count == 1 {
            isResolved = true
            confidence = 1
        }
        return changed
    }
}

extension Array where Element == CastMember {
    /// The member with that name.
    public func member(named name: String) -> CastMember? {
        first { $0.isNamed(name) }
    }

    /// Adds what a translator learned: new people, genders it guessed and voices
    /// it heard. What a pick confirmed stays.
    public mutating func merge(_ learned: [CastMember]) {
        for person in learned where !person.name.trimmingCharacters(in: .whitespaces).isEmpty {
            if let index = firstIndex(where: { $0.isNamed(person.name) }) {
                if !self[index].isConfirmed, person.gender != .unknown { self[index].gender = person.gender }
                for voice in person.voices where !self[index].voices.contains(voice) { self[index].voices.append(voice) }
            } else {
                append(CastMember(name: person.name, gender: person.gender, voices: person.voices))
            }
        }
    }

    /// Records that `name` is `gender`, as the user's pick says.
    public mutating func confirm(_ name: String, as gender: Gender) {
        guard gender == .male || gender == .female else { return }
        if let index = firstIndex(where: { $0.isNamed(name) }) {
            self[index].gender = gender
            self[index].isConfirmed = true
        } else {
            append(CastMember(name: name, gender: gender, isConfirmed: true))
        }
    }

    /// Confirms what a picked variant says about the people in it: the speaker's
    /// gender, and a single named listener's.
    public mutating func confirm(_ variant: TranslationVariant) {
        if let speaker = variant.speaker { confirm(speaker, as: variant.speakerGender) }
        if variant.listeners.count == 1 { confirm(variant.listeners[0], as: variant.listenerGender) }
    }
}

extension Cue {
    /// Re-ranks the cue's flag against the cast (`TranslationFlag.rerank`); when
    /// the chosen variant changes, the text follows. Returns true when it did.
    @discardableResult
    public mutating func rerankFlag(with cast: [CastMember]) -> Bool {
        guard var flag, !flag.isResolved else { return false }
        let changed = flag.rerank(with: cast)
        if changed, let variant = flag.chosenVariant { text = variant.text }
        self.flag = flag
        return changed
    }
}

extension SubtitleTrack {
    /// Uses a flagged cue's variant: its text goes in, the flag is settled, what
    /// the variant assumes about people is confirmed in the cast, and every other
    /// open flag is re-ranked with that. Returns the cues whose text changed besides this one.
    @discardableResult
    public mutating func choose(variant index: Int, forCue id: Cue.ID) -> [Cue.ID] {
        guard let cueIndex = cues.firstIndex(where: { $0.id == id }), var flag = cues[cueIndex].flag,
              flag.variants.indices.contains(index)
        else { return [] }
        let variant = flag.variants[index]
        flag.chosen = index
        flag.isResolved = true
        cues[cueIndex].flag = flag
        cues[cueIndex].text = variant.text
        cast.confirm(variant)
        return rerankFlags()
    }

    /// Re-ranks every open flag against the cast. Returns the cues whose text changed.
    @discardableResult
    public mutating func rerankFlags() -> [Cue.ID] {
        guard cast.contains(where: \.isConfirmed) else { return [] }
        var changed: [Cue.ID] = []
        for index in cues.indices where cues[index].rerankFlag(with: cast) { changed.append(cues[index].id) }
        return changed
    }

    /// Settles every open flag, keeping each cue's text.
    public mutating func resolveFlags() {
        for index in cues.indices where cues[index].flag?.isResolved == false { cues[index].flag?.isResolved = true }
    }
}

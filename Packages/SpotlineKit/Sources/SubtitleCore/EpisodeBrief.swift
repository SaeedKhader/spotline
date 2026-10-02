import Foundation

/// Who is who in an episode and how its names are spelled, built by AI right after
/// transcription (the transcript, the file name and a web lookup of the show) and
/// confirmed by the user before the review. The review and translation then use it:
/// on Confirm its people go into the track's cast, their genders settled.
public struct EpisodeBrief: Hashable, Sendable, Codable {
    /// One person: the transcriber's voice labels for them, and what the brief proposes.
    public struct Person: Identifiable, Hashable, Sendable, Codable {
        public let id: UUID
        /// The transcriber's labels for this person's voice ("speaker_1"); empty for
        /// someone only spoken about.
        public var voices: [String]
        /// The name as the show spells it ("Dunk"); empty when nobody could tell.
        public var name: String
        public var gender: Gender
        /// How the target language spells the name ("دانك").
        public var translatedName: String
        /// How sure the brief is, 0 to 1.
        public var confidence: Double
        /// Why, in a few words: "called Dunk by Egg at 03:12".
        public var note: String

        public init(
            id: UUID = UUID(), voices: [String] = [], name: String = "", gender: Gender = .unknown, translatedName: String = "",
            confidence: Double = 1, note: String = ""
        ) {
            self.id = id
            self.voices = voices
            self.name = name
            self.gender = gender
            self.translatedName = translatedName
            self.confidence = confidence
            self.note = note
        }
    }

    /// A place, a title or a made-up word, with the show's spelling.
    public struct Term: Identifiable, Hashable, Sendable, Codable {
        public let id: UUID
        /// The spelling the show uses ("Ashford Meadow").
        public var term: String
        /// How the transcript heard it, when differently ("Ash for Meadow").
        public var heardAs: [String]
        /// How the target language spells it.
        public var translation: String
        public var note: String
        public var confidence: Double
        /// Whether Confirm adds it to the glossary of the language pair.
        public var addsToGlossary: Bool

        public init(
            id: UUID = UUID(), term: String, heardAs: [String] = [], translation: String = "", note: String = "",
            confidence: Double = 1, addsToGlossary: Bool = true
        ) {
            self.id = id
            self.term = term
            self.heardAs = heardAs
            self.translation = translation
            self.note = note
            self.confidence = confidence
            self.addsToGlossary = addsToGlossary
        }
    }

    public var people: [Person]
    public var terms: [Term]
    /// What happens in the episode, in a few sentences.
    public var plot: String
    /// Scene by scene, who talks to whom and about what: one line each, "12:40 Dunk asks Egg…".
    public var scenes: String
    /// What the video shows, scene by scene: one line each, "12:40 Dunk stands before the steward's desk. In view: …".
    /// Written from a few frames of each scene (`SceneDescriber`), when sending frames is allowed; else empty.
    public var seen: String
    /// The language the brief spells names in (BCP 47), the translation's target.
    public var targetLanguage: String
    /// What the brief is about, from the file name: "A Knight of the Seven Kingdoms S01E01".
    public var work: String?
    /// False until the user confirms it; the review waits for that.
    public var isConfirmed: Bool

    public init(
        people: [Person] = [], terms: [Term] = [], plot: String = "", scenes: String = "", seen: String = "", targetLanguage: String,
        work: String? = nil, isConfirmed: Bool = false
    ) {
        self.people = people
        self.terms = terms
        self.plot = plot
        self.scenes = scenes
        self.seen = seen
        self.targetLanguage = targetLanguage
        self.work = work
        self.isConfirmed = isConfirmed
    }

    private enum CodingKeys: String, CodingKey {
        case people, terms, plot, scenes, seen, targetLanguage, work, isConfirmed
    }

    /// Briefs saved before the plot and scenes, or before what the video shows, have none.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        people = try container.decode([Person].self, forKey: .people)
        terms = try container.decode([Term].self, forKey: .terms)
        plot = try container.decodeIfPresent(String.self, forKey: .plot) ?? ""
        scenes = try container.decodeIfPresent(String.self, forKey: .scenes) ?? ""
        seen = try container.decodeIfPresent(String.self, forKey: .seen) ?? ""
        targetLanguage = try container.decode(String.self, forKey: .targetLanguage)
        work = try container.decodeIfPresent(String.self, forKey: .work)
        isConfirmed = try container.decode(Bool.self, forKey: .isConfirmed)
    }

    /// The plot, the scenes and what the video shows as notes for a translator or reviewer, nil when all are empty.
    public var storyNotes: String? {
        var parts: [String] = []
        let plot = plot.trimmingCharacters(in: .whitespacesAndNewlines)
        let scenes = scenes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !plot.isEmpty { parts.append("Plot: \(plot)") }
        if !scenes.isEmpty { parts.append("Scenes (time, who talks to whom):\n\(scenes)") }
        let seen = seen.trimmingCharacters(in: .whitespacesAndNewlines)
        if !seen.isEmpty { parts.append("What the video shows (time, who is there, from a few frames of each scene):\n\(seen)") }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// Adds a row for every voice no person has, so each speaker can be named.
    public mutating func addMissingVoices(_ voices: [String]) {
        let named = Set(people.flatMap(\.voices))
        for voice in voices where !named.contains(voice) {
            people.append(Person(voices: [voice], confidence: 0))
        }
    }

    /// A term without a leading article, in lower case: "the Seven Kingdoms" and "Seven Kingdoms" are one term.
    static func termKey(_ term: String) -> String {
        var key = term.trimmingCharacters(in: .whitespaces).lowercased()
        for article in ["the ", "a ", "an "] where key.hasPrefix(article) && key.count > article.count {
            key.removeFirst(article.count)
            break
        }
        return key
    }

    /// Makes terms that differ only by case or a leading article one term, so the glossary
    /// gets each once: the spelling without the article stays (it matches both in a
    /// line), with the first translation and note there are, and every way it was heard.
    public mutating func mergeDuplicateTerms() {
        var merged: [Term] = []
        for term in terms {
            let key = Self.termKey(term.term)
            guard !key.isEmpty, let index = merged.firstIndex(where: { Self.termKey($0.term) == key }) else {
                merged.append(term)
                continue
            }
            var kept = merged[index]
            let spelling = term.term.trimmingCharacters(in: .whitespaces)
            if spelling.count < kept.term.trimmingCharacters(in: .whitespaces).count { kept.term = spelling }
            if kept.translation.trimmingCharacters(in: .whitespaces).isEmpty { kept.translation = term.translation }
            if kept.note.isEmpty { kept.note = term.note }
            for heard in term.heardAs where !kept.heardAs.contains(heard) { kept.heardAs.append(heard) }
            kept.confidence = max(kept.confidence, term.confidence)
            kept.addsToGlossary = kept.addsToGlossary || term.addsToGlossary
            merged[index] = kept
        }
        terms = merged
    }

    /// Makes `person` and `other` one person: the other's voices join the person's, and
    /// the other goes. What the person says (name, gender, spelling) stays.
    public mutating func merge(_ other: Person.ID, into person: Person.ID) {
        guard other != person, let from = people.firstIndex(where: { $0.id == other }),
              people.contains(where: { $0.id == person })
        else { return }
        let voices = people[from].voices
        people.remove(at: from)
        guard let into = people.firstIndex(where: { $0.id == person }) else { return }
        for voice in voices where !people[into].voices.contains(voice) { people[into].voices.append(voice) }
    }
}

extension SubtitleTrack {
    /// Takes in a confirmed brief: each named person goes into the cast with their
    /// voices and spelling, and a gender the user left as male or female is settled
    /// (the translator treats it as fact). Open translation flags are re-ranked with that.
    public mutating func confirm(_ brief: EpisodeBrief) {
        var confirmed = brief
        confirmed.isConfirmed = true
        self.brief = confirmed
        for person in brief.people {
            let name = person.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            let spelling = person.translatedName.trimmingCharacters(in: .whitespaces)
            let index = cast.firstIndex { $0.isNamed(name) } ?? {
                cast.append(CastMember(name: name))
                return cast.count - 1
            }()
            // Voices belong to one person: taken from anyone else who had them.
            for other in cast.indices where other != index {
                cast[other].voices.removeAll { person.voices.contains($0) }
            }
            cast[index].voices = person.voices
            if !spelling.isEmpty { cast[index].translatedName = spelling }
            if person.gender != .unknown || !cast[index].isConfirmed {
                cast[index].gender = person.gender
                cast[index].isConfirmed = person.gender == .male || person.gender == .female
            }
        }
        rerankFlags()
    }
}

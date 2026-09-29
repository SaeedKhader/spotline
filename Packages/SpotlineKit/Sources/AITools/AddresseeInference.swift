import Foundation
import SubtitleCore

/// Guesses who each line is spoken to from the scene, on-device: turn-taking
/// (a line usually answers the previous speaker), plural and dual forms of
/// address ("you guys", "you two"), gendered forms of address ("sir", "mom"),
/// and the gender of the likely listener's voice. Lines that do not address
/// anyone (no "you", no imperative) get no tag. Scenes end at long pauses.
///
/// Each tag carries a confidence; below `AddresseeTag.reviewThreshold` the line
/// is flagged for a one-click fix (docs/ARCHITECTURE.md, 7b). Claude translation
/// reads the scene again with the text and can overrule these guesses.
public struct SceneAddresseeInferrer: Sendable {
    /// A pause this long between lines starts a new scene.
    public var scenePauseSeconds = 5.0

    public init() {}

    /// One line to tag: its cue, the text to read (the source language when translating) and its speaker.
    public struct Line: Sendable {
        public var cueID: Cue.ID
        public var text: String
        public var start: MediaTime
        public var end: MediaTime
        public var speakerID: Speaker.ID?
        /// How sure the speaker assignment is.
        public var speakerConfidence: Double

        public init(cueID: Cue.ID, text: String, start: MediaTime, end: MediaTime, speakerID: Speaker.ID?, speakerConfidence: Double = 1) {
            self.cueID = cueID
            self.text = text
            self.start = start
            self.end = end
            self.speakerID = speakerID
            self.speakerConfidence = speakerConfidence
        }
    }

    /// Tags for the lines that address someone, by cue ID.
    public func infer(_ lines: [Line], speakers: [Speaker], language: String) -> [Cue.ID: AddresseeTag] {
        let byID = Dictionary(speakers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var tags: [Cue.ID: AddresseeTag] = [:]
        for scene in scenes(lines.sorted { $0.start < $1.start }) {
            let sceneSpeakers = Set(scene.compactMap(\.speakerID))
            for (index, line) in scene.enumerated() {
                let cue = Cue(start: line.start, end: line.end, text: line.text)
                let words = Self.words(SubtitleText.visibleLines(of: cue.text).joined(separator: " "))
                let form = Self.formOfAddress(words, language: language)
                guard form.addressesSomeone else { continue }
                // The listener: the other speaker just before, else just after.
                let others = scene.enumerated().filter { $0.element.speakerID != nil && $0.element.speakerID != line.speakerID }
                let listener = others.last { $0.offset < index } ?? others.first { $0.offset > index }
                let listenerSpeaker = listener?.element.speakerID.flatMap { byID[$0] }
                let otherCount = sceneSpeakers.subtracting([line.speakerID].compactMap { $0 }).count
                tags[line.cueID] = Self.tag(
                    form: form, listener: listenerSpeaker, listenerConfidence: listener?.element.speakerConfidence ?? 0,
                    otherSpeakers: otherCount, speakerKnown: line.speakerID != nil
                )
            }
        }
        return tags
    }

    func scenes(_ lines: [Line]) -> [[Line]] {
        var scenes: [[Line]] = []
        for line in lines {
            if let last = scenes.last?.last, (line.start - last.end).seconds < scenePauseSeconds {
                scenes[scenes.count - 1].append(line)
            } else {
                scenes.append([line])
            }
        }
        return scenes
    }

    static func tag(form: FormOfAddress, listener: Speaker?, listenerConfidence: Double, otherSpeakers: Int, speakerKnown: Bool) -> AddresseeTag {
        // Explicit words decide number, and gender when they carry it.
        if let explicit = form.explicit {
            return AddresseeTag(explicit, confidence: explicit.gender == .unknown && explicit != .groupMixed ? 0.5 : 0.85)
        }
        if form.count == .many || form.count == .two {
            // Plural "you" without gender: mixed unless everyone else in the scene shares a gender.
            let addressee: Addressee = form.count == .two ? (listener?.gender == .female ? .dualFemale : .dualMale) : .groupMixed
            return AddresseeTag(addressee, confidence: form.count == .two ? 0.5 : 0.6)
        }
        guard let listener, listener.gender != .unknown else {
            return AddresseeTag(.unknown, confidence: 0.2)
        }
        // Two people talking: the listener is clear. More: turn-taking is only a hint.
        let turnTaking = otherSpeakers <= 1 ? 0.95 : otherSpeakers == 2 ? 0.7 : 0.55
        let genderCertainty = listener.source == .confirmed ? 1 : listener.confidence
        let voice = speakerKnown ? min(max(listenerConfidence, 0.3), 1) : 0.6
        let confidence = (turnTaking * genderCertainty * (0.6 + 0.4 * voice) * 100).rounded() / 100
        return AddresseeTag(listener.gender == .female ? .female : .male, confidence: confidence)
    }

    struct FormOfAddress: Equatable {
        var addressesSomeone: Bool
        var count: Addressee.Count
        /// Set when the words name the addressee's gender and number ("ladies", "sir").
        var explicit: Addressee?
    }

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .replacing("’", with: "'")
            .split(whereSeparator: { !($0.isLetter || $0 == "'") })
            .map(String.init)
    }

    static func formOfAddress(_ words: [String], language: String) -> FormOfAddress {
        let joined = " " + words.joined(separator: " ") + " "
        func has(_ phrase: String) -> Bool { joined.contains(" \(phrase) ") }
        let base = Languages.base(language)
        var form = FormOfAddress(addressesSomeone: false, count: .unknown, explicit: nil)

        let pronouns: [String: [String]] = [
            "en": ["you", "your", "yours", "yourself", "yourselves", "you're", "you've", "you'll", "you'd", "ya", "y'all"],
            "fr": ["tu", "toi", "te", "t'", "ton", "ta", "tes", "vous", "votre", "vos"],
            "es": ["tú", "tu", "te", "ti", "contigo", "usted", "ustedes", "vosotros", "vosotras", "os", "vuestro", "vuestra"],
            "de": ["du", "dich", "dir", "dein", "deine", "ihr", "euch", "euer", "sie"],
            "it": ["tu", "te", "ti", "tuo", "tua", "voi", "vi", "vostro", "lei"],
            "pt": ["tu", "você", "vocês", "te", "ti", "teu", "tua", "vós"],
        ]
        let imperatives = [
            "come", "go", "look", "listen", "wait", "stop", "get", "take", "give", "tell", "let", "let's", "sit", "stand", "stay",
            "run", "don't", "do", "be", "leave", "help", "hurry", "try", "keep", "put", "call", "shut", "move", "follow", "open",
            "close", "eat", "drink", "bring", "show", "watch", "hold", "please", "thank", "thanks", "hey", "say", "calm", "relax",
            "trust", "forgive", "remember", "forget", "believe", "see", "hear", "shoot", "drop", "hand",
        ]
        let list = pronouns[base] ?? pronouns["en"]!
        if words.contains(where: list.contains) || (base == "en" && words.first.map(imperatives.contains) == true) {
            form.addressesSomeone = true
            form.count = .one
        }
        // Number and gender named outright.
        let explicit: [(String, Addressee)] = [
            ("ladies and gentlemen", .groupMixed), ("you guys", .groupMixed), ("you all", .groupMixed), ("y'all", .groupMixed),
            ("everyone", .groupMixed), ("everybody", .groupMixed), ("folks", .groupMixed), ("children", .groupMixed),
            ("both of you", .dualMale), ("you two", .dualMale), ("boys", .groupMale), ("gentlemen", .groupMale),
            ("girls", .groupFemale), ("ladies", .groupFemale), ("sir", .male), ("mister", .male), ("dude", .male), ("bro", .male),
            ("son", .male), ("dad", .male), ("daddy", .male), ("father", .male), ("brother", .male), ("buddy", .male),
            ("young man", .male), ("my lord", .male), ("your majesty", .unknown), ("ma'am", .female), ("madam", .female),
            ("miss", .female), ("young lady", .female), ("mom", .female), ("mum", .female), ("mother", .female),
            ("sister", .female), ("my lady", .female), ("girl", .female),
            ("monsieur", .male), ("madame", .female), ("mademoiselle", .female), ("señor", .male), ("señora", .female),
            ("señorita", .female), ("chicos", .groupMale), ("chicas", .groupFemale),
        ]
        // A single word only counts as address when it is not someone's ("your mom", "the girls").
        let possessives: Set<String> = ["your", "my", "his", "her", "their", "our", "the", "a", "an", "to", "of", "that", "this", "ta", "ton", "tu", "su", "la", "le", "el"]
        func addresses(_ phrase: String) -> Bool {
            guard !phrase.contains(" ") else { return has(phrase) }
            return words.indices.contains { index in
                words[index] == phrase && (index == 0 || !possessives.contains(words[index - 1]))
            }
        }
        for (phrase, addressee) in explicit where addresses(phrase) {
            form.addressesSomeone = true
            form.count = addressee.count
            if addressee != .unknown { form.explicit = addressee }
            // "both of you" is dual; its gender comes from the listeners, so it is not explicit.
            if phrase == "both of you" || phrase == "you two" { form.explicit = nil }
            break
        }
        if base == "en", form.explicit == nil, has("you guys") || has("you people") || has("yourselves") { form.count = .many }
        if base == "fr", has("vous"), form.count == .one { form.count = .unknown }
        return form
    }
}

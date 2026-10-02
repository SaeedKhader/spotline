import Foundation
import SubtitleCore
import Testing
@testable import SubtitleTranslation

struct MatchTextTests {
    @Test func normalizesCaseAccentsMarkupAndSpacing() {
        #expect(MatchText.normalize("<i>Café</i>  au\nLAIT") == "cafe au lait")
    }

    @Test func ignoresArabicVowelMarksHamzaAndTatweel() {
        // "أنتَ مشغـــول" and "انت مشغول" read the same for matching.
        #expect(MatchText.normalize("أنتَ مشغـــول") == MatchText.normalize("انت مشغول"))
        #expect(MatchText.normalize("مدرسة") == MatchText.normalize("مدرسه"))
    }

    @Test func wholeWordsOnly() {
        #expect(MatchText.contains("the cat sat", term: "cat"))
        #expect(!MatchText.contains("concatenate", term: "cat"))
        #expect(MatchText.contains("hello, mr smith!", term: "mr smith"))
    }

    @Test func textDirection() {
        #expect(TextDirection.of(languageCode: "ar") == .rightToLeft)
        #expect(TextDirection.of(languageCode: "he-IL") == .rightToLeft)
        #expect(TextDirection.of(languageCode: "fa") == .rightToLeft)
        #expect(TextDirection.of(languageCode: "en") == .leftToRight)
        #expect(TextDirection.of(languageCode: "und", sample: "مرحبا يا Sam") == .rightToLeft)
        #expect(TextDirection.of(languageCode: "und", sample: "Hello") == .leftToRight)
        #expect(TextDirection.of(languageCode: "und") == .leftToRight)
    }
}

struct GlossaryTests {
    let glossary = Glossary(entries: [
        .init(source: "Mr. Smith", target: "السيد سميث"),
        .init(source: "Winterfell", target: "وينترفيل", note: "Place"),
        .init(source: "cat", target: "قطة"),
    ])

    @Test func findsTermsInSourceOrderAndChecksTheTarget() {
        let matches = glossary.matches(source: "Welcome to <i>Winterfell</i>, Mr. Smith.", target: "أهلاً بك في وينترفيل")
        #expect(matches.map(\.entry.source) == ["Winterfell", "Mr. Smith"])
        #expect(matches.map(\.isUsed) == [true, false])
    }

    @Test func theLongestTermWinsWhereTermsOverlap() {
        let glossary = Glossary(entries: [
            .init(source: "the Seven", target: "الآلهة السبعة"),
            .init(source: "Seven Kingdoms", target: "الممالك السبع"),
            .init(source: "the Seven Kingdoms", target: "الممالك السبع"),
            .init(source: "Kingdoms", target: "ممالك"),
        ])
        func terms(_ source: String) -> [String] { glossary.matches(source: source, target: "").map(\.entry.source) }
        // The shorter terms sit inside the longest one: only it counts.
        #expect(terms("He rules the Seven Kingdoms.") == ["the Seven Kingdoms"])
        #expect(terms("All Seven Kingdoms know.") == ["Seven Kingdoms"])
        // By itself, the shorter term counts.
        #expect(terms("By the Seven!") == ["the Seven"])
        #expect(terms("By the Seven, the Seven Kingdoms are lost.") == ["the Seven", "the Seven Kingdoms"])
        // One word of a term is not the term.
        #expect(terms("Seven of them came.").isEmpty)
        // The same term twice in the glossary: both count.
        let twice = Glossary(entries: [.init(source: "Winterfell", target: "أ"), .init(source: "winterfell", target: "ب")])
        #expect(twice.matches(source: "To Winterfell.", target: "").count == 2)
    }

    @Test func ignoresPartialWords() {
        #expect(glossary.matches(source: "Concatenate", target: "").isEmpty)
    }

    @Test func readsCSVAndTSV() {
        let csv = "source,target,note\n\"Smith, John\",جون سميث,Lead\nWinterfell,وينترفيل\n"
        let entries = Glossary.entries(fromDelimited: csv)
        #expect(entries.map(\.source) == ["Smith, John", "Winterfell"])
        #expect(entries.map(\.target) == ["جون سميث", "وينترفيل"])
        #expect(entries.first?.note == "Lead")
        let tsv = Glossary.entries(fromDelimited: "Dragon\tتنين\n")
        #expect(tsv.map(\.target) == ["تنين"])
    }

    @Test func mergeReplacesSameSourceTerm() {
        var copy = glossary
        copy.merge([.init(source: "winterfell", target: "وينترفل"), .init(source: "Dragon", target: "تنين")])
        #expect(copy.entries.count == 4)
        #expect(copy.entries[1].target == "وينترفل")
        #expect(copy.entries[1].note == "Place")
    }
}

struct TranslationMemoryTests {
    @Test func exactMatchIgnoresCaseMarkupAndSpacing() {
        var memory = TranslationMemory()
        memory.record(source: "Where are you going?", target: "إلى أين أنت ذاهب؟")
        let matches = memory.matches(for: "<i>where are  you going?</i>")
        #expect(matches.count == 1)
        #expect(matches.first?.isExact == true)
        #expect(matches.first?.percent == "100%")
    }

    @Test func fuzzyMatchesAreScoredAndSorted() {
        var memory = TranslationMemory()
        let date = Date(timeIntervalSince1970: 0)
        memory.record(source: "I will see you tomorrow at the station", target: "A", at: date)
        memory.record(source: "I will see you tomorrow at the airport", target: "B", at: date)
        memory.record(source: "Completely different words here", target: "C", at: date)
        let matches = memory.matches(for: "I will see you tomorrow at the station, John")
        #expect(matches.map(\.entry.target) == ["A", "B"])
        #expect(matches[0].score > matches[1].score)
        #expect(!matches[0].isExact)
        #expect(matches.allSatisfy { $0.score >= TranslationMemory.fuzzyThreshold })
    }

    @Test func recordingTheSameSourceReplacesIt() {
        var memory = TranslationMemory()
        memory.record(source: "Hello", target: "مرحبا")
        memory.record(source: "hello", target: "أهلاً")
        #expect(memory.entries.count == 1)
        #expect(memory.exactMatch(for: "Hello")?.target == "أهلاً")
        memory.record(source: "", target: "x")
        memory.record(source: "Bye", target: "  ")
        #expect(memory.entries.count == 1)
    }

    @Test func storeRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TranslationStore(directory: directory)
        let pair = TranslationStore.pairKey(source: "en-US", target: "ar")
        #expect(pair == "en-ar")
        var memory = TranslationMemory()
        memory.record(source: "Hello", target: "مرحبا")
        try store.save(memory, pair: pair)
        try store.save(Glossary(entries: [.init(source: "Sam", target: "سام")]), pair: pair)
        #expect(store.memory(pair: pair).exactMatch(for: "hello")?.target == "مرحبا")
        #expect(store.glossary(pair: pair).entries.map(\.target) == ["سام"])
        #expect(store.memory(pair: "en-fr").entries.isEmpty)
    }
}

struct AlignmentTests {
    func time(_ seconds: Int64) -> MediaTime { MediaTime(value: seconds, timescale: 1) }

    @Test func templateCopiesTimingAndLinks() {
        let source = [Cue(start: time(1), end: time(2), text: "One"), Cue(start: time(3), end: time(4), text: "Sign", position: .top)]
        let template = Alignment.template(from: source)
        #expect(template.map(\.text) == ["", ""])
        #expect(template.map(\.sourceCueID) == source.map(\.id))
        #expect(template.map(\.position) == [.bottom, .top])
        #expect(template.map(\.start) == source.map(\.start))
    }

    @Test func unlinkedCuesPairByOverlap() {
        let source = [
            Cue(start: time(0), end: time(2), text: "A"),
            Cue(start: time(2), end: time(6), text: "B"),
            Cue(start: time(3), end: time(4), text: "Sign", position: .top),
        ]
        let target = [
            Cue(start: time(1), end: time(3), text: "a"),
            Cue(start: time(3), end: time(4), text: "b"),
            Cue(start: time(10), end: time(11), text: "none"),
        ]
        let pairs = Alignment.sourceCues(for: target, in: source)
        #expect(pairs[target[0].id]?.text == "A")
        // Equal overlap with B and the sign: the cue in the same position wins.
        #expect(pairs[target[1].id]?.text == "B")
        #expect(pairs[target[2].id] == nil)
        let linked = Alignment.link(target, to: source)
        #expect(linked.map(\.sourceCueID) == [source[0].id, source[1].id, nil])
    }
}

import EditorCommands
import Foundation
import PlaybackCore
import QualityControl
import SubtitleCore
import SubtitleFormats
import Testing
import SubtitleTranslation
@testable import EditorUI

@MainActor
struct TranslationStateTests {
    let rate = FrameRate.fps25
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "TranslationStateTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static let english = """
        1
        00:00:01,000 --> 00:00:02,000
        Welcome to Winterfell.

        2
        00:00:03,000 --> 00:00:04,000
        Where are you going?

        3
        00:00:05,000 --> 00:00:06,000
        Where are you going, John?

        """

    func write(_ text: String, name: String) throws -> URL {
        let url = directory.appending(path: name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func makeEditor(store: TranslationStore? = nil, settings: UserDefaults? = nil) -> EditorState {
        let options = LaunchOptions(isUITestMode: true, mediaURL: URL(fileURLWithPath: "/tmp/clip.mov"))
        let editor = EditorState(
            launchOptions: options, playback: SimulatedPlaybackEngine(frameRate: rate), settings: settings, translationStore: store
        )
        editor.reportError = { title, error in Issue.record("\(title) \(error)") }
        return editor
    }

    func translating(store: TranslationStore? = nil) throws -> EditorState {
        let editor = makeEditor(store: store)
        editor.openSourceSubtitles(from: try write(Self.english, name: "Pilot.en.srt"))
        return editor
    }

    @Test func openingASourceMakesAnEmptyLinkedTarget() throws {
        let editor = try translating()
        #expect(editor.isTranslating)
        #expect(editor.sourceTrack?.languageCode == "en")
        #expect(editor.track.languageCode == "ar")
        #expect(editor.targetDirection == .rightToLeft)
        #expect(editor.sourceDirection == .leftToRight)
        #expect(editor.track.cues.map(\.text) == ["", "", ""])
        #expect(editor.track.cues.map(\.start) == editor.sourceTrack?.cues.map(\.start))
        #expect(editor.track.cues.compactMap { editor.sourceCues[$0.id]?.text }.first == "Welcome to Winterfell.")
        // Undo removes the template; the source stays open.
        editor.perform(.undo)
        #expect(editor.track.cues.isEmpty)
        #expect(editor.isTranslating)
    }

    @Test func existingTargetIsPairedByTime() throws {
        let editor = makeEditor()
        let target = try write("1\n00:00:03,100 --> 00:00:04,000\nإلى أين أنت ذاهب؟\n", name: "Pilot.ar.srt")
        editor.importSubtitles(from: target)
        editor.openSourceSubtitles(from: try write(Self.english, name: "Pilot.en.srt"))
        #expect(editor.track.cues.count == 1)
        #expect(editor.sourceCues[editor.track.cues[0].id]?.text == "Where are you going?")
        // Detected from the Arabic text.
        #expect(editor.track.languageCode == "ar")
        editor.closeSourceSubtitles()
        #expect(!editor.isTranslating)
        #expect(editor.sourceCues.isEmpty)
    }

    @Test func untranslatedCuesAreFlaggedOnTheTarget() throws {
        let editor = try translating()
        let first = editor.track.cues[0].id
        #expect(editor.issues[first]?.map(\.message).contains("Not translated") == true)
        #expect(editor.issues[first]?.first?.severity == .error)
        editor.setText("مرحباً بك في وينترفيل.", forCue: first)
        #expect(editor.issues[first]?.contains { $0.kind == .notTranslated } != true)
    }

    @Test func glossaryTermsAreShownAndChecked() throws {
        let editor = try translating()
        let first = editor.track.cues[0].id
        editor.addGlossaryEntry(source: "Winterfell", target: "وينترفيل", note: "Castle")
        editor.setText("مرحباً بك في القلعة.", forCue: first)
        #expect(editor.glossaryMatches(for: first).map(\.isUsed) == [false])
        #expect(editor.issues[first]?.contains { $0.kind == .glossaryTermNotUsed(source: "Winterfell", target: "وينترفيل") } == true)
        editor.setText("مرحباً بك في وينترفيل.", forCue: first)
        #expect(editor.glossaryMatches(for: first).map(\.isUsed) == [true])
        #expect(glossaryIssues(editor, first).isEmpty)
        // Editing and removing terms re-checks the cues.
        var entry = editor.glossary.entries[0]
        entry.target = "فينترفيل"
        editor.updateGlossaryEntry(entry)
        #expect(glossaryIssues(editor, first) == ["Glossary: “Winterfell” is “فينترفيل”"])
        // A name spelled another common way is the same name.
        entry.target = "وينترفل"
        editor.updateGlossaryEntry(entry)
        #expect(glossaryIssues(editor, first).isEmpty)
        editor.removeGlossaryEntries([entry.id])
        #expect(glossaryIssues(editor, first).isEmpty)
    }

    static let knights = """
        1
        00:00:01,000 --> 00:00:02,000
        I wish you didn't die, ser.

        2
        00:00:03,000 --> 00:00:04,000
        No disrespect, ser.

        3
        00:00:05,000 --> 00:00:06,000
        Please, ser, let me in.

        4
        00:00:07,000 --> 00:00:08,000
        Dunk, my lord is here.

        """

    @Test func glossaryTermsHaveTheirOwnReviewWithAReplaceOption() throws {
        let editor = makeEditor()
        editor.openSourceSubtitles(from: try write(Self.knights, name: "Knights.en.srt"))
        editor.addGlossaryEntry(source: "Ser", target: "سير")
        editor.addGlossaryEntry(source: "Dunk", target: "دانك")
        let ids = editor.track.cues.map(\.id)
        for (id, text) in zip(ids, ["ليتك لم تمت يا سيدي", "مع كامل احترامي يا سيدي", "أرجوك يا سيدي، دعني أدخل", "يا دانق، سيدي هنا"]) {
            editor.setText(text, forCue: id)
        }
        // Its own filter, apart from the other issues.
        #expect(editor.reviewItems(in: .glossary).map(\.cueID) == ids)
        #expect(editor.reviewItems(in: .issues).allSatisfy { item in editor.cardIssues(item).allSatisfy { !$0.message.hasPrefix("Glossary") } })
        #expect(editor.canPerform(.reviewGlossary))
        #expect(editor.perform(.reviewGlossary))
        #expect(editor.reviewScope == .glossary)
        // The word the translation used wherever the source says "ser" is offered for the agreed one.
        let first = try #require(editor.reviewItems.first)
        #expect(editor.glossaryReplacement(forCue: first.cueID)?.title == "Replace “سيدي” with “سير”")
        // The card's button replaces and settles in one step, one undoable edit.
        editor.decide(first, .primary)
        #expect(editor.cue(withID: ids[0])?.text == "ليتك لم تمت يا سير")
        #expect(editor.reviewItems.map(\.cueID) == Array(ids.dropFirst()))
        #expect(editor.lastSettledReview?.outcome == "Replaced “سيدي” with “سير”")
        editor.perform(.undo)
        #expect(editor.cue(withID: ids[0])?.text == "ليتك لم تمت يا سيدي")
        // A spelling close to the agreed one is found by itself; "سيدي" there is "my lord", not the term.
        let last = try #require(editor.reviewItems.last)
        #expect(editor.glossaryReplacement(forCue: last.cueID)?.text == "يا دانك، سيدي هنا")
    }

    @Test func aGlossaryCardOffersReplaceAddAndIgnore() throws {
        let gods = """
            1
            00:00:01,000 --> 00:00:02,000
            The Seven gave you height.

            2
            00:00:03,000 --> 00:00:04,000
            Pray to the Seven.

            3
            00:00:05,000 --> 00:00:06,000
            I'll serve you at the tourney.

            """
        let editor = makeEditor()
        editor.openSourceSubtitles(from: try write(gods, name: "Gods.en.srt"))
        editor.addGlossaryEntry(source: "the Seven", target: "الآلهة السبعة")
        let ids = editor.track.cues.map(\.id)
        editor.setText("لقد وهبك السبعة في الأعالي طولًا", forCue: ids[0])
        editor.setText("صلِّ للسبعة", forCue: ids[1])
        // "السبعة" is one word of the agreed "الآلهة السبعة": it is what Replace swaps.
        #expect(editor.glossaryOptions(forCue: ids[0]).map(\.title) == [
            "Replace “السبعة” with “الآلهة السبعة”", "Add “السبعة” as a translation of “the Seven”", "Ignore “the Seven” in this line",
        ])
        #expect(editor.glossaryReplacement(forCue: ids[0])?.text == "لقد وهبك الآلهة السبعة في الأعالي طولًا")
        let card = try #require(editor.reviewItems(in: .glossary).first { $0.cueID == ids[0] })
        editor.decide(card, .primary)
        #expect(editor.cue(withID: ids[0])?.text == "لقد وهبك الآلهة السبعة في الأعالي طولًا")
        editor.perform(.undo)
        // Ignore: this line keeps its wording and loses the card; the other line still has one.
        editor.decide(card, .ignoreGlossaryTerms)
        #expect(editor.cue(withID: ids[0])?.acceptedGlossaryTerms == ["seven"])
        #expect(editor.reviewItems(in: .glossary).map(\.cueID) == [ids[1]])
        editor.perform(.undo)
        // Add: the word becomes another translation of the term, and every line using it is fine.
        editor.decide(card, .addGlossaryWord)
        #expect(editor.glossary.entries[0].alternatives == ["السبعة"])
        #expect(editor.reviewItems(in: .glossary).isEmpty, "للسبعة uses it too")
        // Saved and read back; glossaries saved before alternatives read as none.
        let data = try JSONEncoder().encode(editor.glossary)
        #expect(try JSONDecoder().decode(Glossary.self, from: data).entries[0].alternatives == ["السبعة"])
        // With no word standing out, Add and Replace take one picked from the line.
        editor.addGlossaryEntry(source: "tourney", target: "بطولة")
        let tourney = editor.track.cues[2].id
        editor.setText("سأخدمك خلال المبارزة", forCue: tourney)
        #expect(editor.glossaryReplacement(forCue: tourney) == nil)
        #expect(editor.glossaryWordChoices(forCue: tourney) == ["سأخدمك", "خلال", "المبارزة"])
        let joust = try #require(editor.reviewItems(in: .glossary).first { $0.cueID == tourney })
        editor.decide(joust, .replaceChosenGlossaryWord("المبارزة"))
        #expect(editor.cue(withID: tourney)?.text == "سأخدمك خلال بطولة")
        editor.perform(.undo)
        editor.decide(joust, .addChosenGlossaryWord("المبارزة"))
        #expect(editor.glossary.entries[1].alternatives == ["المبارزة"])
        #expect(editor.reviewItems(in: .glossary).isEmpty)
        let old = Data(#"{"entries": [{"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "source": "Ser", "target": "سير", "note": ""}]}"#.utf8)
        #expect(try JSONDecoder().decode(Glossary.self, from: old).entries[0].alternatives.isEmpty)
    }

    func glossaryIssues(_ editor: EditorState, _ id: Cue.ID) -> [String] {
        (editor.issues[id] ?? []).filter {
            if case .glossaryTermNotUsed = $0.kind { true } else { false }
        }.map(\.message)
    }

    @Test func importsAGlossary() throws {
        let editor = try translating()
        editor.chooseGlossaryToImport = { try? self.write("source\ttarget\nWinterfell\tوينترفيل\nJohn\tجون\n", name: "terms.tsv") }
        #expect(editor.perform(.importGlossary))
        #expect(editor.glossary.entries.map(\.source) == ["Winterfell", "John"])
        #expect(editor.glossaryMatches(for: editor.track.cues[2].id).map(\.entry.target) == ["جون"])
    }

    @Test func memoryLearnsFromLeftCuesAndSuggests() throws {
        let editor = try translating()
        let (second, third) = (editor.track.cues[1].id, editor.track.cues[2].id)
        editor.select(second)
        editor.setText("إلى أين أنت ذاهب؟", forCue: second)
        // Moving on stores the translation.
        editor.select(third)
        #expect(editor.memory.entries.count == 1)
        let matches = editor.memoryMatches(for: third)
        #expect(matches.count == 1)
        #expect(!matches[0].isExact)
        #expect(editor.canPerform(.useMemoryMatch))
        #expect(editor.perform(.useMemoryMatch))
        #expect(editor.track.cues[2].text == "إلى أين أنت ذاهب؟")
        editor.perform(.undo)
        #expect(editor.track.cues[2].text == "")
    }

    @Test func fillsExactMatchesInOneStep() throws {
        let editor = try translating()
        editor.memory.record(source: "where are you going?", target: "إلى أين؟")
        editor.memory.record(source: "Welcome to Winterfell.", target: "أهلاً")
        editor.setText("موجود", forCue: editor.track.cues[0].id)
        #expect(editor.perform(.fillExactMatches))
        // Only empty cues are filled, only from exact matches.
        #expect(editor.track.cues.map(\.text) == ["موجود", "إلى أين؟", ""])
        editor.perform(.undo)
        #expect(editor.track.cues.map(\.text) == ["موجود", "", ""])
    }

    @Test func copiesSourceToTarget() throws {
        let editor = try translating()
        editor.select(editor.track.cues[0].id)
        #expect(editor.perform(.copySourceToTarget))
        #expect(editor.track.cues[0].text == "Welcome to Winterfell.")
    }

    @Test func glossaryAndMemoryPersistPerLanguagePair() throws {
        let store = TranslationStore(directory: directory.appending(path: "store"))
        do {
            let editor = try translating(store: store)
            editor.addGlossaryEntry(source: "Winterfell", target: "وينترفيل")
            editor.setText("إلى أين أنت ذاهب؟", forCue: editor.track.cues[1].id)
            editor.perform(.addTranslationsToMemory)
        }
        let editor = try translating(store: store)
        #expect(editor.glossary.entries.map(\.target) == ["وينترفيل"])
        #expect(editor.memory.exactMatch(for: "Where are you going?")?.target == "إلى أين أنت ذاهب؟")
        // Another pair has its own.
        editor.setTargetLanguage("fr")
        #expect(editor.glossary.entries.isEmpty)
        #expect(editor.memory.entries.isEmpty)
        #expect(editor.targetDirection == .leftToRight)
    }

    @Test func exportSuggestsANameForTheTargetLanguageAndRemembers() throws {
        let editor = try translating()
        #expect(editor.suggestedTranslationFile?.url.lastPathComponent == "Pilot.ar.srt")
        editor.setText("أهلاً", forCue: editor.track.cues[0].id)
        let url = directory.appending(path: "out.stl")
        editor.exportSubtitles(to: SubtitleFileReference(url: url, format: .ebuSTL))
        #expect(editor.memory.entries.count == 1)
        let (format, track) = try SubtitleFile.read(from: url)
        #expect(format == .ebuSTL)
        #expect(track.languageCode == "ar")
        #expect(track.cues.first?.text == "أهلاً")
    }

    @Test func splitKeepsTheSourceLink() throws {
        let editor = try translating()
        let first = editor.track.cues[0]
        editor.select(first.id)
        #expect(editor.perform(.splitCue))
        #expect(editor.track.cues[1].sourceCueID == first.sourceCueID)
    }

    @Test func theWorkTitleComesFromTheFileNameWithoutReleaseTags() {
        #expect(EditorState.workTitle(fromFileName: "A Knight of the Seven Kingdoms (2026) S01E01 The Hedge Knight (1080p AMZN Webrip x265 10bit EAC3 5.1 Atmos - DNU)[TAoE]")
            == "A Knight of the Seven Kingdoms (2026) S01E01 The Hedge Knight")
        #expect(EditorState.workTitle(fromFileName: "Game.of.Thrones.S02E01.The.North.Remembers.2160p.TrueHD.Atmos.7.1.DV.HEVC.REMUX-FraMeSToR")
            == "Game of Thrones S02E01 The North Remembers")
        #expect(EditorState.workTitle(fromFileName: "[pseudo] Rick and Morty S01E01 Pilot [BDRip] [1080p] [h.265]") == "Rick and Morty S01E01 Pilot")
    }

    @Test func theGlossarysShowIsTheTitleWithoutTheEpisodeOrYear() {
        #expect(EditorState.showName(fromWorkTitle: "A Knight of the Seven Kingdoms (2026) S01E01 The Hedge Knight") == "A Knight of the Seven Kingdoms")
        #expect(EditorState.showName(fromWorkTitle: "Game of Thrones S02E01 The North Remembers") == "Game of Thrones")
        #expect(EditorState.showName(fromWorkTitle: "Rick and Morty 1x02 Lawnmower Dog") == "Rick and Morty")
        #expect(EditorState.showName(fromWorkTitle: "Dune (2021)") == "Dune")
    }

    @Test func namesTheTranslationSpelledGoToTheGlossary() throws {
        let editor = try translating()
        #expect(!editor.canPerform(.addNamesToGlossary))
        editor.edit("Cast") { track in
            track.cast = [CastMember(name: "Dunk", translatedName: "دانك"), CastMember(name: "Egg"), CastMember(name: "Winterfell", translatedName: "وينترفيل")]
        }
        editor.addGlossaryEntry(source: "Winterfell", target: "وينترفل")
        #expect(editor.namesMissingFromGlossary.map(\.name) == ["Dunk"])
        #expect(editor.perform(.addNamesToGlossary))
        #expect(editor.glossary.entries.map(\.target).sorted() == ["دانك", "وينترفل"])
        #expect(!editor.canPerform(.addNamesToGlossary))
    }

    @Test func translatorNotesAreSavedWithTheTrackAndUndoAsOneStep() throws {
        let editor = try translating()
        editor.setTranslatorNotes("Egg")
        editor.setTranslatorNotes("Egg is a boy.")
        #expect(editor.track.translatorNotes == "Egg is a boy.")
        let decoded = try JSONDecoder().decode(SubtitleTrack.self, from: JSONEncoder().encode(editor.track))
        #expect(decoded.translatorNotes == "Egg is a boy.")
        editor.perform(.undo)
        #expect(editor.track.translatorNotes == nil)
    }
}

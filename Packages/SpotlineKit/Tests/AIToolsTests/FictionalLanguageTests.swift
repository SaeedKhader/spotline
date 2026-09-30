import Foundation
import SubtitleCore
import Testing
@testable import AITools

struct FictionalLanguageTests {
    func request(on: Bool) -> TranslationRequest {
        TranslationRequest(
            lines: [
                .init(cueID: UUID(), source: "Zaldrīzes buzdari iksos daor.", start: .zero, end: MediaTime(value: 2, timescale: 1)),
                .init(cueID: UUID(), source: "Tell the khal we ride at dawn.", start: MediaTime(value: 3, timescale: 1), end: MediaTime(value: 4, timescale: 1)),
            ],
            sourceLanguage: "en", targetLanguage: "ar", leavesOutFictionalLanguages: on
        )
    }

    func rules(_ body: [String: Any]) -> String {
        ((body["system"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    @Test func madeUpLanguagesAreLeftOutByDefaultAndTheChoiceIsSaved() throws {
        let suite = "FictionalLanguageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AISettings.load(from: defaults).leavesOutFictionalLanguages)
        var settings = AISettings()
        settings.leavesOutFictionalLanguages = false
        settings.save(to: defaults)
        #expect(!AISettings.load(from: defaults).leavesOutFictionalLanguages)
    }

    @Test func translatorsAreAskedToMarkMadeUpLanguagesOnlyWhenTheyAreLeftOut() throws {
        func itemProperties(_ schema: [String: Any]) throws -> [String: Any] {
            let translations = try #require((schema["properties"] as? [String: Any])?["translations"] as? [String: Any])
            return try #require((translations["items"] as? [String: Any])?["properties"] as? [String: Any])
        }
        #expect(rules(ClaudeTranslator.body(for: request(on: true))).contains("made-up language"))
        #expect(try itemProperties(ClaudeTranslator.outputSchema(for: request(on: true)))["fictional_language"] != nil)
        #expect(!rules(ClaudeTranslator.body(for: request(on: false))).contains("made-up language"))
        #expect(try itemProperties(ClaudeTranslator.outputSchema(for: request(on: false)))["fictional_language"] == nil)
        // Luna gets the same rule, and the strict schema requires the field.
        let luna = OpenAITranslator.body(for: request(on: true))
        #expect((luna["instructions"] as? String)?.contains("made-up language") == true)
        let format = try #require((luna["text"] as? [String: Any])?["format"] as? [String: Any])
        let schema = try #require(format["schema"] as? [String: Any])
        let translations = try #require((schema["properties"] as? [String: Any])?["translations"] as? [String: Any])
        #expect(((translations["items"] as? [String: Any])?["required"] as? [String])?.contains("fictional_language") == true)
    }

    @Test func aLineMarkedAsAMadeUpLanguageComesBackEmptyAndLeftOut() throws {
        let output = """
            {"translations": [
              {"id": "L1", "text": "", "reasons": [], "confidence": 1, "note": "", "variants": [], "fictional_language": true},
              {"id": "L2", "text": "أخبر الخال أننا سننطلق فجرًا.", "reasons": [], "confidence": 1, "note": "", "variants": [], "fictional_language": false}],
             "cast": []}
            """
        let batch = try ClaudeTranslator.translations(from: CloudProviderTests.response(output), request: request(on: true))
        #expect(batch.translations.map(\.leftOut) == [.fictionalLanguage, nil])
        #expect(batch.translations[0].text.isEmpty && batch.translations[0].isAnswered)
        #expect(!batch.translations[0].isWalla)
        // A mark the user did not ask for is not followed: the line is left untranslated, to be asked again.
        let off = try ClaudeTranslator.translations(from: CloudProviderTests.response(output), request: request(on: false))
        #expect(off.translations.map(\.leftOut) == [nil, nil])
        #expect(!off.translations[0].isAnswered)
    }

    @Test func aSentenceInAMadeUpLanguageIsLeftOutInEveryCue() {
        let ids = [UUID(), UUID()]
        let group = SentenceSpans.Group(cueIDs: ids, sources: ["Zaldrīzes buzdari", "iksos daor."])
        let spread = SentenceSpans.spread([.fictionalLanguage(ids[0])], groups: [group]) { $0 }
        #expect(spread.map(\.cueID) == ids)
        #expect(spread.allSatisfy { $0.leftOut == .fictionalLanguage && $0.text.isEmpty })
    }

    @Test func aMadeUpLanguageChangesNoCueInTheProposal() {
        let cue = Cue(start: .zero, end: MediaTime(value: 1, timescale: 1), text: "")
        #expect(Proposals.translation(TranslationBatch(translations: [.fictionalLanguage(cue.id)]), cues: [cue]).isEmpty)
    }
}

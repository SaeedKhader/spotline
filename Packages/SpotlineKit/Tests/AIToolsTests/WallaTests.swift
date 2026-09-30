import Foundation
import MediaAnalysis
import QualityControl
import SubtitleCore
import Testing
@testable import AITools

struct WallaFilterTests {
    let rate = FrameRate.fps25

    /// Levels for `seconds` of audio: `floor` dBFS, with each stretch at its own level.
    func levels(_ seconds: Double, floor: Float = -140, _ stretches: [(Double, Double, Float)]) -> SpeechLevels {
        var levels = [Float](repeating: floor, count: Int(seconds / SpeechLevels.frameSeconds))
        for (start, end, level) in stretches {
            for frame in Int(start / SpeechLevels.frameSeconds)..<min(Int(end / SpeechLevels.frameSeconds), levels.count) { levels[frame] = level }
        }
        return SpeechLevels(levels: levels)
    }

    func word(_ text: String, _ start: Double, _ end: Double, _ speaker: String?) -> TranscribedWord {
        TranscribedWord(text: text, start: MediaTime(seconds: start, timescale: 1000), end: MediaTime(seconds: end, timescale: 1000), speaker: speaker)
    }

    /// Two people talk at -20 dBFS for a minute, each line three seconds apart.
    func dialogue(upTo seconds: Double = 60) -> (words: [TranscribedWord], stretches: [(Double, Double, Float)]) {
        var words: [TranscribedWord] = []
        var stretches: [(Double, Double, Float)] = []
        for (index, start) in stride(from: 0.0, to: seconds, by: 3).enumerated() {
            words.append(word("Line \(index).", start, start + 1, index.isMultiple(of: 2) ? "speaker_0" : "speaker_1"))
            stretches.append((start, start + 1, -20))
        }
        return (words, stretches)
    }

    @Test func voicesFarUnderTheDialogueGo() {
        var (words, stretches) = dialogue()
        // A crowd voice 25 dB under the dialogue, heard for longer than a brief voice.
        for start in stride(from: 1.2, to: 60, by: 6) {
            words.append(word("Get a load of him!", start, start + 1.5, "speaker_2"))
            stretches.append((start, start + 1.5, -45))
        }
        words.sort { $0.start < $1.start }
        let kept = WallaFilter(levels: levels(62, stretches)).words(words)
        #expect(!kept.contains { $0.speaker == "speaker_2" })
        #expect(kept.count == dialogue().words.count, "The dialogue stays")
    }

    @Test func aQuieterLineIsKeptUnlessFarUnder() {
        var (words, stretches) = dialogue()
        // A whisper 12 dB under the dialogue is dialogue.
        words.append(word("Quiet now.", 31.3, 32, "speaker_0"))
        stretches.append((31.3, 32, -32))
        words.sort { $0.start < $1.start }
        #expect(WallaFilter(levels: levels(62, stretches)).words(words).contains { $0.text == "Quiet now." })
    }

    @Test func aVoiceHeardOnlyBrieflyGoesSooner() {
        var (words, stretches) = dialogue()
        // 16 dB under: walla from a voice heard once, dialogue from someone who talks a lot.
        words.append(word("Move on!", 31.3, 32, "speaker_9"))
        words.append(word("Over here.", 40.3, 41, "speaker_0"))
        stretches += [(31.3, 32, -36), (40.3, 41, -36)]
        words.sort { $0.start < $1.start }
        let kept = WallaFilter(levels: levels(62, stretches)).words(words)
        #expect(!kept.contains { $0.text == "Move on!" })
        #expect(kept.contains { $0.text == "Over here." })
    }

    @Test func aLineWithLittleDialogueAroundIsKept() {
        let words = [word("Hello?", 0, 1, "speaker_0"), word("Anyone?", 100, 101, "speaker_1")]
        let levels = levels(102, [(0, 1, -20), (100, 101, -50)])
        #expect(WallaFilter(levels: levels).words(words).count == 2)
    }

    @Test func soundDescriptionsAreNotWalla() {
        var (words, stretches) = dialogue()
        words.append(word("(crowd cheering)", 31.3, 32, nil))
        stretches.append((31.3, 32, -60))
        words.sort { $0.start < $1.start }
        #expect(WallaFilter(levels: levels(62, stretches)).words(words).contains { $0.text == "(crowd cheering)" })
    }

    @Test func thePipelineLeavesWallaOutOfTheCues() {
        var (words, stretches) = dialogue(upTo: 12)
        words.append(word("Take my horse.", 7.5, 8.5, "speaker_2"))
        stretches.append((7.5, 8.5, -45))
        words.sort { $0.start < $1.start }
        let walla = WallaFilter(levels: levels(14, stretches))
        let plain = TranscriptionPipeline(preset: .netflix, frameRate: rate).cues(from: words)
        let filtered = TranscriptionPipeline(preset: .netflix, frameRate: rate, walla: walla).cues(from: words)
        #expect(plain.contains { $0.text.contains("Take my horse.") })
        #expect(!filtered.contains { $0.text.contains("Take my horse.") })
        #expect(filtered.map(\.text).joined(separator: " ").contains("Line 3."))
    }

    @Test func levelsFollowTheChunksOnTheMediaTimeline() {
        // A loud second at 2 s, a quiet one at 5 s, silence between.
        let loud = [Float](repeating: 0.5, count: PreparedAudio.sampleRate)
        let quiet = [Float](repeating: 0.005, count: PreparedAudio.sampleRate)
        let audio = PreparedAudio(
            source: .mix, audioStreamIndex: 0, duration: MediaTime(value: 8, timescale: 1),
            chunks: [AudioChunk(id: 0, start: MediaTime(value: 2, timescale: 1), samples: loud),
                     AudioChunk(id: 1, start: MediaTime(value: 5, timescale: 1), samples: quiet)]
        )
        let levels = SpeechLevels(audio)
        func at(_ start: Double, _ end: Double) -> Float {
            levels.loudest(from: MediaTime(seconds: start, timescale: 1000), to: MediaTime(seconds: end, timescale: 1000))
        }
        #expect(abs(at(2.2, 2.8) - -6) < 0.5)
        #expect(abs(at(5.2, 5.8) - -46) < 0.5)
        #expect(at(3.5, 4.5) < -100)
        #expect(at(0, 8) > -7, "The loudest moment")
        #expect(at(20, 21) < -100, "Past the end is silence")
    }

    @Test func wallaIsLeftOutByDefaultAndTheChoiceIsSaved() throws {
        let suite = "WallaTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AISettings.load(from: defaults).leavesOutWalla)
        var settings = AISettings()
        settings.leavesOutWalla = false
        settings.save(to: defaults)
        #expect(!AISettings.load(from: defaults).leavesOutWalla)
    }
}

struct WallaTranslationTests {
    func request(walla: Bool) -> TranslationRequest {
        TranslationRequest(
            lines: [
                .init(cueID: UUID(), source: "Get a load of this fella!", start: .zero, end: MediaTime(value: 2, timescale: 1)),
                .init(cueID: UUID(), source: "Ser Duncan the Tall.", start: MediaTime(value: 3, timescale: 1), end: MediaTime(value: 4, timescale: 1)),
            ],
            sourceLanguage: "en", targetLanguage: "ar", leavesOutWalla: walla
        )
    }

    func rules(_ body: [String: Any]) -> String {
        ((body["system"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    @Test func translatorsAreAskedToMarkWallaOnlyWhenItIsLeftOut() throws {
        func itemProperties(_ schema: [String: Any]) throws -> [String: Any] {
            let translations = try #require((schema["properties"] as? [String: Any])?["translations"] as? [String: Any])
            return try #require((translations["items"] as? [String: Any])?["properties"] as? [String: Any])
        }
        let on = ClaudeTranslator.body(for: request(walla: true))
        #expect(rules(on).contains("Walla is background crowd chatter"))
        #expect(try itemProperties(ClaudeTranslator.outputSchema(for: request(walla: true)))["walla"] != nil)
        let off = ClaudeTranslator.body(for: request(walla: false))
        #expect(!rules(off).contains("Walla"))
        #expect(try itemProperties(ClaudeTranslator.outputSchema(for: request(walla: false)))["walla"] == nil)
        // Luna gets the same rule, and the strict schema requires the field.
        let luna = OpenAITranslator.body(for: request(walla: true))
        #expect((luna["instructions"] as? String)?.contains("Walla is background crowd chatter") == true)
        let format = try #require((luna["text"] as? [String: Any])?["format"] as? [String: Any])
        let schema = try #require(format["schema"] as? [String: Any])
        let translations = try #require((schema["properties"] as? [String: Any])?["translations"] as? [String: Any])
        #expect(((translations["items"] as? [String: Any])?["required"] as? [String])?.contains("walla") == true)
    }

    @Test func aLineMarkedWallaComesBackEmptyAndMarked() throws {
        let output = """
            {"translations": [
              {"id": "L1", "text": "", "reasons": [], "confidence": 1, "note": "", "variants": [], "walla": true},
              {"id": "L2", "text": "السير دنكن الطويل", "reasons": [], "confidence": 1, "note": "", "variants": [], "walla": false}],
             "cast": []}
            """
        let request = request(walla: true)
        let batch = try ClaudeTranslator.translations(from: CloudProviderTests.response(output), request: request)
        #expect(batch.translations.map(\.isWalla) == [true, false])
        #expect(batch.translations[0].text.isEmpty && batch.translations[0].isAnswered)
        #expect(batch.translations[1].text == "السير دنكن الطويل")
        // A mark the user did not ask for is not followed: the line is left untranslated, to be asked again.
        let off = try ClaudeTranslator.translations(from: CloudProviderTests.response(output), request: self.request(walla: false))
        #expect(off.translations.map(\.isWalla) == [false, false])
        #expect(!off.translations[0].isAnswered)
    }

    @Test func aSentenceOfWallaIsWallaInEveryCue() {
        let ids = [UUID(), UUID()]
        let group = SentenceSpans.Group(cueIDs: ids, sources: ["He's walking", "down the hill!"])
        let spread = SentenceSpans.spread([.walla(ids[0])], groups: [group]) { $0 }
        #expect(spread.map(\.cueID) == ids)
        #expect(spread.allSatisfy { $0.isWalla && $0.text.isEmpty })
    }

    @Test func wallaChangesNoCueInTheProposal() {
        let cue = Cue(start: .zero, end: MediaTime(value: 1, timescale: 1), text: "")
        let proposal = Proposals.translation(TranslationBatch(translations: [.walla(cue.id)]), cues: [cue])
        #expect(proposal.isEmpty)
    }
}

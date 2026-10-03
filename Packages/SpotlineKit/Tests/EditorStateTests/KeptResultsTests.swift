import EditorCommands
import Foundation
import PlaybackCore
import QualityControl
import SubtitleCore
import SubtitleTranslation
import Testing
@testable import EditorUI

/// What the editor keeps between edits to stay fast (each cue's checks, where each cue is,
/// the source pairing, the review lists) must always be what working it all out again gives.
@MainActor
struct KeptResultsTests {
    let rate = FrameRate.fps25
    func f(_ n: Int64) -> MediaTime { MediaTime(frame: n, rate: rate) }

    func makeEditor(_ track: SubtitleTrack = SubtitleTrack()) -> EditorState {
        let editor = EditorState(
            launchOptions: LaunchOptions(isUITestMode: true), playback: SimulatedPlaybackEngine(frameRate: rate),
            frameRate: rate, track: track
        )
        editor.reportError = { _, _ in }
        return editor
    }

    /// A translation of eight lines with a glossary, some lines breaking QC rules.
    func translating() -> EditorState {
        let lines = [
            "Welcome to Winterfell.", "Where are you going?", "Where are you going, John?", "I wish you didn't die, ser.",
            "No disrespect, ser.", "Please, ser, let me in.", "Dunk, my lord is here.", "Winterfell is far, John.",
        ]
        let source = lines.enumerated().map { index, text in
            Cue(start: f(Int64(index) * 60), end: f(Int64(index) * 60 + 40), text: text)
        }
        var target = Alignment.template(from: source)
        let translations = ["مرحباً بك في وينترفيل.", "", "إلى أين تذهب يا جون؟", "ليتك لم تمت يا سيدي.", "", "أرجوك دعني أدخل.", "دانك، مولاي هنا.", "القلعة بعيدة."]
        for index in target.indices { target[index].text = translations[index] }
        target[2].unsureWords = ["جون"]
        target[5].flag = TranslationFlag(reasons: [.listener], variants: [
            TranslationVariant(text: "أرجوك دعني أدخل.", listenerGender: .male, listenerCount: .one),
            TranslationVariant(text: "أرجوكِ دعيني أدخل.", listenerGender: .female, listenerCount: .one),
        ], confidence: 0.6, note: "")
        let editor = makeEditor(SubtitleTrack(languageCode: "ar", cues: target))
        editor.sourceTrack = SubtitleTrack(languageCode: "en", cues: source)
        editor.glossary = Glossary(entries: [
            Glossary.Entry(source: "Winterfell", target: "وينترفيل"), Glossary.Entry(source: "ser", target: "سير"),
            Glossary.Entry(source: "John", target: "جون"),
        ])
        return editor
    }

    /// An editor given the same cues, source, glossary and preset all at once: nothing kept from before.
    func fresh(like editor: EditorState) -> EditorState {
        let other = makeEditor(editor.track)
        other.selectQCPreset(id: editor.qcPreset.id)
        other.sourceTrack = editor.sourceTrack
        other.glossary = editor.glossary
        return other
    }

    func expectSameAsFresh(_ editor: EditorState, _ log: [String]) {
        let other = fresh(like: editor)
        let trail = log.joined(separator: "\n")
        #expect(editor.issues == other.issues, "issues after:\n\(trail)")
        #expect(editor.sourceCues == other.sourceCues, "source pairing after:\n\(trail)")
        for scope in ReviewScope.allCases {
            #expect(editor.reviewItems(in: scope) == other.reviewItems(in: scope), "\(scope) cards after:\n\(trail)")
        }
        #expect(editor.attentionCueIDs == other.attentionCueIDs, "cues to check after:\n\(trail)")
        #expect(editor.suggestionCueIDs == other.suggestionCueIDs, "cues to decide after:\n\(trail)")
        for (index, cue) in editor.track.cues.enumerated() {
            #expect(editor.cue(withID: cue.id) == cue, "cue \(index + 1) after:\n\(trail)")
            #expect(editor.index(ofCue: cue.id) == index, "index of cue \(index + 1) after:\n\(trail)")
            #expect(editor.glossaryMatches(for: cue.id) == other.glossaryMatches(for: cue.id), "glossary of cue \(index + 1) after:\n\(trail)")
            #expect(editor.glossaryReplacement(forCue: cue.id)?.text == other.glossaryReplacement(forCue: cue.id)?.text, "replacement in cue \(index + 1) after:\n\(trail)")
        }
        #expect(editor.cue(withID: UUID()) == nil)
    }

    @Test(arguments: 0..<60)
    func everyEditLeavesWhatAFreshStartWouldWorkOut(seed: Int) {
        var generator = SeededGenerator(seed: UInt64(seed + 1))
        let editor = translating()
        var log: [String] = []
        expectSameAsFresh(editor, log)
        let texts = ["", "وينترفيل", "يا سير", "القلعة يا سيدي", "سطر طويل جداً جداً جداً لا يتسع في سطر واحد من الترجمة أبداً", "جون\nوينترفيل\nسير", "<i></i>", "دانك"]
        for _ in 0..<20 {
            let cues = editor.track.cues
            guard let cue = cues.randomElement(using: &generator) else { break }
            // The cards are asked for between edits, as the sidebar does, so what is kept is in use.
            _ = editor.reviewCards
            switch Int.random(in: 0..<13, using: &generator) {
            case 0...3:
                let text = texts.randomElement(using: &generator)!
                log.append("type “\(text)” in \(cue.start.seconds)")
                editor.setText(text, forCue: cue.id)
            case 4:
                let shift = f(Int64.random(in: -30...30, using: &generator))
                log.append("move \(cue.start.seconds) by \(shift.seconds)")
                editor.setTiming(start: cue.start + shift, end: cue.end + shift, forCue: cue.id, actionName: "Move")
            case 5:
                let longer = f(Int64.random(in: 1...40, using: &generator))
                log.append("extend \(cue.start.seconds) by \(longer.seconds)")
                editor.setTiming(start: cue.start, end: cue.end + longer, forCue: cue.id, actionName: "Extend")
            case 6:
                log.append("delete \(cue.start.seconds)")
                editor.deleteCue(cue.id)
            case 7:
                log.append("add after \(cue.start.seconds)")
                editor.addCue(after: cue.id)
            case 8:
                log.append("split \(cue.start.seconds)")
                _ = editor.splitCue(cue.id, at: nil)
            case 9:
                log.append("merge \(cue.start.seconds)")
                editor.mergeWithNext(cue.id)
            case 10:
                log.append("undo")
                editor.perform(.undo)
            case 11:
                log.append("top \(cue.start.seconds)")
                editor.setPosition(cue.position == .top ? .bottom : .top, forCue: cue.id)
            default:
                if Bool.random(using: &generator), let entry = editor.glossary.entries.randomElement(using: &generator) {
                    log.append("remove term \(entry.source)")
                    editor.removeGlossaryEntries([entry.id])
                } else {
                    log.append("add term Dunk")
                    editor.addGlossaryEntry(source: "Dunk", target: "دانك")
                }
            }
            expectSameAsFresh(editor, log)
        }
    }

    @Test func eachFilterListsItsKindOfEverything() {
        let editor = translating()
        let all = editor.reviewItems(in: .all)
        #expect(!all.isEmpty)
        for scope in ReviewScope.allCases where scope != .all {
            #expect(Set(editor.reviewItems(in: scope)) == Set(all.filter { $0.kind.scope == scope }), "\(scope)")
        }
        #expect(ReviewScope.allCases.filter { $0 != .all }.reduce(0) { $0 + editor.reviewCount(in: $1) } == all.count)
    }

    @Test func changingThePresetOrTheShotChangesChecksEveryCueAgain() {
        let editor = makeEditor(SubtitleTrack(cues: [
            Cue(start: f(0), end: f(10), text: "Short"), Cue(start: f(11), end: f(60), text: "Next"),
        ]))
        let standard = editor.issues
        editor.selectQCPreset(id: QCPreset.all.first { $0.id != editor.qcPreset.id }!.id)
        #expect(editor.issues == fresh(like: editor).issues)
        editor.selectQCPreset(id: QCPreset.standard.id)
        #expect(editor.issues == standard)
    }

    @Test func leavingACueWhoseTranslationIsKnownKeepsTheSuggestions() {
        let editor = translating()
        let cues = editor.track.cues
        // Leaving each cue the first time records its translation.
        editor.select(cues[0].id)
        editor.select(cues[2].id)
        editor.select(cues[0].id)
        _ = editor.memoryMatches(for: cues[0].id)
        #expect(!editor.memoryMatchCache.isEmpty)
        // Leaving them again records nothing new, so nothing is worked out again.
        editor.select(cues[2].id)
        editor.select(cues[0].id)
        #expect(!editor.memoryMatchCache.isEmpty)
        editor.select(cues[2].id)
        // A new translation is recorded, and the suggestions are worked out from it again.
        editor.setText("إلى أين أنت ذاهب يا جون؟", forCue: cues[2].id)
        editor.select(cues[0].id)
        #expect(editor.memory.exactMatch(for: "Where are you going, John?")?.target == "إلى أين أنت ذاهب يا جون؟")
        #expect(editor.memoryMatchCache.isEmpty)
    }

    @Test func aSavedProjectEncodesItsSourceOnlyWhenItChanges() throws {
        let editor = translating()
        let cache = ProjectFile.EncodingCache()
        let first = try editor.projectFile(savingTo: nil).fileWrapper(cache: cache)
        editor.setText("مرحباً", forCue: editor.track.cues[0].id)
        let second = try editor.projectFile(savingTo: nil).fileWrapper(cache: cache)
        let name = "source.json"
        #expect(first.fileWrappers?[name]?.regularFileContents == second.fileWrappers?[name]?.regularFileContents)
        #expect(first.fileWrappers?["subtitles.json"]?.regularFileContents != second.fileWrappers?["subtitles.json"]?.regularFileContents)
        // Another source is written, not the one kept.
        var source = try #require(editor.sourceTrack)
        source.cues[0].text = "Welcome."
        editor.sourceTrack = source
        let third = try editor.projectFile(savingTo: nil).fileWrapper(cache: cache)
        let saved = try ProjectFile(fileWrapper: third)
        #expect(saved.sourceTrack == source)
    }
}

@MainActor
struct CuesAtPlayheadTests {
    let rate = FrameRate.fps25
    func f(_ n: Int64) -> MediaTime { MediaTime(frame: n, rate: rate) }

    @Test func theCuesOnScreenAreFoundAmongOverlappingAndLongCues() {
        var sign = Cue(start: f(0), end: f(500), text: "A long sign", position: .top)
        sign.style = nil
        let cues = [
            sign, Cue(start: f(10), end: f(40), text: "One"), Cue(start: f(50), end: f(90), text: "Two"),
            Cue(start: f(80), end: f(120), text: "Overlaps two"), Cue(start: f(300), end: f(320), text: "Late"),
        ]
        let playback = SimulatedPlaybackEngine(frameRate: rate, frameCount: 1_000)
        let editor = EditorState(
            launchOptions: LaunchOptions(isUITestMode: true), playback: playback, frameRate: rate, track: SubtitleTrack(cues: cues)
        )
        playback.load(URL(fileURLWithPath: "/tmp/clip.mov"))
        for frame: Int64 in [0, 5, 10, 39, 40, 45, 50, 85, 89, 90, 119, 120, 200, 300, 319, 320, 499, 500, 600] {
            editor.seek(toFrame: frame)
            let time = f(frame)
            // What looking at every cue gives.
            let showing = cues.filter { $0.start <= time && time < $0.end }
            #expect(editor.cueAtPlayhead?.id == showing.last?.id, "frame \(frame)")
            #expect(editor.currentCueID == showing.last?.id, "frame \(frame)")
            let expected = CuePosition.allCases.compactMap { position in showing.last { $0.position == position } }
            #expect(editor.cuesAtPlayhead == expected, "frame \(frame)")
        }
        // Editing the cue on screen shows at once.
        editor.seek(toFrame: 60)
        editor.setText("Two!", forCue: cues[2].id)
        #expect(editor.cuesAtPlayhead.map(\.text) == ["Two!", "A long sign"])
    }
}

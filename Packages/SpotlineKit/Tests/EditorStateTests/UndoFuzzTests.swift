import AITools
import EditorCommands
import Foundation
import PlaybackCore
import SubtitleCore
import Testing
@testable import EditorUI

@MainActor
struct UndoFuzzTests {
    let rate = FrameRate.fps25
    func f(_ n: Int64) -> MediaTime { MediaTime(frame: n, rate: rate) }

    @Test(arguments: 0..<100)
    func undoingEverythingGetsBackTheStart(seed: Int) {
        var generator = SeededGenerator(seed: UInt64(seed + 1))
        var unsure = Cue(start: f(300), end: f(360), text: "Hello Duncan my friend")
        unsure.unsureWords = ["Duncan", "friend"]
        var flagged = Cue(start: f(400), end: f(460), text: "انت مستعد؟")
        flagged.flag = TranslationFlag(reasons: [.listener], variants: [
            TranslationVariant(text: "انت مستعد؟", listenerGender: .male, listenerCount: .one),
            TranslationVariant(text: "انتِ مستعدة؟", listenerGender: .female, listenerCount: .one),
        ], confidence: 0.6, note: "")
        let cues = [
            Cue(start: f(0), end: f(10), text: "This subtitle line is much too long to fit on one line"),
            Cue(start: f(12), end: f(60), text: ""),
            Cue(start: f(100), end: f(110), text: "Short"),
            Cue(start: f(150), end: f(170), text: "This line has exactly forty characters.."),
            unsure, flagged,
        ]
        let editor = EditorState(
            launchOptions: LaunchOptions(isUITestMode: true), playback: SimulatedPlaybackEngine(frameRate: rate),
            frameRate: rate, track: SubtitleTrack(cues: cues)
        )
        editor.reportError = { _, _ in }
        let start = editor.track
        var log: [String] = []
        for _ in 0..<25 {
            let cards = editor.reviewCards
            switch Int.random(in: 0..<10, using: &generator) {
            case 0...3:
                guard let card = cards.randomElement(using: &generator) else { continue }
                let options = editor.reviewSuggestions(for: card)
                if case .issues = card.kind, !options.isEmpty {
                    let pick = Int.random(in: 0..<options.count, using: &generator)
                    log.append("try \(pick) of \(options.map(\.title)) on \(card.id.suffix(10))")
                    editor.decide(card, .suggestion(pick))
                } else if case .choice = card.kind {
                    log.append("variant on \(card.id.suffix(10))")
                    editor.decide(card, .variant(Int.random(in: 0..<2, using: &generator)))
                }
            case 4...5:
                guard let card = cards.randomElement(using: &generator) else { continue }
                log.append("confirm \(card.id.suffix(12))")
                editor.decide(card, .primary)
            case 6:
                guard let cue = editor.track.cues.randomElement(using: &generator) else { continue }
                log.append("type in \(cue.text.prefix(8))")
                editor.setText(cue.text + " x", forCue: cue.id)
            case 7:
                log.append("undo note")
                editor.undoLastReviewDecision()
            case 8:
                log.append("undo")
                editor.perform(.undo)
            default:
                log.append("redo")
                editor.perform(.redo)
            }
        }
        let end = editor.track
        if editor.canUndo {
            editor.perform(.undo)
            editor.perform(.redo)
            #expect(editor.track.cues == end.cues, "undo, redo: \(log.joined(separator: "\n"))")
        }
        while editor.canUndo { editor.perform(.undo) }
        #expect(editor.track.cues == start.cues, "\(log.joined(separator: "\n"))")

    }
}

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

import AITools
import EditorCommands
import Foundation
import MediaAnalysis
import PlaybackCore
import SubtitleCore
import Testing
@testable import EditorUI

/// What the AI bar says while a tool runs, and after.
@MainActor
struct AIProgressTests {
    let start = Date(timeIntervalSinceReferenceDate: 0)

    func makeEditor(cues: [Cue] = []) -> EditorState {
        let editor = EditorState(
            launchOptions: LaunchOptions(isUITestMode: true), playback: SimulatedPlaybackEngine(frameRate: .fps25, frameCount: 250),
            track: SubtitleTrack(cues: cues)
        )
        editor.open(URL(fileURLWithPath: "/tmp/clip.mov"))
        editor.prepareAudio = { _, _, progress in
            progress(1)
            return PreparedAudio(source: .mix, audioStreamIndex: 0, duration: MediaTime(value: 10, timescale: 1), chunks: [])
        }
        editor.reportError = { title, error in Issue.record("\(title) \(error)") }
        editor.aiSettings.joinsLinesAfterTranslating = false
        editor.aiSettings.translationStyle.dropsFinalPunctuation = false
        return editor
    }

    func cue(_ text: String, at second: Int64) -> Cue {
        Cue(start: MediaTime(value: second, timescale: 1), end: MediaTime(value: second + 1, timescale: 1), text: text)
    }

    func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<300 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    // MARK: The status

    @Test func anUploadIsItsOwnStageThenTheWaitIsTimedNotGuessed() {
        var task = AITaskStatus(
            title: "Transcription", provider: "ElevenLabs Scribe (cloud)",
            stages: ["Preparing audio", "Compressing audio", "Uploading", "Transcribing"]
        )
        #expect(task.provider == "ElevenLabs Scribe")
        #expect(task.detail == "Preparing audio")
        // Compressing is its own stage, measured from empty.
        task.update(with: .encoding(0), now: start)
        #expect(task.stage == 1 && task.detail == "Compressing audio · 0%" && task.fraction == 0)
        task.update(with: .encoding(0.4), now: start)
        #expect(task.detail == "Compressing audio · 40%" && task.fraction == 0.4)
        task.update(with: .uploading(sent: 6_100_000, total: 18_000_000), now: start)
        #expect(task.stage == 2)
        #expect(task.detail == "Uploading 6.1 of 18 MB · 34%")
        #expect(abs((task.fraction ?? 0) - 6.1 / 18) < 0.001)
        task.update(with: .waiting, now: start)
        #expect(task.stage == 3 && task.detail == "ElevenLabs Scribe is transcribing")
        #expect(task.fraction == nil, "Nothing measures the provider's work: no percentage")
        #expect(task.waitingSince == start)
        task.update(with: .waiting, now: start.addingTimeInterval(30))
        #expect(task.waitingSince == start, "The wait is timed from when it began")
        #expect(task.step == "Step 4 of 4")
        #expect(task.fraction(at: start.addingTimeInterval(30)) == nil, "The first time, nothing says how long it takes")
        #expect(task.waited(at: start.addingTimeInterval(9)) == "0:09")
        // Once timed before, the wait is measured against how long it usually takes, never shown full.
        task.usualWait = 80
        #expect(task.fraction(at: start.addingTimeInterval(40)) == 0.5)
        #expect(task.waited(at: start.addingTimeInterval(9)) == "0:09 of about 1:20")
        #expect(task.fraction(at: start.addingTimeInterval(79)) == nil)
        #expect(task.waited(at: start.addingTimeInterval(95)) == "1:35, longer than usual")
        task.usualWait = nil
        #expect(AITaskStatus.elapsed(since: start, now: start.addingTimeInterval(72)) == "1:12")
        #expect(AITaskStatus.elapsed(since: start, now: start.addingTimeInterval(3725)) == "1:02:05")
        #expect(task.overallFraction == 0.75)
        task.enter("Uploading")
        #expect(task.stage == 2 && task.waitingSince == nil)
    }

    @Test func partsAndOnDeviceWorkAreCounted() {
        var task = AITaskStatus(title: "Transcription", provider: "OpenAI Whisper (cloud)", stages: ["Preparing audio", "Transcribing"])
        task.update(with: .parts(done: 3, total: 12), now: start)
        #expect(task.stage == 1 && task.detail == "OpenAI Whisper · 3 of 12 parts" && task.fraction == 0.25)
        var local = AITaskStatus(title: "Transcription", provider: "Apple Speech (on this Mac)", stages: ["Preparing audio", "Transcribing"])
        local.update(with: .fraction(0.4), now: start)
        #expect(local.detail == "Apple Speech · 40%")
    }

    @Test func timeLeftWaitsForTwoBatches() {
        let ids = (0..<50).map { _ in UUID() }
        var task = AITaskStatus(title: "Translation", provider: "Claude (cloud)", stages: ["Translating"])
        task.update(with: .lines(done: 0, total: 650, inFlight: Array(ids.prefix(10))), now: start)
        #expect(task.detail == "Claude · 0 of 650 lines")
        #expect(task.inFlight == Set(ids.prefix(10)))
        // The first batch is small and pays for reading the script: no estimate from it.
        task.update(with: .lines(done: 10, total: 650, inFlight: ids), now: start.addingTimeInterval(20))
        #expect(task.estimatedEnd == nil)
        // 40 lines in 30 seconds: 600 more take 450.
        task.update(with: .lines(done: 50, total: 650, inFlight: []), now: start.addingTimeInterval(50))
        #expect(task.estimatedEnd == start.addingTimeInterval(50 + 450))
        let now = start.addingTimeInterval(50)
        #expect(AITaskStatus.timeLeft(until: task.estimatedEnd!, now: now) == "about 8 min left")
        #expect(AITaskStatus.timeLeft(until: now.addingTimeInterval(40), now: now) == "under a minute left")
        #expect(AITaskStatus.timeLeft(until: now, now: now) == nil)

        task.update(with: .retrying(inFlight: [ids[0], ids[1], ids[2]]), now: now)
        #expect(task.detail == "Claude · retrying 3 declined lines")
        #expect(task.inFlight.count == 3)
    }

    // MARK: In the editor

    @Test func transcriptionGoesThroughItsStages() async {
        let editor = makeEditor()
        let release = AsyncStream<Void>.makeStream()
        editor.aiProviders = AIProviderFactory(
            transcriber: { _ in UploadingTranscriber(words: ScriptedTranscriber.fixture.words, gate: release.stream) },
            translator: { _ in ScriptedTranslator() }
        )
        var seen: [AITaskStatus?] = []
        editor.onAITaskChange = { seen.append($0) }
        #expect(editor.perform(.transcribe))
        #expect(editor.aiTask?.stages == ["Preparing audio", "Compressing audio", "Uploading", "Transcribing"])
        await waitUntil { editor.aiTask?.waitingSince != nil }
        #expect(editor.aiTask?.detail == "Uploading is transcribing")
        #expect(editor.aiTask?.stage == 3)
        #expect(seen.contains { $0?.detail == "Compressing audio · 50%" })
        #expect(seen.contains { $0?.detail == "Uploading 1.0 of 2.0 MB · 50%" }, "The app hears each step, for the Dock")
        release.continuation.yield()
        await waitUntil { editor.aiTask == nil }
        #expect(seen.last == .some(nil))
        #expect(editor.aiSummary?.text == "2 cues transcribed")
        #expect(editor.aiSummary?.followUp == nil)
    }

    @Test func theWaitIsTimedForNextTime() async {
        let editor = makeEditor()
        let release = AsyncStream<Void>.makeStream()
        editor.aiProviders = AIProviderFactory(
            transcriber: { _ in UploadingTranscriber(words: ScriptedTranscriber.fixture.words, gate: release.stream) },
            translator: { _ in ScriptedTranslator() }
        )
        editor.aiSettings.transcription = .elevenLabsScribe
        editor.perform(.transcribe)
        await waitUntil { editor.aiTask?.waitingSince != nil }
        #expect(editor.aiTask?.usualWait == nil)
        try? await Task.sleep(for: .milliseconds(100))
        release.continuation.yield()
        await waitUntil { editor.aiTask == nil }
        // 10 seconds of audio: the wait per second of audio is kept by provider.
        let rate = try! #require(editor.waitRates[AISettings.TranscriptionProvider.elevenLabsScribe.rawValue])
        // A 0.1 s wait at least; the upper bound only rules out nonsense (a busy CI runner can be slow).
        #expect(rate > 0.005 && rate < 1)
        // A new run of the same audio (the stored words are cleared) expects about as long.
        editor.storedTranscripts = []
        editor.perform(.transcribe)
        await waitUntil { editor.aiTask?.usualWait != nil }
        #expect(abs((editor.aiTask?.usualWait ?? 0) - rate * 10) < 0.001)
        editor.perform(.cancelAITask)
    }

    @Test func aSavedTranscriptIsSaidToBeUsed() async {
        let editor = makeEditor()
        editor.perform(.transcribe)
        await waitUntil { editor.aiTask == nil }
        #expect(editor.perform(.transcribe))
        // The audio is read again (from the cache) to tell crowd chatter from dialogue.
        #expect(editor.aiTask?.stages == ["Preparing audio", "Transcribing"])
        #expect(editor.aiTask?.detail == "Using the saved transcript")
        editor.perform(.cancelAITask)

        editor.aiSettings.leavesOutWalla = false
        #expect(editor.perform(.transcribe))
        #expect(editor.aiTask?.stages == ["Transcribing"])
    }

    @Test func translationSaysWhatItFlagged() async {
        let editor = makeEditor(cues: [cue("Where are you going?", at: 1), cue("Home.", at: 3)])
        var ended: [AITaskEnd] = []
        editor.onAITaskEnd = { ended.append($0) }
        #expect(editor.perform(.translateWithAI))
        #expect(editor.aiTask?.detail == "Scripted translator · 0 of 2 lines")
        await waitUntil { editor.aiTask == nil }
        #expect(editor.aiSummary?.text == "2 lines translated")
        #expect(editor.aiSummary?.fullText == "2 lines translated · 1 flagged")
        #expect(ended == [AITaskEnd(title: "Translation finished", message: "2 lines translated · 1 flagged", succeeded: true)])
    }

    @Test func linesInFlightAreKnownWhileTheyAreTranslated() async {
        let editor = makeEditor(cues: [cue("One.", at: 1), cue("Two.", at: 3)])
        let release = AsyncStream<Void>.makeStream()
        editor.aiProviders = AIProviderFactory(
            transcriber: { _ in ScriptedTranscriber.fixture }, translator: { _ in GatedTranslator(gate: release.stream) }
        )
        editor.perform(.translateWithAI)
        await waitUntil { editor.aiTask?.inFlight.isEmpty == false }
        #expect(editor.aiTask?.inFlight == Set(editor.track.cues.prefix(1).map(\.id)))
        #expect(editor.aiTask?.detail == "Gated · 0 of 2 lines")
        release.continuation.yield()
        await waitUntil { editor.aiTask == nil }
        #expect(editor.track.cues.map(\.text) == ["[ar] One.", "[ar] Two."])
    }

    @Test func theSummaryGoesAwayAndIsReplacedByTheNextTool() async {
        let editor = makeEditor()
        editor.aiSummaryDuration = .milliseconds(50)
        editor.perform(.transcribe)
        await waitUntil { editor.aiTask == nil }
        #expect(editor.aiSummary != nil)
        await waitUntil { editor.aiSummary == nil }
        #expect(editor.aiSummary == nil)
    }
}

/// Uploads 2 MB in two steps, then waits for `gate` as a provider working on the whole file would.
private struct UploadingTranscriber: Transcriber {
    var name: String { "Uploading (cloud)" }
    var uploadsInOnePiece: Bool { true }
    let words: [TranscribedWord]
    let gate: AsyncStream<Void>

    func transcribe(
        _ audio: PreparedAudio, language: String?, progress: @escaping @Sendable (AIProgress) -> Void,
        found: @escaping @Sendable ([TranscribedWord]) -> Void
    ) async throws -> [TranscribedWord] {
        progress(.encoding(0))
        progress(.encoding(0.5))
        progress(.encoding(1))
        progress(.uploading(sent: 1_000_000, total: 2_000_000))
        progress(.waiting)
        for await _ in gate { break }
        try Task.checkCancellation()
        found(words)
        return words
    }
}

/// Translates the first line, then waits for `gate` before the second.
private struct GatedTranslator: CueTranslator {
    var name: String { "Gated (cloud)" }
    let gate: AsyncStream<Void>

    func translate(
        _ request: TranslationRequest, progress: @escaping @Sendable (AIProgress) -> Void,
        found: @escaping @Sendable (TranslationBatch) -> Void
    ) async throws -> TranslationBatch {
        let all = request.lines.map { CueTranslation(cueID: $0.cueID, text: "[ar] " + $0.source) }
        progress(.lines(done: 0, total: all.count, inFlight: [all[0].cueID]))
        for await _ in gate { break }
        found(TranslationBatch(translations: all))
        progress(.lines(done: all.count, total: all.count, inFlight: []))
        return TranslationBatch(translations: all)
    }
}

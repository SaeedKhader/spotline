import EditorCommands
import Foundation
import PlaybackCore
import SubtitleCore
import SubtitleFormats
import Testing
@testable import EditorUI

@MainActor
struct EditingTests {
    let rate = FrameRate.fps23_976
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "EditingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func makeEditor(subtitles: String? = nil) throws -> EditorState {
        var options = LaunchOptions(isUITestMode: true, mediaURL: URL(fileURLWithPath: "/tmp/clip.mov"))
        if let subtitles {
            let url = directory.appending(path: "launch.srt")
            try subtitles.write(to: url, atomically: true, encoding: .utf8)
            options.subtitlesURL = url
        }
        let editor = EditorState(launchOptions: options, playback: SimulatedPlaybackEngine(frameRate: rate))
        editor.reportError = { title, error in Issue.record("\(title) \(error)") }
        return editor
    }

    static let threeCues = """
        1
        00:00:01,000 --> 00:00:02,000
        One

        2
        00:00:03,000 --> 00:00:04,000
        Two

        3
        00:00:05,000 --> 00:00:06,000
        Three

        """

    func frame(_ n: Int64) -> MediaTime { MediaTime(frame: n, rate: rate) }

    func step(_ editor: EditorState, to frame: Int64) {
        editor.playback.seek(toFrame: frame, rate: rate)
        #expect(editor.currentFrame == frame)
    }

    // MARK: Import and export

    @Test func launchImportIsNotUndoable() throws {
        let editor = try makeEditor(subtitles: Self.threeCues)
        #expect(editor.track.cues.map(\.text) == ["One", "Two", "Three"])
        #expect(editor.subtitleFile?.format == .srt)
        #expect(!editor.hasUnsavedChanges)
        #expect(!editor.canPerform(.undo))
    }

    @Test func importIsUndoable() throws {
        let editor = try makeEditor(subtitles: Self.threeCues)
        let url = directory.appending(path: "other.vtt")
        try "WEBVTT\n\n00:01.000 --> 00:02.000\nOther\n".write(to: url, atomically: true, encoding: .utf8)
        editor.chooseSubtitlesToImport = { url }
        #expect(editor.perform(.importSubtitles))
        #expect(editor.track.cues.map(\.text) == ["Other"])
        #expect(editor.subtitleFile == SubtitleFileReference(url: url, format: .webVTT))
        editor.perform(.undo)
        #expect(editor.track.cues.map(\.text) == ["One", "Two", "Three"])
    }

    @Test func failedImportReportsAndKeepsCues() throws {
        let editor = try makeEditor(subtitles: Self.threeCues)
        let url = directory.appending(path: "bad.srt")
        try "not subtitles".write(to: url, atomically: true, encoding: .utf8)
        var reported: String?
        editor.reportError = { title, _ in reported = title }
        editor.importSubtitles(from: url)
        #expect(reported == "“bad.srt” could not be imported.")
        #expect(editor.track.cues.count == 3)
    }

    @Test func exportWritesTheChosenFormat() throws {
        let editor = try makeEditor(subtitles: Self.threeCues)
        editor.select(editor.track.cues[0].id)
        editor.setText("Uno", forCue: editor.track.cues[0].id)
        #expect(editor.hasUnsavedChanges)
        let destination = SubtitleFileReference(url: directory.appending(path: "out.vtt"), format: .webVTT)
        var suggested: SubtitleFileReference?
        editor.chooseExportDestination = { current in
            suggested = current
            return destination
        }
        #expect(editor.perform(.exportSubtitles))
        #expect(suggested?.format == .srt)
        #expect(editor.subtitleFile == destination)
        #expect(!editor.hasUnsavedChanges)
        let written = try String(contentsOf: destination.url, encoding: .utf8)
        #expect(written.hasPrefix("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nUno\n"))
    }

    // MARK: Cues

    @Test func addCueAtPlayheadSelectsItAndAsksForText() throws {
        let editor = try makeEditor()
        step(editor, to: 24)
        #expect(editor.perform(.addCue))
        let cue = try #require(editor.selectedCue)
        #expect(cue.start == frame(24))
        #expect(cue.end == frame(24 + 48))
        #expect(cue.text.isEmpty)
        #expect(editor.textFocusRequest == 1)
    }

    @Test func addedCueStopsAtTheNextCue() throws {
        let editor = try makeEditor(subtitles: Self.threeCues)
        step(editor, to: 60)  // 2.5 s, before "Two" at 3 s
        editor.perform(.addCue)
        #expect(editor.selectedCue?.end == MediaTime(value: 3, timescale: 1) - frame(2))
        #expect(editor.track.cues.map(\.text) == ["One", "", "Two", "Three"])
        #expect(editor.selectedCueIndex == 1)
    }

    @Test func deleteSelectsTheNextCue() throws {
        let editor = try makeEditor(subtitles: Self.threeCues)
        editor.select(editor.track.cues[1].id)
        #expect(editor.perform(.deleteCue))
        #expect(editor.track.cues.map(\.text) == ["One", "Three"])
        #expect(editor.selectedCue?.text == "Three")
        editor.perform(.deleteCue)
        #expect(editor.selectedCue?.text == "One")
        editor.perform(.deleteCue)
        #expect(editor.selectedCue == nil)
        #expect(!editor.canPerform(.deleteCue))
    }

    @Test func selectingACueMovesThePlayheadToItsFirstFrame() throws {
        let editor = try makeEditor(subtitles: Self.threeCues)
        editor.select(editor.track.cues[1].id)
        // 3 s at 23.976 fps is inside frame 71; frame 72 is the first to show the cue.
        #expect(editor.currentFrame == 72)
        #expect(editor.cueAtPlayhead?.text == "Two")
    }

    @Test func nextAndPreviousCue() throws {
        let editor = try makeEditor(subtitles: Self.threeCues)
        #expect(editor.perform(.nextCue))
        #expect(editor.selectedCue?.text == "One")
        editor.perform(.nextCue)
        editor.perform(.nextCue)
        #expect(editor.selectedCue?.text == "Three")
        #expect(!editor.canPerform(.nextCue))
        #expect(editor.perform(.previousCue))
        #expect(editor.selectedCue?.text == "Two")
    }

    // MARK: Timing

    @Test func setInAndOutAtPlayhead() throws {
        let editor = try makeEditor(subtitles: Self.threeCues)
        editor.select(editor.track.cues[0].id)
        step(editor, to: 30)
        #expect(editor.perform(.setIn))
        #expect(editor.selectedCue?.start == frame(30))
        #expect(!editor.perform(.setIn), "Already there")
        step(editor, to: 40)
        #expect(editor.perform(.setOut))
        #expect(editor.selectedCue?.end == frame(40))
        step(editor, to: 20)
        #expect(editor.canPerform(.setOut))
        #expect(!editor.perform(.setOut), "Out must follow in")
        #expect(editor.selectedCue?.end == frame(40))
    }

    @Test func setInPastTheOutKeepsTheDuration() throws {
        let editor = try makeEditor(subtitles: Self.threeCues)
        editor.select(editor.track.cues[2].id)  // "Three", 5 to 6 s, the last cue
        step(editor, to: 200)
        #expect(editor.perform(.setIn))
        let cue = try #require(editor.selectedCue)
        #expect(cue.start == frame(200))
        #expect(cue.duration == MediaTime(value: 1, timescale: 1))
    }

    @Test func setInCannotJumpOverTheNextCue() throws {
        let editor = try makeEditor(subtitles: Self.threeCues)
        editor.select(editor.track.cues[0].id)  // "One", 1 to 2 s; "Two" starts at 3 s
        step(editor, to: 200)
        #expect(!editor.perform(.setIn))
        step(editor, to: 60)  // 2.5 s: past its end, so it keeps its duration, shortened to fit
        #expect(editor.perform(.setIn))
        #expect(editor.selectedCue?.start == frame(60))
        #expect(editor.selectedCue?.end == MediaTime(value: 3, timescale: 1) - frame(2))
    }

    @Test func editsKeepTheMinimumGap() throws {
        let editor = try makeEditor(subtitles: Self.threeCues)
        let one = editor.track.cues[0].id, two = editor.track.cues[1].id
        // Typed or dragged times are clamped two frames from the neighbours.
        editor.setTiming(start: frame(10), end: frame(100), forCue: one, actionName: "Set Out")
        #expect(editor.cue(withID: one)?.end == MediaTime(value: 3, timescale: 1) - frame(2))
        editor.setTiming(start: frame(1), end: frame(90), forCue: two, actionName: "Set In")
        #expect(editor.cue(withID: two)?.start == editor.cue(withID: one)!.end + frame(2))
        // Set Out past the next cue's start is refused.
        editor.select(one)
        step(editor, to: 120)
        #expect(!editor.perform(.setOut))
        #expect(editor.issues.isEmpty)
    }

    @Test func topCuesMayOverlapBottomOnes() throws {
        let editor = try makeEditor(subtitles: Self.threeCues)
        let sign = editor.track.cues[1].id
        editor.setPosition(.top, forCue: sign)
        editor.setTiming(start: frame(10), end: frame(140), forCue: sign, actionName: "Move Cue")
        #expect(editor.cue(withID: sign)?.start == frame(10))
        #expect(editor.cue(withID: sign)?.end == frame(140))
        #expect(editor.issues.isEmpty)
        #expect(editor.room(for: sign).latestEnd == nil)
    }

    @Test func addAtPlayheadInsideACueGoesAfterIt() throws {
        let editor = try makeEditor(subtitles: Self.threeCues)
        step(editor, to: 30)  // inside "One" (1 to 2 s)
        #expect(editor.perform(.addCue))
        let added = try #require(editor.selectedCue)
        #expect(added.start == MediaTime(frame: (MediaTime(value: 2, timescale: 1) + frame(2)).firstFrame(at: rate), rate: rate))
        #expect(added.end == MediaTime(value: 3, timescale: 1) - frame(2))
    }

    @Test func fixOverlapsTrimsImportedOverlaps() throws {
        let editor = try makeEditor(subtitles: """
            1
            00:00:01,000 --> 00:00:03,500
            One

            2
            00:00:03,000 --> 00:00:04,000
            Two

            3
            00:00:03,800 --> 00:00:05,000
            {\\an8}Sign on the wall

            """)
        #expect(editor.issues.count == 1, "The top sign does not count")
        #expect(editor.perform(.fixOverlaps))
        #expect(editor.track.cues[0].end == MediaTime(value: 3, timescale: 1) - frame(2))
        #expect(editor.track.cues[2].start == MediaTime(value: 19, timescale: 5), "Top cue untouched")
        #expect(editor.issues.isEmpty)
        #expect(!editor.canPerform(.fixOverlaps))
        editor.perform(.undo)
        #expect(editor.issues.count == 1)
    }

    @Test func timingCommandsNeedASelection() throws {
        let editor = try makeEditor(subtitles: Self.threeCues)
        #expect(!editor.canPerform(.setIn))
        #expect(!editor.canPerform(.setOut))
        #expect(!editor.canPerform(.deleteCue))
    }

    // MARK: Undo

    @Test func typingUndoesAsOneStep() throws {
        let editor = try makeEditor(subtitles: Self.threeCues)
        let id = editor.track.cues[0].id
        editor.select(id)
        editor.isEditingText = true
        for text in ["O", "On", "One!", "One!!"] { editor.setText(text, forCue: id) }
        editor.perform(.undo)
        #expect(editor.cue(withID: id)?.text == "One")
        editor.perform(.redo)
        #expect(editor.cue(withID: id)?.text == "One!!")
    }

    @Test func typingSessionsEndWhenFocusLeaves() throws {
        let editor = try makeEditor(subtitles: Self.threeCues)
        let id = editor.track.cues[0].id
        editor.select(id)
        editor.isEditingText = true
        editor.setText("A", forCue: id)
        editor.isEditingText = false
        editor.isEditingText = true
        editor.setText("AB", forCue: id)
        editor.perform(.undo)
        #expect(editor.cue(withID: id)?.text == "A")
    }

    @Test func undoRedoWalksEveryEdit() throws {
        let editor = try makeEditor(subtitles: Self.threeCues)
        let original = editor.track
        editor.select(editor.track.cues[0].id)
        step(editor, to: 30)
        editor.perform(.setIn)
        editor.perform(.addCue)
        editor.setText("New", forCue: try #require(editor.selectedCueID))
        editor.perform(.deleteCue)
        let edited = editor.track

        for _ in 0..<4 { #expect(editor.perform(.undo)) }
        #expect(editor.track == original)
        #expect(!editor.canPerform(.undo))
        for _ in 0..<4 { #expect(editor.perform(.redo)) }
        #expect(editor.track == edited)
        #expect(!editor.canPerform(.redo))
    }

    @Test func undoRestoresTheSelection() throws {
        let editor = try makeEditor(subtitles: Self.threeCues)
        editor.select(editor.track.cues[1].id)
        editor.perform(.deleteCue)
        editor.perform(.undo)
        #expect(editor.selectedCue?.text == "Two")
    }

    @Test func newEditClearsRedo() throws {
        let editor = try makeEditor(subtitles: Self.threeCues)
        editor.select(editor.track.cues[0].id)
        editor.perform(.deleteCue)
        editor.perform(.undo)
        #expect(editor.canPerform(.redo))
        editor.perform(.addCue)
        #expect(!editor.canPerform(.redo))
    }

    // MARK: Shortcuts while typing

    @Test func typingKeysAreOffWhileEditingText() throws {
        let editor = try makeEditor(subtitles: Self.threeCues)
        editor.select(editor.track.cues[0].id)
        step(editor, to: 30)
        #expect(editor.isShortcutEnabled(for: .setIn))
        editor.isEditingText = true
        for command in [EditorCommand.setIn, .togglePlay, .stepForward, .shuttleForward, .deleteCue] {
            #expect(!editor.isShortcutEnabled(for: command), "\(command.id)")
            #expect(editor.canPerform(command), "Buttons still work: \(command.id)")
        }
        #expect(editor.isShortcutEnabled(for: .addCue))
    }

    // MARK: UI design pass

    @Test func movingBetweenCuesWhileTypingKeepsTheCursorInTheText() throws {
        let editor = try makeEditor(subtitles: Self.threeCues)
        editor.select(editor.track.cues[0].id)
        editor.isEditingText = true
        #expect(editor.isShortcutEnabled(for: .nextCue))
        let requests = editor.textFocusRequest
        editor.perform(.nextCue)
        #expect(editor.selectedCue?.text == "Two")
        #expect(editor.textFocusRequest == requests + 1)
    }

    @Test func splitAtThePlayheadDividesTheText() throws {
        let editor = try makeEditor(subtitles: "1\n00:00:01,000 --> 00:00:03,000\nFirst line\nsecond line\n")
        editor.select(editor.track.cues[0].id)
        step(editor, to: 48)  // 2.002 s, inside the cue
        #expect(editor.perform(.splitCue))
        #expect(editor.track.cues.map(\.text) == ["First line", "second line"])
        #expect(editor.track.cues[0].end == frame(48))
        #expect(editor.track.cues[1].start == frame(48))
        #expect(editor.track.cues[1].end == MediaTime(value: 3, timescale: 1))
        editor.perform(.undo)
        #expect(editor.track.cues.count == 1)
    }

    @Test func splitOutsideTheCueUsesItsMiddle() throws {
        let editor = try makeEditor(subtitles: "1\n00:00:01,000 --> 00:00:03,000\nWhere are we going now\n")
        editor.select(editor.track.cues[0].id)
        editor.perform(.splitCue)
        #expect(editor.track.cues.map(\.text) == ["Where are we", "going now"])
        #expect(editor.track.cues[0].end == MediaTime(value: 2, timescale: 1).snapped(to: rate))
    }

    @Test func splitTextFallsBackToOnePiece() {
        #expect(EditorState.splitText("Word") == ("Word", ""))
        #expect(EditorState.splitText("a\nb\nc") == ("a\nb", "c"))
    }

    @Test func mergeJoinsWithTheNextCue() throws {
        let editor = try makeEditor(subtitles: Self.threeCues)
        editor.select(editor.track.cues[1].id)
        #expect(editor.perform(.mergeWithNext))
        #expect(editor.track.cues.map(\.text) == ["One", "Two\nThree"])
        #expect(editor.track.cues[1].end == MediaTime(value: 6, timescale: 1))
        #expect(!editor.canPerform(.mergeWithNext), "Last cue")
    }

    @Test func positionTogglesAndExports() throws {
        let editor = try makeEditor(subtitles: Self.threeCues)
        editor.select(editor.track.cues[0].id)
        #expect(editor.isOn(.togglePositionTop) == false)
        editor.perform(.togglePositionTop)
        #expect(editor.selectedCue?.position == .top)
        #expect(editor.isOn(.togglePositionTop) == true)
        let url = directory.appending(path: "top.srt")
        editor.exportSubtitles(to: SubtitleFileReference(url: url, format: .srt))
        #expect(try String(contentsOf: url, encoding: .utf8).contains("{\\an8}One"))
        editor.perform(.undo)
        #expect(editor.selectedCue?.position == .bottom)
    }

    @Test func addCueAfterLeavesAGap() throws {
        let editor = try makeEditor(subtitles: Self.threeCues)
        editor.addCue(after: editor.track.cues[0].id)
        let added = try #require(editor.selectedCue)
        #expect(editor.selectedCueIndex == 1)
        // "One" ends at 2 s (frame 47.95, so frame 48 is the first without it); two frames later.
        #expect(added.start == frame(50))
        #expect(added.end == MediaTime(value: 3, timescale: 1) - frame(2), "Stops two frames before the next cue")
        #expect(editor.textFocusRequest == 1)
    }

    @Test func reviewIssuesFollowEdits() throws {
        let editor = try makeEditor(subtitles: Self.threeCues)
        #expect(editor.issues.isEmpty)
        #expect(!editor.canPerform(.nextIssue))
        let id = editor.track.cues[2].id
        editor.setText("", forCue: id)
        #expect(editor.issues[id] == [.empty])
        #expect(editor.perform(.nextIssue))
        #expect(editor.selectedCueID == id)
        #expect(!editor.perform(.nextIssue), "No more after it")
        editor.perform(.undo)
        #expect(editor.issues.isEmpty)
    }

    @Test func timeLabelsInFramesOrMilliseconds() throws {
        let editor = try makeEditor(subtitles: Self.threeCues)
        let start = editor.track.cues[0].start  // 1 s
        #expect(editor.label(for: start) == "00:00:01:00")
        editor.perform(.toggleMilliseconds)
        #expect(editor.label(for: start) == "00:00:01,000")
        #expect(editor.time(from: "00:00:01,500") == MediaTime(value: 3, timescale: 2))
        #expect(editor.time(from: "00:00:01:12") == frame(36))
        #expect(editor.time(from: "nonsense") == nil)
    }

    @Test func shuttleSpeedsUpAndPauses() throws {
        let editor = try makeEditor()
        editor.perform(.shuttleForward)
        #expect(editor.status.rate == 1)
        editor.perform(.shuttleForward)
        editor.perform(.shuttleForward)
        #expect(editor.status.rate == 4)
        editor.perform(.shuttleBackward)
        #expect(editor.status.rate == -1)
        editor.perform(.shuttleBackward)
        #expect(editor.status.rate == -2)
        editor.perform(.pause)
        #expect(!editor.isPlaying)
        editor.perform(.togglePlay)
        #expect(editor.status.rate == 1)
    }
}

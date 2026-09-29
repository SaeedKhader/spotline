import EditorCommands
import Foundation
import MediaAnalysis
import PlaybackCore
import QualityControl
import SubtitleCore
import SubtitleFormats
import Testing
@testable import EditorUI

/// QC presets, live issues and the issues panel, and importing and exporting styled formats.
@MainActor
struct QualityControlStateTests {
    let rate = FrameRate.fps25
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "QualityControlStateTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func f(_ n: Int64) -> MediaTime { MediaTime(frame: n, rate: rate) }

    func makeEditor(_ cues: [Cue] = [], settings: UserDefaults? = nil) -> EditorState {
        let editor = EditorState(
            launchOptions: LaunchOptions(isUITestMode: true), playback: SimulatedPlaybackEngine(frameRate: rate),
            frameRate: rate, track: SubtitleTrack(cues: cues), settings: settings
        )
        editor.reportError = { title, error in Issue.record("\(title) \(error)") }
        return editor
    }

    @Test func netflixIsTheDefaultAndPresetsChangeTheIssues() {
        // 0.6 s: too short for Netflix, fine for Basic.
        let cue = Cue(start: f(0), end: f(15), text: "Quick")
        let editor = makeEditor([cue])
        #expect(editor.qcPreset == .netflix)
        #expect(editor.issues[cue.id]?.map(\.kind) == [.tooShort(f(15))])
        editor.selectQCPreset(id: QCPreset.basic.id)
        #expect(editor.issues.isEmpty)
        #expect(!editor.canPerform(.nextIssue))
    }

    @Test func theChosenPresetIsRemembered() throws {
        let suite = "QualityControlStateTests-\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        makeEditor(settings: settings).selectQCPreset(id: QCPreset.broadcast.id)
        #expect(makeEditor(settings: settings).qcPreset == .broadcast)
        #expect(makeEditor().qcPreset == .netflix, "Without settings, the default")
    }

    @Test func shotChangesArriveAndAreChecked() async throws {
        let cue = Cue(start: f(45), end: f(100), text: "Five frames after a cut")
        let editor = makeEditor([cue])
        editor.analyzeWaveform = { _, _, _ in AudioAnalysis(waveform: Waveform(peaks: []), audioStreamIndex: 1) }
        editor.analyzeSpeech = { _, _, _ in [] }
        let cut = f(40)
        editor.analyzeShotChanges = { _, _ in [cut] }
        #expect(editor.issues.isEmpty)
        editor.open(URL(fileURLWithPath: "/tmp/cut.mov"))
        for _ in 0..<100 where editor.shotChanges == nil { await Task.yield() }
        #expect(editor.issues[cue.id]?.map(\.kind) == [.startNearShotChange(frames: 5)])
        #expect(editor.issues[cue.id]?.first?.message == "Starts 5 frames after a shot change")
    }

    @Test func fixOverlapsAlsoWidensShortGaps() {
        let one = Cue(start: f(0), end: f(50), text: "One")
        let two = Cue(start: f(51), end: f(100), text: "Two")
        let editor = makeEditor([one, two])
        #expect(editor.issues[one.id]?.map(\.kind) == [.gapTooShort(frames: 1)])
        #expect(editor.perform(.fixOverlaps))
        #expect(editor.cue(withID: one.id)?.end == f(49))
        #expect(editor.issues.isEmpty)
        #expect(editor.undoManager.undoActionName == EditorCommand.fixOverlaps.title)
    }

    @Test func issueListFollowsCueOrderAndSelects() {
        let cues = [
            Cue(start: f(0), end: f(30), text: ""),
            Cue(start: f(100), end: f(130), text: String(repeating: "a", count: 43)),
        ]
        let editor = makeEditor(cues)
        let list = editor.issueList
        #expect(list.map(\.cueNumber) == [1, 2, 2])
        #expect(list.map(\.issue.kind) == [.empty, .lineTooLong(line: 0, characters: 43), .readingSpeed(43 / 1.2)])
        #expect(Set(list.map(\.id)).count == 3)
    }

    @Test func issuesPanelToggles() {
        let editor = makeEditor()
        #expect(editor.isOn(.toggleIssuesPanel) == false)
        #expect(editor.perform(.toggleIssuesPanel))
        #expect(editor.isIssuesPanelShown)
        #expect(editor.isOn(.toggleIssuesPanel) == true)
    }

    @Test func assStylesSurviveImportAndExport() throws {
        let source = """
            [Script Info]
            ScriptType: v4.00+
            PlayResX: 1280
            PlayResY: 720

            [V4+ Styles]
            Format: Name, Fontname, Fontsize, Alignment
            Style: Default,Arial,40,2
            Style: Sign,Arial,30,8

            [Events]
            Format: Layer, Start, End, Style, Name, Text
            Dialogue: 0,0:00:01.00,0:00:03.00,Default,Anna,{\\i1}Hello{\\i0}
            Dialogue: 0,0:00:04.00,0:00:06.00,Sign,,EXIT

            """
        let url = directory.appending(path: "in.ass")
        try source.write(to: url, atomically: true, encoding: .utf8)
        let editor = makeEditor()
        editor.importSubtitles(from: url)
        #expect(editor.subtitleFile?.format == .ass)
        #expect(editor.track.styles.map(\.name) == ["Default", "Sign"])
        #expect(editor.track.cues.map(\.position) == [.bottom, .top])
        #expect(editor.track.cues[0].text == "<i>Hello</i>")

        editor.setText("<i>Hello</i> there", forCue: editor.track.cues[0].id)
        let out = directory.appending(path: "out.ass")
        editor.exportSubtitles(to: SubtitleFileReference(url: out, format: .ass))
        let written = try String(contentsOf: out, encoding: .utf8)
        #expect(written.contains("PlayResX: 1280\n"))
        #expect(written.contains("Style: Sign,Arial,30,"))
        #expect(written.contains("Dialogue: 0,0:00:01.00,0:00:03.00,Default,Anna,0,0,0,,{\\i1}Hello{\\i0} there\n"))
        #expect(written.contains("Dialogue: 0,0:00:04.00,0:00:06.00,Sign,,0,0,0,,EXIT\n"))

        // Undoing the import puts back the empty track, styles included.
        editor.perform(.undo)
        editor.perform(.undo)
        #expect(editor.track.styles.isEmpty)
    }

    @Test func ttmlExportsPositionsAndLanguage() throws {
        let url = directory.appending(path: "in.ttml")
        try """
            <tt xmlns="http://www.w3.org/ns/ttml" xml:lang="ar"><body><div>
            <p begin="1s" end="2s">مرحبا</p>
            </div></body></tt>
            """.write(to: url, atomically: true, encoding: .utf8)
        let editor = makeEditor()
        editor.importSubtitles(from: url)
        #expect(editor.track.languageCode == "ar")
        editor.setPosition(.top, forCue: editor.track.cues[0].id)
        let out = directory.appending(path: "out.ttml")
        editor.exportSubtitles(to: SubtitleFileReference(url: out, format: .ttml))
        let written = try String(contentsOf: out, encoding: .utf8)
        #expect(written.contains("xml:lang=\"ar\""))
        #expect(written.contains("<p begin=\"00:00:01.000\" end=\"00:00:02.000\" region=\"top\">مرحبا</p>"))
    }
}

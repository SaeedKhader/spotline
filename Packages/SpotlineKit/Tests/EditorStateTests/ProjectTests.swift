import AITools
import EditorCommands
import Foundation
import MediaAnalysis
import PlaybackCore
import SubtitleCore
import Testing
@testable import EditorUI

/// Projects (`.spotline`): what is saved, and that reopening puts it all back
/// without analyzing, transcribing or uploading again.
@MainActor
struct ProjectTests {
    let rate = FrameRate.fps25
    let directory: URL
    let media: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "ProjectTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        media = directory.appending(path: "Episode 1.mkv")
        try Data("video".utf8).write(to: media)
    }

    /// An editor on the simulated player whose analysis and transcription count their runs.
    func makeEditor(counter: RunCounter = RunCounter()) -> EditorState {
        let editor = EditorState(
            launchOptions: LaunchOptions(isUITestMode: true), playback: SimulatedPlaybackEngine(frameRate: rate, frameCount: 250)
        )
        editor.analyzeWaveform = { _, stream, _ in
            counter.add("waveform")
            return AudioAnalysis(waveform: Waveform(peaks: [1, 2, 3]), audioStreamIndex: stream ?? 1)
        }
        editor.analyzeSpeech = { _, _, _ in
            counter.add("speech")
            return [SpeechRegion(start: .zero, end: MediaTime(value: 1, timescale: 1), confidence: 0.9)]
        }
        editor.analyzeShotChanges = { _, _ in
            counter.add("shots")
            return [MediaTime(value: 2, timescale: 1)]
        }
        editor.listEmbeddedSubtitles = { _ in [] }
        editor.prepareAudio = { _, _, progress in
            progress(1)
            return PreparedAudio(source: .mix, audioStreamIndex: 0, duration: MediaTime(value: 10, timescale: 1), chunks: [])
        }
        editor.aiProviders = AIProviderFactory(
            transcriber: { _ in CountingTranscriber(counter: counter) }, translator: { _ in ScriptedTranslator() }
        )
        editor.reportError = { title, error in Issue.record("\(title) \(error)") }
        editor.locateMissingMedia = { name in
            Issue.record("Asked for \(name)")
            return nil
        }
        return editor
    }

    func settle(_ editor: EditorState) async {
        for _ in 0..<200 where editor.waveformJob != nil || editor.shotChangesJob != nil || editor.speechJob != nil || editor.aiTask != nil {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func cue(_ text: String, at second: Int64) -> Cue {
        Cue(start: MediaTime(value: second, timescale: 1), end: MediaTime(value: second + 1, timescale: 1), text: text)
    }

    /// Writes the editor's project as a package and reads it back, as saving and reopening does.
    func saveAndRead(_ editor: EditorState, to url: URL) throws -> ProjectFile {
        try editor.projectFile(savingTo: url).fileWrapper().write(to: url, options: .atomic, originalContentsURL: nil)
        return try ProjectFile(fileWrapper: FileWrapper(url: url))
    }

    @Test func reopeningPutsEverythingBackWithoutAnalyzingAgain() async throws {
        let counter = RunCounter()
        let editor = makeEditor(counter: counter)
        editor.open(media)
        await settle(editor)
        #expect(counter.count("waveform") == 1)
        editor.edit("Add") { track in
            track.cues = [cue("One", at: 1), cue("Two", at: 3)]
            track.cues[1].isAIGenerated = true
            track.languageCode = "en"
        }
        editor.selectQCPreset(id: "broadcast")
        editor.select(editor.track.cues[1].id)
        let url = directory.appending(path: "Episode 1.spotline")
        let project = try saveAndRead(editor, to: url)

        let reopened = makeEditor(counter: counter)
        reopened.loadProject(project, from: url)
        await settle(reopened)
        #expect(reopened.status.mediaURL?.resolvingSymlinksInPath() == media.resolvingSymlinksInPath())
        #expect(reopened.track == editor.track, "Cues, AI tint and language come back")
        #expect(reopened.qcPreset.id == "broadcast")
        #expect(reopened.selectedCueID == editor.track.cues[1].id)
        #expect(reopened.audioAnalysis?.waveform.peaks == [1, 2, 3])
        #expect(reopened.shotChanges == [MediaTime(value: 2, timescale: 1)])
        #expect(reopened.speech?.count == 1)
        #expect(counter.count("waveform") == 1 && counter.count("shots") == 1 && counter.count("speech") == 1, "Nothing is analyzed again")
        #expect(!reopened.canUndo, "Opening a project is not an edit")
        #expect(reopened.projectURL == url)
    }

    @Test func packageRoundTripsEveryPart() throws {
        let source = SubtitleTrack(languageCode: "en", cues: [cue("Hello", at: 1)])
        var target = SubtitleTrack(languageCode: "ar", cues: [cue("مرحبا", at: 1)])
        target.cues[0].sourceCueID = source.cues[0].id
        let project = ProjectFile(
            media: MediaReference(url: media, projectURL: directory.appending(path: "P.spotline")), frameRate: rate, track: target,
            sourceTrack: source, qcPresetID: "netflix", selectedCueID: target.cues[0].id, playhead: MediaTime(value: 3, timescale: 2),
            agentWrittenCueIDs: [target.cues[0].id],
            analysis: StoredAnalysis(
                waveforms: ["main": AudioAnalysis(waveform: Waveform(peaks: [4, 5]), audioStreamIndex: 1)],
                speech: ["2": []], shotChanges: [MediaTime(value: 1, timescale: 1)]
            ),
            transcripts: [StoredTranscript(provider: "elevenLabsScribe", audioStream: nil, language: "en", words: ScriptedTranscriber.fixture.words)]
        )
        let read = try ProjectFile(fileWrapper: project.fileWrapper(cache: ProjectFile.EncodingCache()))
        #expect(read == project)
        #expect(project.media?.relativePath == "Episode 1.mkv")
    }

    @Test func projectsFromANewerSpotlineAreRefused() throws {
        let wrapper = try ProjectFile().fileWrapper()
        let manifest = try #require(wrapper.fileWrappers?[ProjectFile.manifestName]?.regularFileContents)
        var json = try #require(try JSONSerialization.jsonObject(with: manifest) as? [String: Any])
        json["formatVersion"] = ProjectFile.formatVersion + 1
        wrapper.removeFileWrapper(try #require(wrapper.fileWrappers?[ProjectFile.manifestName]))
        wrapper.addRegularFile(withContents: try JSONSerialization.data(withJSONObject: json), preferredFilename: ProjectFile.manifestName)
        #expect(throws: ProjectFile.ReadError.newerVersion(ProjectFile.formatVersion + 1)) { try ProjectFile(fileWrapper: wrapper) }
        #expect(throws: ProjectFile.ReadError.notAProject) { try ProjectFile(fileWrapper: FileWrapper(directoryWithFileWrappers: [:])) }
    }

    @Test func editsUndoAndSettingsTellTheDocument() {
        let editor = makeEditor()
        var changes: [ProjectChange] = []
        editor.projectDidChange = { changes.append($0) }
        editor.edit("Add") { $0.cues = [cue("One", at: 1)] }
        editor.perform(.undo)
        editor.perform(.redo)
        editor.selectQCPreset(id: "broadcast")
        #expect(changes == [.edit, .undo, .redo, .other])

        // Putting a project in place is no change.
        changes = []
        editor.loadProject(ProjectFile(frameRate: rate, track: SubtitleTrack(cues: [cue("Two", at: 2)]), qcPresetID: "standard"), from: nil)
        #expect(changes.isEmpty)
        #expect(editor.track.cues.map(\.text) == ["Two"])
    }

    @Test func openingOtherMediaIsAChange() {
        let editor = makeEditor()
        var changes: [ProjectChange] = []
        editor.projectDidChange = { changes.append($0) }
        editor.open(media)
        #expect(changes == [.other])
        #expect(editor.projectFile(savingTo: nil).media?.path == media.path)
    }

    @Test func aMovedVideoIsFoundBesideTheProject() throws {
        let editor = makeEditor()
        let folder = directory.appending(path: "Copied")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appending(path: "Episode 1.mkv")
        try FileManager.default.copyItem(at: media, to: copy)
        // The original path and bookmark lead nowhere on this Mac.
        let reference = MediaReference(bookmark: nil, isSecurityScoped: false, path: "/Volumes/Gone/Episode 1.mkv", relativePath: "Episode 1.mkv")
        editor.loadProject(ProjectFile(media: reference, frameRate: rate), from: folder.appending(path: "Episode 1.spotline"))
        #expect(editor.status.mediaURL == copy)
        #expect(editor.missingMediaName == nil)
    }

    @Test func aMissingVideoIsAskedForAndKept() throws {
        let editor = makeEditor()
        var asked: [String] = []
        editor.locateMissingMedia = { name in
            asked.append(name)
            return nil
        }
        let reference = MediaReference(bookmark: nil, isSecurityScoped: false, path: "/Volumes/Gone/Pilot.mov", relativePath: nil)
        editor.loadProject(ProjectFile(media: reference, frameRate: rate, track: SubtitleTrack(cues: [cue("Hi", at: 1)])), from: nil)
        #expect(asked == ["Pilot.mov"])
        #expect(!editor.hasMedia)
        #expect(editor.missingMediaName == "Pilot.mov")
        #expect(editor.track.cues.map(\.text) == ["Hi"], "The cues open without the video")
        #expect(editor.projectFile(savingTo: nil).media == reference, "Saving keeps pointing at the video")

        // Opening the video again relinks the project.
        var changes: [ProjectChange] = []
        editor.projectDidChange = { changes.append($0) }
        editor.open(media)
        #expect(editor.missingMediaName == nil)
        #expect(changes == [.other])
        #expect(editor.projectFile(savingTo: nil).media?.path == media.path)
    }

    @Test func aVideoLocatedByHandOpens() {
        let editor = makeEditor()
        editor.locateMissingMedia = { _ in media }
        var changes: [ProjectChange] = []
        editor.projectDidChange = { changes.append($0) }
        let reference = MediaReference(bookmark: nil, isSecurityScoped: false, path: "/Volumes/Gone/Pilot.mov", relativePath: nil)
        editor.loadProject(ProjectFile(media: reference, frameRate: rate), from: nil)
        #expect(editor.status.mediaURL == media)
        #expect(changes == [.other], "The new location is saved")
    }

    @Test func transcribingAgainUsesTheSavedWords() async throws {
        let counter = RunCounter()
        let editor = makeEditor(counter: counter)
        var aiStarts = 0
        editor.aiToolWillStart = { aiStarts += 1 }
        editor.open(media)
        await settle(editor)
        #expect(editor.perform(.transcribe))
        await settle(editor)
        #expect(counter.count("transcribe") == 1)
        #expect(aiStarts == 1, "The project can save itself before the tool runs")
        let transcript = editor.track.cues.map(\.text)
        let url = directory.appending(path: "Episode 1.spotline")
        let project = try saveAndRead(editor, to: url)
        #expect(project.transcripts.first?.words.count == ScriptedTranscriber.fixture.words.count)

        let reopened = makeEditor(counter: counter)
        reopened.loadProject(project, from: url)
        await settle(reopened)
        #expect(reopened.track.cues.map(\.text) == transcript)
        reopened.edit("Clear") { $0.cues = [] }
        #expect(reopened.perform(.transcribe))
        await settle(reopened)
        #expect(counter.count("transcribe") == 1, "Nothing is sent to the transcriber again")
        #expect(reopened.track.cues.map(\.text) == transcript)
    }

    @Test func newProjectsGoBesideTheVideoWithAFreeName() {
        let video = URL(fileURLWithPath: "/Shows/Pilot.mkv")
        let taken: Set<String> = ["/Shows/Pilot.spotline", "/Shows/Pilot 2.spotline"]
        #expect(ProjectFile.suggestedURL(forMedia: video) { taken.contains($0.path) }.path == "/Shows/Pilot 3.spotline")
        #expect(ProjectFile.suggestedURL(forMedia: video) { _ in false }.path == "/Shows/Pilot.spotline")
    }

    @Test func videoPathsFromTheProjectFolder() {
        let path = { (folder: String, target: String) in
            MediaReference.relativePath(from: URL(fileURLWithPath: folder), to: URL(fileURLWithPath: target))
        }
        #expect(path("/Shows/Season 1", "/Shows/Season 1/Pilot.mkv") == "Pilot.mkv")
        #expect(path("/Shows/Projects", "/Shows/Media/Pilot.mkv") == "../Media/Pilot.mkv")
        #expect(path("/Users/me/Projects", "/Volumes/Drive/Pilot.mkv") == nil, "Not across disks")
    }

    @Test func theStandInEditorOnlyOpensProjects() {
        let editor = makeEditor()
        editor.allowedCommandIDs = EditorWorkspace.commandsWithoutProject
        #expect(editor.canPerform(.openMedia))
        #expect(!editor.canPerform(.importSubtitles))
        #expect(!editor.canPerform(.addCue))
    }
}

/// Counts analysis and transcription runs, from any thread.
final class RunCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func add(_ name: String) {
        lock.withLock { counts[name, default: 0] += 1 }
    }

    func count(_ name: String) -> Int {
        lock.withLock { counts[name] ?? 0 }
    }
}

/// The scripted transcriber, counting how often audio is sent to it.
struct CountingTranscriber: Transcriber {
    let counter: RunCounter
    var name: String { "Counting transcriber" }

    func transcribe(
        _ audio: PreparedAudio, language: String?, progress: @escaping @Sendable (Double) -> Void,
        found: @escaping @Sendable ([TranscribedWord]) -> Void
    ) async throws -> [TranscribedWord] {
        counter.add("transcribe")
        return try await ScriptedTranscriber.fixture.transcribe(audio, language: language, progress: progress, found: found)
    }
}

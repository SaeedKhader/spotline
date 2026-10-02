import EditorCommands
import Foundation
import MediaAnalysis
import SubtitleCore

/// Scene frames: the few frames of each scene that show who is there, picked on
/// this Mac for a vision model to describe later (docs/ARCHITECTURE.md, section 7d).
/// Frames are read while the lines are spoken and just after the shot changes
/// around them, grouped into scenes, and the many frames of one camera setup
/// become one. Nothing is sent anywhere: the sheet shows what was picked, and
/// Export writes the frames and a list of them to a folder.
extension EditorState {
    /// When each line of the script is spoken: the source when translating, else the cues being edited.
    var sceneFrameLines: [SceneFramePicker.Line] {
        briefSourceTrack.cues.filter { !SubtitleText.visibleLines(of: $0.text).joined().allSatisfy(\.isWhitespace) }
            .sorted { $0.start < $1.start }
            .map { SceneFramePicker.Line(start: $0.start, end: $0.end) }
    }

    var canPickSceneFrames: Bool { hasMedia && !sceneFrameLines.isEmpty }

    /// Opens the sheet, picking the frames when there are none yet.
    func showSceneFrames() {
        isSceneFramesSheetShown = true
        if sceneFrames == nil, sceneFramesJob == nil { pickSceneFrames() }
    }

    public func dismissSceneFrames() {
        isSceneFramesSheetShown = false
    }

    /// Reads the frames in the background and groups them into scenes, replacing what was picked before.
    func pickSceneFrames() {
        sceneFramesTask?.cancel()
        guard let url = status.mediaURL else { return }
        let lines = sceneFrameLines
        guard !lines.isEmpty else { return }
        let samples = SceneFramePicker.samples(lines: lines, shotChanges: shotChanges ?? [])
        sceneFrames = nil
        sceneFramesJob = AnalysisJob()
        let grab = grabFrames
        let report: @Sendable (MediaAnalyzer.Progress<Int>) -> Void = { [weak self] progress in
            guard let editor = self else { return }
            Task { @MainActor in
                guard editor.status.mediaURL == url, let job = editor.sceneFramesJob, let next = job.advanced(by: progress) else { return }
                editor.sceneFramesJob = next
            }
        }
        sceneFramesTask = Task { [weak self] in
            do {
                let grabbed = try await grab(url, samples.map(\.time), report)
                let scenes = try await EditorState.runDetached {
                    let frames = grabbed.filter { samples.indices.contains($0.index) }.map { frame in
                        SceneFramePicker.Frame(
                            id: frame.index, time: frame.time, line: samples[frame.index].line, signature: frame.signature,
                            faces: frame.faces, jpeg: frame.jpeg, width: frame.width, height: frame.height
                        )
                    }
                    return SceneFramePicker.scenes(frames: frames, lines: lines)
                }
                guard let self, !Task.isCancelled, self.status.mediaURL == url else { return }
                self.sceneFrames = scenes
                self.sceneFramesJob = nil
            } catch {
                guard let self, !Task.isCancelled, self.status.mediaURL == url else { return }
                self.sceneFramesJob = nil
                self.isSceneFramesSheetShown = false
                self.reportError("The scene frames could not be picked.", error)
            }
        }
    }

    /// Forgets the picked frames and stops picking; the media they were of is gone.
    func resetSceneFrames() {
        sceneFramesTask?.cancel()
        sceneFramesTask = nil
        sceneFrames = nil
        sceneFramesJob = nil
        isSceneFramesSheetShown = false
    }

    /// Shows a picked frame in the video, closing the sheet.
    public func showSceneFrame(at time: MediaTime) {
        guard hasMedia else { return }
        isSceneFramesSheetShown = false
        seek(toFrame: time.nearestFrame(at: frameRate))
    }

    /// The scene's lines as the script has them, for the sheet and the export.
    public func sceneFrameCues(_ lines: ClosedRange<Int>) -> [Cue] {
        let cues = briefSourceTrack.cues.filter { !SubtitleText.visibleLines(of: $0.text).joined().allSatisfy(\.isWhitespace) }
            .sorted { $0.start < $1.start }
        return Array(cues[max(lines.lowerBound, 0)..<min(lines.upperBound + 1, cues.count)])
    }

    /// Writes each picked frame as a JPEG ("scene-03-frame-2.jpg") and "scenes.json",
    /// which lists the scenes with their frames and lines, into `folder`.
    func exportSceneFrames(to folder: URL) {
        guard let scenes = sceneFrames else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var listed: [SceneFramesExport.Scene] = []
            for (number, scene) in scenes.enumerated() {
                var frames: [SceneFramesExport.Frame] = []
                for (order, pick) in scene.picks.enumerated() {
                    let name = String(format: "scene-%02d-frame-%d.jpg", number + 1, order + 1)
                    try pick.frame.jpeg.write(to: folder.appending(path: name))
                    frames.append(SceneFramesExport.Frame(
                        file: name, time: timecode(pick.frame.time), faces: pick.frame.faces.count, isWidest: pick.isWidest,
                        linesSpokenOver: pick.lines.count, similarFramesLeftOut: pick.alike.count
                    ))
                }
                let lines = sceneFrameCues(scene.lines).map { cue in
                    SceneFramesExport.Line(
                        time: timecode(cue.start), voice: (cue.speaker.map { [$0] } ?? cue.voices ?? []).joined(separator: ", "),
                        text: SubtitleText.visibleLines(of: cue.text).joined(separator: " ")
                    )
                }
                listed.append(SceneFramesExport.Scene(scene: number + 1, start: timecode(scene.start), end: timecode(scene.end), frames: frames, lines: lines))
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(listed).write(to: folder.appending(path: "scenes.json"))
        } catch {
            reportError("The scene frames could not be exported.", error)
        }
    }

    func timecode(_ time: MediaTime) -> String {
        Timecode(frameNumber: max(time.firstFrame(at: frameRate), 0), rate: frameRate).description
    }

    func canPerformSceneFrames(_ command: EditorCommand) -> Bool {
        switch command.id {
        case EditorCommand.showSceneFrames.id: canPickSceneFrames
        case EditorCommand.pickSceneFramesAgain.id: canPickSceneFrames && sceneFramesJob == nil
        case EditorCommand.exportSceneFrames.id: sceneFrames?.isEmpty == false
        default: false
        }
    }

    func performSceneFrames(_ command: EditorCommand) -> Bool {
        guard canPerformSceneFrames(command) else { return false }
        switch command.id {
        case EditorCommand.showSceneFrames.id: showSceneFrames()
        case EditorCommand.pickSceneFramesAgain.id: pickSceneFrames()
        case EditorCommand.exportSceneFrames.id:
            guard let folder = chooseSceneFramesFolder() else { return false }
            exportSceneFrames(to: folder)
        default: return false
        }
        return true
    }
}

/// What "scenes.json" lists beside the exported frames.
enum SceneFramesExport {
    struct Scene: Codable {
        var scene: Int
        var start: String
        var end: String
        var frames: [Frame]
        var lines: [Line]
    }

    struct Frame: Codable {
        var file: String
        var time: String
        var faces: Int
        var isWidest: Bool
        var linesSpokenOver: Int
        var similarFramesLeftOut: Int
    }

    struct Line: Codable {
        var time: String
        var voice: String
        var text: String
    }
}

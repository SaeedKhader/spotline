import AITools
import Foundation
import MediaAnalysis
import SubtitleCore

/// The scene sheet: GPT-6 Luna looks at the frames picked for each scene and writes
/// who is in view into the episode brief ("In the Video"), which the user confirms
/// and the translator then reads as text (docs/ARCHITECTURE.md, section 7d). It runs
/// by itself after the brief is built when "Send video frames" is on, and from
/// AI › Describe Scenes from Video. Luna only reports what it sees; it never words a line.
extension EditorState {
    /// What the describer gets for each scene: its picked frames, its lines with who the brief says speaks them, and the brief's people.
    func sceneRequests(for scenes: [SceneFramePicker.Scene], brief: EpisodeBrief) -> [SceneRequest] {
        let named = brief.people.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        let people = named.map { SceneRequest.Person(name: $0.name, gender: $0.gender) }
        return scenes.filter { !$0.picks.isEmpty }.map { scene in
            let lines = sceneFrameCues(scene.lines).map { cue -> SceneRequest.Line in
                let voices = cue.speaker.map { [$0] } ?? voices(for: cue) ?? []
                let speaker = named.first { !Set($0.voices).isDisjoint(with: voices) }?.name
                return SceneRequest.Line(start: cue.start, voices: voices, name: speaker, text: SubtitleText.visibleLines(of: cue.text).joined(separator: " "))
            }
            return SceneRequest(
                start: scene.start, frames: scene.picks.map { SceneRequest.Frame(time: $0.frame.time, jpeg: $0.frame.jpeg, isWidest: $0.isWidest) },
                lines: lines, people: people, work: brief.work
            )
        }
    }

    /// From the brief's dialog: keeps what was edited there (unconfirmed still), then describes the scenes.
    public func describeScenes(keeping draft: EpisodeBrief) {
        guard canPerform(.describeScenes) else { return }
        if draft != track.brief { edit("Edit Episode Brief") { track in track.brief = draft } }
        isBriefSheetShown = false
        describeScenes(automatically: false)
    }

    /// Picks the scene frames when there are none yet, sends each scene's to the describer and
    /// puts the notes in the brief, as one undoable edit; then the brief opens. `automatically`
    /// (after the brief is built): quietly skipped without a describer, and the brief opens anyway.
    func describeScenes(automatically: Bool) {
        func skip(_ error: any Error) {
            if automatically { isBriefSheetShown = true } else { reportError("The scenes could not be described.", error) }
        }
        guard let url = status.mediaURL, track.brief != nil, !sceneFrameLines.isEmpty else {
            return skip(AIError.nothingToDo("It needs the video, its lines and an episode brief."))
        }
        let describer: (any SceneDescriber)?
        do { describer = try aiProviders.sceneDescriber(aiSettings) } catch { return skip(error) }
        guard let describer else { return skip(AIError.provider("It needs GPT-6 Luna: allow cloud AI and add an OpenAI API key in Settings › AI.")) }

        aiSummary = nil
        aiTask = AITaskStatus(title: "Scene Descriptions", provider: describer.name, stages: ["Picking frames", "Describing scenes"])
        aiTask?.fraction = 0
        aiTaskGeneration += 1
        let generation = aiTaskGeneration
        let picked = sceneFrames
        aiTaskHandle = Task { [weak self] in
            do {
                let scenes: [SceneFramePicker.Scene]
                if let picked {
                    scenes = picked
                } else {
                    guard let loaded = try await self?.loadSceneFrames(from: url, report: { progress in
                        Task { @MainActor in
                            guard let self, self.aiTaskGeneration == generation else { return }
                            self.aiTask?.fraction = progress.fraction
                        }
                    }) else { return }
                    scenes = loaded
                }
                guard let self, !Task.isCancelled, self.aiTaskGeneration == generation else { return }
                // Other media, or the brief undone, meanwhile: there is nothing to describe any more.
                guard self.status.mediaURL == url, let brief = self.track.brief else {
                    self.aiTask = nil
                    return
                }
                self.sceneFrames = scenes
                let requests = self.sceneRequests(for: scenes, brief: brief)
                self.aiTask?.stage = 1
                self.aiTask?.fraction = 0
                self.aiTask?.detail = "0 of \(requests.count) scenes"
                let notes = try await describer.describe(requests) { [weak self] done, total in
                    Task { @MainActor in
                        guard let self, self.aiTaskGeneration == generation, total > 0 else { return }
                        self.aiTask?.detail = "\(done) of \(total) scenes"
                        self.aiTask?.fraction = Double(done) / Double(total)
                    }
                }
                guard !Task.isCancelled, self.aiTaskGeneration == generation else { return }
                self.aiTask = nil
                let seen = notes.sorted { $0.start < $1.start }.map(\.line).joined(separator: "\n")
                self.edit("Describe Scenes") { track in track.brief?.seen = seen }
                // In the plan, the brief opens when it is next to be confirmed.
                if self.aiFlow != nil { self.aiFlowFinished(.scenes) } else { self.isBriefSheetShown = true }
                self.onAITaskEnd?(AITaskEnd(
                    title: "Scenes described", message: notes.count == 1 ? "1 scene, in the episode brief" : "\(notes.count) scenes, in the episode brief",
                    succeeded: true
                ))
            } catch {
                guard let self else { return }
                if self.aiTaskGeneration == generation { self.aiTask = nil }
                if !(error is CancellationError), !Task.isCancelled {
                    self.reportError("The scene descriptions stopped.", error)
                    self.onAITaskEnd?(AITaskEnd(title: "Scene descriptions stopped", message: error.localizedDescription, succeeded: false))
                }
                // The brief is there without them.
                if self.aiFlow != nil, !(error is CancellationError), !Task.isCancelled {
                    self.aiFlowFinished(.scenes)
                } else if automatically, self.track.brief != nil {
                    self.isBriefSheetShown = true
                }
            }
        }
    }
}

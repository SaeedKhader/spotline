import AITools
import EditorCommands
import Foundation
import QualityControl
import SubtitleCore

/// What changed in a project, for the document's edited state and autosave.
public enum ProjectChange: Sendable {
    /// An undoable edit.
    case edit
    case undo
    case redo
    /// Something saved that is not an edit: the video, a file, the QC preset, the source.
    case other
}

/// The project document's commands (new, open, save, duplicate, revert), which
/// `EditorState.perform` hands over so menus, shortcuts and agents share them.
@MainActor
public protocol ProjectActions: AnyObject {
    func canPerform(_ command: EditorCommand, projectURL: URL?) -> Bool
    func perform(_ command: EditorCommand) -> Bool
}

/// Projects (`.spotline`, see `ProjectFile`): what the editor saves, and putting
/// a saved project back. Reopening shows the same cues, analysis and AI results
/// without reading, analyzing or uploading anything again.
extension EditorState {
    /// Everything the project file keeps, as it is now.
    public func projectFile(savingTo projectURL: URL?) -> ProjectFile {
        var media = mediaReference
        if let url = status.mediaURL, media?.path != url.path || (projectURL != nil && media?.relativePath == nil) {
            media = MediaReference(url: url, projectURL: projectURL)
            mediaReference = media
        }
        return ProjectFile(
            media: media, frameRate: frameRate, track: track, sourceTrack: sourceTrack,
            subtitleFile: subtitleFile.map(ProjectFile.StoredFile.init), sourceFile: sourceFile.map(ProjectFile.StoredFile.init),
            qcPresetID: qcPreset.id, selectedCueID: selectedCueID, playhead: hasMedia ? currentTime : projectPlayhead,
            agentWrittenCueIDs: track.cues.map(\.id).filter(agentWrittenCues.contains),
            analysis: storedAnalysis, transcripts: storedTranscripts
        )
    }

    /// Puts a saved project in place of what the editor shows, with nothing to undo.
    /// A video that cannot be found is asked for (`locateMissingMedia`); without
    /// it the cues still open, and the project keeps pointing at the video.
    public func loadProject(_ project: ProjectFile, from projectURL: URL?) {
        isLoadingProject = true
        defer { isLoadingProject = false }
        if hasMedia || !track.cues.isEmpty || sourceTrack != nil { resetForNewMedia() }
        self.projectURL = projectURL
        frameRate = project.frameRate
        track = project.track
        // Projects saved before sure choices were left out of the review.
        track.settleSureFlags()
        sourceFile = project.sourceFile?.reference
        sourceTrack = project.sourceTrack
        subtitleFile = project.subtitleFile?.reference
        if let preset = project.qcPresetID.flatMap(QCPreset.named) { selectQCPreset(id: preset.id) }
        agentWrittenCues = Set(project.agentWrittenCueIDs)
        storedAnalysis = project.analysis
        storedTranscripts = project.transcripts
        mediaReference = project.media
        projectPlayhead = project.playhead
        selectedCueID = project.selectedCueID.flatMap { cue(withID: $0)?.id }
        translationPairDidChange()
        undoManager.removeAllActions()
        refreshUndoState()
        hasUnsavedChanges = false

        guard let media = project.media else { return }
        if let (url, isStale) = media.resolve(projectURL: projectURL) {
            if isStale { mediaReference = MediaReference(url: url, projectURL: projectURL) }
            if status.mediaURL?.standardizedFileURL == url.standardizedFileURL {
                // Reverting: the video stays open; its analysis comes from the project again.
                startWaveformAnalysis()
                startShotChangeAnalysis()
                if let playhead = project.playhead { playback.seek(toFrame: playhead.nearestFrame(at: frameRate), rate: frameRate) }
                return
            }
            projectMediaURL = url
            playback.load(url)
        } else if let url = locateMissingMedia(media.fileName) {
            // Found by hand: a change to save.
            mediaReference = MediaReference(url: url, projectURL: projectURL)
            playback.load(url)
        } else {
            missingMediaName = media.fileName
        }
    }

    /// Called when the player opens media. Media the project did not open (the
    /// person or an agent chose it) is a change to save.
    func mediaDidOpen() {
        guard let url = status.mediaURL else { return }
        missingMediaName = nil
        if let expected = projectMediaURL, expected.standardizedFileURL == url.standardizedFileURL {
            projectMediaURL = nil
            if let playhead = projectPlayhead, playhead > .zero {
                playback.seek(toFrame: playhead.nearestFrame(at: frameRate), rate: frameRate)
            }
            return
        }
        projectMediaURL = nil
        if mediaReference?.path != url.path { mediaReference = MediaReference(url: url, projectURL: projectURL) }
        projectDidChange?(.other)
    }

    /// Stops playback and background work when the project's window closes.
    public func close() {
        cancelAITask()
        cancelAnalysis()
        playback.setPaused(true)
        playback.unload()
    }

    // MARK: Transcripts

    /// The words a transcriber already returned for this audio, if the project has them.
    func storedTranscript(provider: AISettings.TranscriptionProvider, audioStream: Int?, language: String?) -> [TranscribedWord]? {
        storedTranscripts.last {
            $0.provider == provider.rawValue && $0.audioStream == audioStream && $0.language == language && !$0.words.isEmpty
        }?.words
    }

    /// Keeps a transcriber's words in the project (replacing older ones for the same audio).
    func storeTranscript(_ words: [TranscribedWord], provider: AISettings.TranscriptionProvider, audioStream: Int?, language: String?) {
        let transcript = StoredTranscript(provider: provider.rawValue, audioStream: audioStream, language: language, words: words)
        storedTranscripts.removeAll { $0.fileName == transcript.fileName }
        storedTranscripts.append(transcript)
        projectDidChange?(.other)
    }
}

import EditorCommands
import SwiftUI

/// Builds the app's command menus from `EditorCommand.all`.
public struct EditorMenuCommands: Commands {
    let workspace: EditorWorkspace
    /// The project window in front, or the stand-in while none is open.
    var editor: EditorState { workspace.menuEditor }

    public init(workspace: EditorWorkspace) {
        self.workspace = workspace
    }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            buttons(for: .file, only: [.newProject, .openProject])
            OpenRecentMenu(workspace: workspace)
            Divider()
            buttons(for: .file, only: [.openMedia, .importSubtitles, .importEmbeddedSubtitles])
        }
        CommandGroup(replacing: .saveItem) {
            buttons(for: .file, only: [.saveProject, .duplicateProject])
            Menu("Revert To") {
                buttons(for: .file, only: [.revertProject, .browseProjectVersions])
            }
            Divider()
            buttons(for: .file, only: [.exportSubtitles])
        }
        // The editor's undo stack also covers typing in the cue text editor,
        // so it replaces the text system's Undo and Redo.
        CommandGroup(replacing: .undoRedo) {
            buttons(for: .editing)
        }
        // View: what the window shows, and the timeline's zoom, snapping and speech highlight.
        CommandGroup(after: .toolbar) {
            buttons(for: .view)
            Divider()
            buttons(for: .timeline, only: [.zoomIn, .zoomOut])
            Divider()
            buttons(for: .timeline, only: [.toggleSnapping, .toggleSpeechHighlight])
            Divider()
        }
        CommandMenu("Cue") {
            buttons(for: .cue)
            Divider()
            buttons(for: .navigation)
        }
        CommandMenu("Review") {
            buttons(for: .review)
            Divider()
            QCPresetPicker(editor: editor)
        }
        CommandMenu("Translation") {
            buttons(for: .translation)
            Divider()
            TargetLanguagePicker(editor: editor)
                .disabled(!editor.isTranslating)
        }
        CommandMenu("AI") {
            buttons(for: .ai, only: [.planAIFlow, .continueAIFlow])
            Divider()
            // Each step by itself, to do one again.
            buttons(for: .ai, only: [.transcribe, .syncSubtitlesToAudio, .showEpisodeBrief, .rebuildEpisodeBrief, .showSceneFrames, .describeScenes, .translateWithAI])
            Divider()
            buttons(for: .ai, only: [.clearTranslation, .clearTranscript])
            Divider()
            buttons(for: .ai, only: [.reviewScriptWithAI, .reviewScriptFindings])
            buttons(for: .ai, only: [.reviewWords, .confirmRemainingWords])
            buttons(for: .ai, only: [.reviewChoices, .acceptRemainingChoices])
            Divider()
            buttons(for: .ai, only: [.maskProfanity, .removeHearingImpaired, .fixPunctuation])
            Divider()
            buttons(for: .ai, only: [.acceptChange, .rejectChange, .acceptAllChanges, .rejectAllChanges])
            Divider()
            buttons(for: .ai, only: [.cancelAITask])
        }
        CommandMenu("Playback") {
            buttons(for: .playback, only: [.togglePlay, .shuttleBackward, .pause, .shuttleForward])
            Divider()
            buttons(for: .playback, only: [.stepBackward, .stepForward, .goToStart, .goToEnd])
            Divider()
            buttons(for: .playback, only: [.previousShotChange, .nextShotChange])
            Divider()
            buttons(for: .playback, only: [.nextAudioTrack])
            AudioTrackPicker(editor: editor)
                .disabled(editor.audioTracks.isEmpty)
        }
    }

    /// The category's commands, or only those in `only` (to split a menu into sections).
    private func buttons(for category: EditorCommand.Category, only: [EditorCommand]? = nil) -> some View {
        ForEach(EditorCommand.all.filter { $0.category == category && (only?.contains($0) ?? true) }) { command in
            Group {
                if let isOn = editor.isOn(command) {
                    Toggle(editor.title(of: command), isOn: Binding(get: { isOn }, set: { _ in editor.perform(command) }))
                } else {
                    Button(editor.title(of: command)) { editor.perform(command) }
                }
            }
            .keyboardShortcut(command.defaultShortcut?.keyboardShortcut)
            .disabled(!editor.isShortcutEnabled(for: command))
        }
    }
}

/// File › Open Recent: projects opened lately.
struct OpenRecentMenu: View {
    let workspace: EditorWorkspace

    var body: some View {
        Menu("Open Recent") {
            ForEach(workspace.recentProjects, id: \.self) { url in
                Button(url.deletingPathExtension().lastPathComponent) { workspace.openProject(at: url) }
            }
            if !workspace.recentProjects.isEmpty { Divider() }
            Button("Clear Menu") { workspace.clearRecentProjects() }
                .disabled(workspace.recentProjects.isEmpty)
        }
    }
}

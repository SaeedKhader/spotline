import EditorCommands
import QualityControl
import SpotlineAccessibility
import SubtitleCore
import SubtitleTranslation
import SwiftUI

/// The editor window. Top: the cue list (each row edits its cue) on the left,
/// the video with the transport under it, and the review sidebar on the right
/// (toggled from the title bar). Bottom: the
/// editing actions, the mini-map of the whole media and the timeline. The
/// title bar shows what a running AI tool is doing.
public struct MainWindowView: View {
    let editor: EditorState

    public init(editor: EditorState) {
        self.editor = editor
    }

    public var body: some View {
        VSplitView {
            HSplitView {
                // Translation mode shows source and target side by side.
                CueEditorList(editor: editor)
                    .frame(minWidth: editor.isTranslating ? 520 : 380, idealWidth: editor.isTranslating ? 820 : 560)
                VStack(spacing: 0) {
                    VideoSurfaceView(editor: editor)
                    Divider()
                    TransportBar(editor: editor)
                }
                .frame(minWidth: 320, minHeight: 240)
                if editor.isReviewSidebarVisible {
                    ReviewSidebar(editor: editor)
                        .frame(minWidth: 280, idealWidth: 330, maxWidth: 480)
                        .clipped()
                }
            }
            .frame(minHeight: 280)
            VStack(spacing: 0) {
                ActionsBar(editor: editor)
                Divider()
                MiniMapView(editor: editor)
                    .frame(height: 30)
                Divider()
                TimelineHost(editor: editor)
                    .frame(minHeight: 90)
            }
            .frame(minHeight: 170, idealHeight: 220)
        }
        .frame(minWidth: 960, minHeight: 600)
        .sheet(isPresented: Binding(
            get: { editor.isEmbeddedSubtitlesSheetShown },
            set: { if !$0 { editor.dismissEmbeddedSubtitles() } }
        )) {
            EmbeddedSubtitlesSheet(editor: editor)
        }
        .sheet(isPresented: Binding(
            get: { editor.isBriefSheetShown },
            set: { if !$0 { editor.dismissEpisodeBrief() } }
        )) {
            EpisodeBriefSheet(editor: editor)
        }
        .transaction { transaction in
            if editor.launchOptions.isUITestMode { transaction.disablesAnimations = true }
        }
    }
}

/// The timeline, in its own view so the playhead redraws only it.
struct TimelineHost: View {
    let editor: EditorState

    var body: some View {
        TimelineRepresentable(editor: editor, content: editor.timelineContent)
    }
}

/// The player's video, or a hint to open media when nothing is loaded.
struct VideoSurfaceView: View {
    let editor: EditorState

    var body: some View {
        ZStack {
            Color.black
            if let videoView = editor.playback.videoView() {
                HostedVideoView(view: videoView)
            }
            SubtitleOverlayHost(editor: editor)
            // A click on the picture ends typing in the cue list; the cue stays selected.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil) }
                .accessibilityHidden(true)
            if !editor.hasMedia {
                // A project whose video was moved: opening it again relinks the project.
                let missing = editor.missingMediaName
                let hint = missing == nil
                    ? "Drop a video here (\(EditorCommand.openMedia.menuHint("File")))"
                    : "Drop it here to relink the project (\(EditorCommand.openMedia.menuHint("File")))"
                VStack(spacing: 10) {
                    Image(systemName: missing == nil ? "film" : "questionmark.video")
                        .font(.largeTitle)
                    Text(missing.map { "“\($0)” Not Found" } ?? "No Media")
                        .font(.title3)
                    Text(hint)
                        .font(.callout)
                }
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityValue(hint)
                .accessibilityIdentifier(AccessibilityID.Video.emptyState)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: \.isFileURL) else { return false }
            editor.open(url)
            return true
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Video.surface)
    }
}

/// Shows the engine's video view. The engine owns the view and returns the same
/// one every time, because libmpv allows one render context per player.
struct HostedVideoView: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// A button that runs an editor command and is findable by its command ID:
/// a borderless icon when given `systemImage`, else a titled button.
struct CommandButton: View {
    let command: EditorCommand
    var systemImage: String?
    let editor: EditorState

    var body: some View {
        Group {
            if let systemImage {
                Button {
                    editor.perform(command)
                } label: {
                    Label(command.title, systemImage: systemImage)
                        .labelStyle(.iconOnly)
                        .foregroundStyle(editor.isOn(command) == true ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                }
                .buttonStyle(.borderless)
            } else {
                Button(command.title) { editor.perform(command) }
            }
        }
        .help(command.title)
        .disabled(!editor.canPerform(command))
        .accessibilityIdentifier(AccessibilityID.command(command.id))
    }
}

/// Shows the cues at the playhead, in its own view so only it redraws as the video plays.
struct SubtitleOverlayHost: View {
    let editor: EditorState

    var body: some View {
        ForEach(editor.cuesAtPlayhead) { cue in
            SubtitleOverlay(cue: cue)
        }
    }
}

/// The cue under the playhead as a delivery would show it: white text with a
/// thin black outline, centered inside the title-safe area (90% of the
/// picture), at the bottom or top.
struct SubtitleOverlay: View {
    let cue: Cue

    var body: some View {
        let lines = SubtitleText.visibleLines(of: cue.text)
        let text = lines.joined(separator: "\n")
        // Dialogue lines line up on their dashes: a block aligned to the start
        // of the text's direction (right for Arabic), centred as a whole.
        let isDialogue = SubtitleText.isDialogue(lines)
        let direction: LayoutDirection = TextDirection.of(text: text) == .rightToLeft ? .rightToLeft : .leftToRight
        GeometryReader { geometry in
            let margin = geometry.size.height * 0.05
            VStack {
                if cue.position == .bottom { Spacer() }
                if !text.isEmpty {
                    Text(text)
                        .font(.system(size: max(12, geometry.size.height * 0.055), weight: .medium))
                        .multilineTextAlignment(isDialogue ? .leading : .center)
                        .environment(\.layoutDirection, direction)
                        .foregroundStyle(.white)
                        // A one-point outline from four offset shadows, plus a soft drop shadow.
                        .shadow(color: .black, radius: 0, x: 1, y: 1)
                        .shadow(color: .black, radius: 0, x: -1, y: -1)
                        .shadow(color: .black, radius: 0, x: 1, y: -1)
                        .shadow(color: .black, radius: 0, x: -1, y: 1)
                        .shadow(color: .black.opacity(0.6), radius: 3)
                        .padding(.horizontal, geometry.size.width * 0.05)
                        .padding(cue.position == .bottom ? .bottom : .top, margin)
                        .accessibilityLabel("Subtitle")
                        .accessibilityValue(text)
                        .accessibilityIdentifier(cue.position == .top ? AccessibilityID.Video.topSubtitle : AccessibilityID.Video.subtitle)
                }
                if cue.position == .top { Spacer() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .allowsHitTesting(false)
    }
}

/// Chooses the audio track to play and draw, in the Playback menu.
struct AudioTrackPicker: View {
    let editor: EditorState

    var body: some View {
        Picker("Audio Track", selection: Binding(
            get: { editor.selectedAudioTrackID },
            set: { id in if let id { editor.selectAudioTrack(id: id) } }
        )) {
            ForEach(editor.audioTracks) { track in
                Text(track.displayName).tag(Optional(track.id))
            }
        }
    }
}

/// Chooses the QC preset cues are checked against, in the Review menu.
struct QCPresetPicker: View {
    let editor: EditorState

    var body: some View {
        Picker("QC Preset", selection: Binding(
            get: { editor.qcPreset.id },
            set: { editor.selectQCPreset(id: $0) }
        )) {
            ForEach(QCPreset.all) { preset in
                Text(preset.name).tag(preset.id)
            }
        }
    }
}

/// Chooses the language the translation is in, in the Translation menu.
struct TargetLanguagePicker: View {
    let editor: EditorState

    var body: some View {
        Picker("Target Language", selection: Binding(
            get: { editor.track.languageCode },
            set: { editor.setTargetLanguage($0) }
        )) {
            ForEach(editor.targetLanguageChoices, id: \.self) { code in
                Text(EditorState.languageName(code)).tag(code)
            }
        }
    }
}

/// Media analysis progress, then the number of shot changes found.
struct AnalysisStatusView: View {
    let editor: EditorState

    private func percent(_ job: AnalysisJob) -> String {
        "\(Int((job.fraction * 100).rounded()))%"
    }

    var body: some View {
        let found = editor.shotChanges.map { $0.count == 1 ? "1 shot change" : "\($0.count) shot changes" }
        let text: String? = if let job = editor.waveformJob {
            "Reading audio \(percent(job))"
        } else if let job = editor.speechJob {
            "Detecting speech \(percent(job))"
        } else if let job = editor.shotChangesJob {
            "Finding shot changes \(percent(job))" + (editor.shotChanges.map { " · \($0.count) so far" } ?? "")
        } else {
            found
        }
        if let text {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityLabel("Media analysis")
                .accessibilityValue(text)
                .accessibilityIdentifier(AccessibilityID.Transport.analysis)
        }
    }
}

extension EditorState {
    /// Cues with something for the user to check: QC issues and words the transcriber was unsure of.
    var attentionCueIDs: Set<Cue.ID> {
        Set(issues.keys).union(track.cues.lazy.filter { $0.unsureWords?.isEmpty == false }.map(\.id))
    }

    /// Cues with an AI suggestion to decide: a proposed change or a translation choice.
    var suggestionCueIDs: Set<Cue.ID> {
        Set(pendingReview?.changes.map(\.cueID) ?? []).union(track.cues.lazy.filter { $0.flag?.isResolved == false }.map(\.id))
    }

    var timelineContent: TimelineContent {
        TimelineContent(
            cues: track.cues,
            selectedCueID: selectedCueID,
            playhead: currentTime,
            hasMedia: hasMedia,
            duration: status.duration,
            frameRate: frameRate,
            shotChanges: shotChangeFrames,
            waveform: audioAnalysis?.waveform,
            speech: isSpeechHighlighted ? speech : nil,
            speechAnalyzedUntil: speechJob?.analyzedUntil,
            analyzedUntil: analyzedUntil,
            attentionCueIDs: attentionCueIDs,
            suggestionCueIDs: suggestionCueIDs,
            scale: timelineScale,
            scrollRequest: timelineScrollRequest
        )
    }
}

import EditorCommands
import SpotlineAccessibility
import SubtitleCore
import SwiftUI

/// The editor window: video and inspector on top, transport, timeline and cue list below.
public struct MainWindowView: View {
    let editor: EditorState

    public init(editor: EditorState) {
        self.editor = editor
    }

    public var body: some View {
        VSplitView {
            HSplitView {
                VideoSurfaceView(editor: editor)
                    .frame(minWidth: 480, minHeight: 270)
                InspectorView(editor: editor)
                    .frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
            }
            VStack(spacing: 0) {
                TransportBar(editor: editor)
                Divider()
                TimelineRepresentable(editor: editor, content: editor.timelineContent)
                    .frame(height: 110)
                Divider()
                CueListView(editor: editor)
            }
            .frame(minHeight: 240)
        }
        .frame(minWidth: 960, minHeight: 640)
        .transaction { transaction in
            if editor.launchOptions.isUITestMode { transaction.disablesAnimations = true }
        }
    }
}

/// The player's video, or a prompt to open media when nothing is loaded.
struct VideoSurfaceView: View {
    let editor: EditorState

    var body: some View {
        ZStack {
            Color.black
            if let videoView = editor.playback.videoView() {
                HostedVideoView(view: videoView)
            }
            if let cue = editor.cueAtPlayhead {
                SubtitleOverlay(cue: cue)
            }
            if !editor.hasMedia {
                VStack(spacing: 12) {
                    Image(systemName: "film")
                        .font(.largeTitle)
                    Text("No Media")
                    Button(EditorCommand.openMedia.title) { editor.perform(.openMedia) }
                        .accessibilityIdentifier(AccessibilityID.command(EditorCommand.openMedia.id))
                }
                .foregroundStyle(.secondary)
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

struct TransportBar: View {
    let editor: EditorState

    var body: some View {
        HStack(spacing: 12) {
            CommandButton(command: .stepBackward, systemImage: "backward.frame", editor: editor)
            CommandButton(
                command: .togglePlay,
                systemImage: editor.isPlaying ? "pause.fill" : "play.fill",
                editor: editor
            )
            CommandButton(command: .stepForward, systemImage: "forward.frame", editor: editor)
            Spacer()
            AnalysisStatusView(editor: editor)
            if !editor.audioTracks.isEmpty {
                AudioTrackPicker(editor: editor)
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .help("Audio track")
                    .accessibilityValue(editor.selectedAudioTrack?.displayName ?? "None")
                    .accessibilityIdentifier(AccessibilityID.Transport.audioTrack)
            }
            Text(editor.timecode.description)
                .font(.system(.title3, design: .monospaced))
                .accessibilityLabel("Timecode")
                .accessibilityValue(editor.timecode.description)
                .accessibilityIdentifier(AccessibilityID.Transport.timecode)
            Text(editor.frameRate.description)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Frame rate")
                .accessibilityValue(editor.frameRate.description)
                .accessibilityIdentifier(AccessibilityID.Transport.frameRate)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Transport.root)
    }
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

/// The cue under the playhead, drawn over the bottom of the video.
struct SubtitleOverlay: View {
    let cue: Cue

    var body: some View {
        let text = SubtitleText.visibleLines(of: cue.text).joined(separator: "\n")
        GeometryReader { geometry in
            VStack {
                Spacer()
                if !text.isEmpty {
                    Text(text)
                        .font(.system(size: max(12, geometry.size.height * 0.05), weight: .medium))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .shadow(color: .black, radius: 2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 4))
                        .padding(.bottom, geometry.size.height * 0.06)
                        .accessibilityLabel("Subtitle")
                        .accessibilityValue(text)
                        .accessibilityIdentifier(AccessibilityID.Video.subtitle)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .allowsHitTesting(false)
    }
}

/// Chooses the audio track to play and draw. Used in the transport bar and the Playback menu.
struct AudioTrackPicker: View {
    let editor: EditorState

    var body: some View {
        Picker("Audio Track", selection: Binding(
            get: { editor.status.selectedAudioTrackID },
            set: { id in if let id { editor.selectAudioTrack(id: id) } }
        )) {
            ForEach(editor.audioTracks) { track in
                Text(track.displayName).tag(Optional(track.id))
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
            analyzedUntil: analyzedUntil,
            scale: timelineScale
        )
    }
}

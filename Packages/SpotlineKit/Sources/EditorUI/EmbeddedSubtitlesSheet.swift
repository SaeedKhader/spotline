import MediaAnalysis
import SpotlineAccessibility
import SwiftUI

/// Offers the subtitle tracks muxed into the media: pick one to import as the
/// working cues, optionally saving a copy. Image-based tracks are listed but
/// cannot be picked.
struct EmbeddedSubtitlesSheet: View {
    let editor: EditorState
    @State private var selection: Int?
    @State private var savesCopy = false

    var body: some View {
        let tracks = editor.embeddedSubtitles
        let isReading = editor.embeddedSubtitlesJob != nil
        VStack(alignment: .leading, spacing: 14) {
            Text("Import Embedded Subtitles?")
                .font(.headline)
            Text(explanation(trackCount: tracks.count))
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(tracks) { track in
                    TrackRow(track: track, isSelected: selection == track.streamIndex) {
                        selection = track.streamIndex
                    }
                }
            }
            .disabled(isReading)
            Toggle("Also save a copy as a subtitle file", isOn: $savesCopy)
                .disabled(isReading || selection == nil)
                .accessibilityIdentifier(AccessibilityID.EmbeddedSubtitles.saveCopy)
            if let job = editor.embeddedSubtitlesJob {
                ProgressView(value: job.fraction) {
                    Text("Reading subtitles…").font(.caption)
                }
                .accessibilityIdentifier(AccessibilityID.EmbeddedSubtitles.progress)
            }
            HStack {
                Spacer()
                Button(isReading ? "Cancel" : "Not Now") { editor.dismissEmbeddedSubtitles() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(AccessibilityID.EmbeddedSubtitles.cancelButton)
                Button("Import") {
                    if let selection { editor.importEmbeddedSubtitles(streamIndex: selection, savesCopy: savesCopy) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil || isReading)
                .accessibilityIdentifier(AccessibilityID.EmbeddedSubtitles.importButton)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            let text = tracks.filter(\.isText)
            selection = (text.first(where: \.isDefault) ?? text.first)?.streamIndex
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.EmbeddedSubtitles.sheet)
    }

    private func explanation(trackCount: Int) -> String {
        var text = trackCount == 1 ? "This video has a subtitle track." : "This video has \(trackCount) subtitle tracks."
        text += " Spotline shows only the cues you edit over the picture. Import a track to edit it."
        let cueCount = editor.track.cues.count
        if cueCount > 0 {
            text += " This replaces the current \(cueCount == 1 ? "cue" : "\(cueCount) cues"); you can undo it."
        }
        return text
    }

    /// A radio-style row: the track's name, and its format or why it cannot be imported.
    private struct TrackRow: View {
        let track: EmbeddedSubtitleTrack
        let isSelected: Bool
        let select: () -> Void

        var body: some View {
            Button(action: select) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.displayName)
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!track.isText)
            .accessibilityLabel(track.displayName)
            .accessibilityValue(detail)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityIdentifier(AccessibilityID.EmbeddedSubtitles.track(track.streamIndex))
        }

        private var detail: String {
            guard track.isText else { return "\(track.formatName) · Image-based, can’t be imported as text" }
            return track.isDefault ? "\(track.formatName) · Default" : track.formatName
        }
    }
}

import MediaAnalysis
import SpotlineAccessibility
import SwiftUI

/// Offers the subtitle tracks muxed into the media: pick one to import as the
/// working cues, optionally saving a copy. Image-based tracks cannot be
/// picked; they are summed up in one line, since Blu-ray remuxes carry dozens.
struct EmbeddedSubtitlesSheet: View {
    let editor: EditorState
    @State private var selection: Int?
    @State private var savesCopy = false

    var body: some View {
        let tracks = editor.embeddedSubtitles
        let textTracks = tracks.filter(\.isText)
        let imageTracks = tracks.filter { !$0.isText }
        let isReading = editor.embeddedSubtitlesJob != nil
        VStack(alignment: .leading, spacing: 14) {
            Text(textTracks.isEmpty ? "Embedded Subtitles" : "Import Embedded Subtitles?")
                .font(.headline)
            Text(explanation(trackCount: tracks.count))
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
            if !textTracks.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(textTracks) { track in
                            TrackRow(track: track, isSelected: selection == track.streamIndex) {
                                selection = track.streamIndex
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 280)
                .fixedSize(horizontal: false, vertical: textTracks.count <= 6)
                .disabled(isReading)
            }
            if !imageTracks.isEmpty {
                Label(imageSummary(imageTracks), systemImage: "photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(imageTracks.map(\.displayName).joined(separator: "\n"))
                    .accessibilityIdentifier(AccessibilityID.EmbeddedSubtitles.imageTracks)
            }
            if !textTracks.isEmpty {
                Toggle("Also save a copy as a subtitle file", isOn: $savesCopy)
                    .disabled(isReading || selection == nil)
                    .accessibilityIdentifier(AccessibilityID.EmbeddedSubtitles.saveCopy)
            }
            if let job = editor.embeddedSubtitlesJob {
                ProgressView(value: job.fraction) {
                    Text("Reading subtitles…").font(.caption)
                }
                .accessibilityIdentifier(AccessibilityID.EmbeddedSubtitles.progress)
            }
            HStack {
                Spacer()
                Button(isReading ? "Cancel" : textTracks.isEmpty ? "OK" : "Not Now") { editor.dismissEmbeddedSubtitles() }
                    .keyboardShortcut(textTracks.isEmpty ? .defaultAction : .cancelAction)
                    .accessibilityIdentifier(AccessibilityID.EmbeddedSubtitles.cancelButton)
                if !textTracks.isEmpty {
                    Button("Import") {
                        if let selection { editor.importEmbeddedSubtitles(streamIndex: selection, savesCopy: savesCopy) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil || isReading)
                    .accessibilityIdentifier(AccessibilityID.EmbeddedSubtitles.importButton)
                }
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
        text += " Spotline shows only the cues you edit over the picture."
        guard editor.embeddedSubtitles.contains(where: \.isText) else { return text }
        text += " Import a track to edit it."
        let cueCount = editor.track.cues.count
        if cueCount > 0 {
            text += " This replaces the current \(cueCount == 1 ? "cue" : "\(cueCount) cues"); you can undo it."
        }
        return text
    }

    /// E.g. "28 image-based tracks (PGS) can’t be imported as text: English, French, …".
    private func imageSummary(_ tracks: [EmbeddedSubtitleTrack]) -> String {
        var formats: [String] = []
        for track in tracks where !formats.contains(track.formatName) { formats.append(track.formatName) }
        let count = tracks.count == 1 ? "1 image-based track" : "\(tracks.count) image-based tracks"
        var names: [String] = []
        for track in tracks where !names.contains(track.displayName) { names.append(track.displayName) }
        let listed = names.prefix(6).joined(separator: ", ") + (names.count > 6 ? ", and \(names.count - 6) more" : "")
        return "\(count) (\(formats.joined(separator: ", "))) can’t be imported as text: \(listed)."
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
            .accessibilityLabel(track.displayName)
            .accessibilityValue(detail)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityIdentifier(AccessibilityID.EmbeddedSubtitles.track(track.streamIndex))
        }

        private var detail: String {
             track.isDefault ? "\(track.formatName) · Default" : track.formatName
        }
    }
}

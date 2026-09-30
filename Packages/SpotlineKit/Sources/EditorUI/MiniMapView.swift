import QualityControl
import SpotlineAccessibility
import SubtitleCore
import SwiftUI

/// The whole media at a glance: speech, cues (grey; the selected one in the
/// accent colour, a dot of colour where there is something to review), shot
/// changes, the playhead and a box for the part the timeline shows.
/// Click or drag to go there (with no media, to show it in the timeline).
struct MiniMapView: View {
    let editor: EditorState

    var body: some View {
        GeometryReader { geometry in
            let duration = totalSeconds
            ZStack {
                MiniMapContent(editor: editor, duration: duration)
                MiniMapOverlay(editor: editor, duration: duration)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let fraction = min(max(drag.location.x / max(geometry.size.width, 1), 0), 1)
                if editor.hasMedia {
                    editor.seek(toFrame: MediaTime(seconds: fraction * duration).nearestFrame(at: editor.frameRate))
                } else {
                    editor.scrollTimeline(toCenter: fraction * duration)
                }
            })
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Overview")
        .accessibilityValue(accessibilitySummary)
        .accessibilityIdentifier(AccessibilityID.MiniMap.root)
    }

    /// The media's length, or the last cue's end when no media is open.
    private var totalSeconds: Double {
        max(editor.status.duration?.seconds ?? 0, editor.track.cues.map(\.end.seconds).max() ?? 0, 1)
    }

    private var accessibilitySummary: String {
        let viewport = editor.timelineViewport
        return "Showing \(Timestamp.format(MediaTime(seconds: viewport.lowerBound))) to \(Timestamp.format(MediaTime(seconds: viewport.upperBound)))"
    }
}

/// Speech, cues and shot changes; redraws only when they change.
private struct MiniMapContent: View {
    let editor: EditorState
    let duration: Double

    var body: some View {
        let cues = editor.track.cues
        let issues = editor.issues
        let suggestions = editor.suggestionCueIDs
        let selected = editor.selectedCueID
        let speech = editor.isSpeechHighlighted ? editor.speech ?? [] : []
        let shots = editor.shotChanges ?? []
        Canvas { context, size in
            func x(_ seconds: Double) -> CGFloat { CGFloat(seconds / duration) * size.width }
            for region in speech {
                let rect = CGRect(x: x(region.start.seconds), y: 0, width: max(x(region.end.seconds) - x(region.start.seconds), 1), height: size.height)
                context.fill(Path(rect), with: .color(.primary.opacity(0.07)))
            }
            for shot in shots {
                context.fill(Path(CGRect(x: x(shot.seconds), y: size.height * 0.15, width: 1, height: size.height * 0.2)), with: .color(.secondary.opacity(0.6)))
            }
            for cue in cues {
                let rect = CGRect(
                    x: x(cue.start.seconds), y: size.height * 0.45,
                    width: max(x(cue.end.seconds) - x(cue.start.seconds), 1.5), height: size.height * 0.4
                )
                let color: Color = if cue.id == selected {
                    .accentColor
                } else {
                    switch issues[cue.id]?.map(\.severity).max() {
                    case .error: .errorTint
                    case .warning: .attentionTint
                    case nil where cue.unsureWords?.isEmpty == false: .attentionTint
                    case nil where suggestions.contains(cue.id): .aiTint
                    case nil: .secondary.opacity(0.45)
                    }
                }
                context.fill(Path(rect), with: .color(color))
            }
        }
    }
}

/// The playhead and the timeline's visible span.
private struct MiniMapOverlay: View {
    let editor: EditorState
    let duration: Double

    var body: some View {
        let viewport = editor.timelineViewport
        let playhead = editor.hasMedia ? editor.currentTime.seconds : nil
        Canvas { context, size in
            func x(_ seconds: Double) -> CGFloat { CGFloat(seconds / duration) * size.width }
            let box = CGRect(x: x(viewport.lowerBound), y: 1, width: max(x(viewport.upperBound) - x(viewport.lowerBound), 3), height: size.height - 2)
            context.fill(Path(roundedRect: box, cornerRadius: 3), with: .color(.primary.opacity(0.07)))
            context.stroke(Path(roundedRect: box, cornerRadius: 3), with: .color(.primary.opacity(0.5)), lineWidth: 1)
            if let playhead {
                context.fill(Path(CGRect(x: x(playhead) - 0.5, y: 0, width: 1.5, height: size.height)), with: .color(.primary))
            }
        }
        .allowsHitTesting(false)
    }
}

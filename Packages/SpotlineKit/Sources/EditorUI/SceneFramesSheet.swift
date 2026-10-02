import MediaAnalysis
import SpotlineAccessibility
import SubtitleCore
import SwiftUI

/// The frames picked for each scene (AI › Scene Frames…): while they are read, how
/// far that has got; then one row a scene with the frames kept, each with its time,
/// the faces found in it, how many lines are spoken over its camera setup and how
/// many similar frames it stands for. A frame shows in the video when clicked. A
/// scene opens to show its lines and the frames left out, to judge the picking.
struct SceneFramesSheet: View {
    let editor: EditorState
    @State private var opened: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let job = editor.sceneFramesJob {
                ProgressView(value: job.fraction) {
                    Text("Reading frames from the video…").font(.caption)
                }
                .accessibilityValue("\(Int(job.fraction * 100)) percent")
                .accessibilityIdentifier(AccessibilityID.SceneFrames.progress)
            } else if let scenes = editor.sceneFrames {
                Text(summary(scenes))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AccessibilityID.SceneFrames.summary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(Array(scenes.enumerated()), id: \.element.id) { index, scene in
                            sceneRow(scene, number: index + 1)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(minHeight: 240, maxHeight: 560)
            }
            footer
        }
        .padding(20)
        .frame(width: 940)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.SceneFrames.sheet)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Scene Frames").font(.headline)
            Text("The frames that would show a vision model who is in each scene. They are picked on this Mac and nothing is sent anywhere: frames are read while the lines are spoken, grouped into scenes, and the many frames of one camera setup become one.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            CommandButton(command: .pickSceneFramesAgain, editor: editor)
            CommandButton(command: .exportSceneFrames, editor: editor)
            Spacer()
            Button("Done") { editor.dismissSceneFrames() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier(AccessibilityID.SceneFrames.doneButton)
        }
    }

    private func summary(_ scenes: [SceneFramePicker.Scene]) -> String {
        let kept = scenes.reduce(0) { $0 + $1.picks.count }
        let read = scenes.reduce(0) { $0 + $1.frameCount }
        guard !scenes.isEmpty else { return "No scenes with lines were found." }
        return "\(Self.count(scenes.count, "scene")), \(Self.count(kept, "frame")) kept of \(read) read."
    }

    static func count(_ number: Int, _ noun: String) -> String {
        number == 1 ? "1 \(noun)" : "\(number) \(noun)s"
    }

    private func sceneRow(_ scene: SceneFramePicker.Scene, number: Int) -> some View {
        let lineCount = scene.lines.count
        let title = "Scene \(number) · \(editor.timecode(scene.start)) – \(editor.timecode(scene.end)) · \(Self.count(lineCount, "line"))"
        let isOpen = opened.contains(scene.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.subheadline.weight(.semibold))
                Text("\(Self.count(scene.frameCount, "frame")) read, \(Self.count(scene.setupCount, "camera setup")), \(scene.picks.count) kept")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(isOpen ? "Hide Details" : "Lines and Frames Left Out") {
                    if isOpen { opened.remove(scene.id) } else { opened.insert(scene.id) }
                }
                .buttonStyle(.link)
                .font(.caption)
                .accessibilityIdentifier(AccessibilityID.SceneFrames.details(number))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 290), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                ForEach(Array(scene.picks.enumerated()), id: \.element.id) { order, pick in
                    PickView(editor: editor, pick: pick, showsAlike: isOpen)
                        .accessibilityIdentifier(AccessibilityID.SceneFrames.frame(number, order + 1))
                }
            }
            if isOpen {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(editor.sceneFrameCues(scene.lines)) { cue in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(editor.timecode(cue.start)).monospacedDigit().foregroundStyle(.secondary)
                            if let voice = cue.speaker ?? cue.voices?.first {
                                Text(voice).foregroundStyle(.secondary)
                            }
                            Text(SubtitleText.visibleLines(of: cue.text).joined(separator: " "))
                        }
                        .font(.caption)
                    }
                }
                .padding(.top, 2)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityIdentifier(AccessibilityID.SceneFrames.scene(number))
    }
}

/// One kept frame with why it was kept and, when the scene is opened, the similar frames it stands for.
private struct PickView: View {
    let editor: EditorState
    let pick: SceneFramePicker.Pick
    let showsAlike: Bool

    private var reason: String {
        var parts: [String] = []
        if pick.isWidest { parts.append("Widest view") }
        parts.append(pick.frame.faces.isEmpty ? "no faces" : SceneFramesSheet.count(pick.frame.faces.count, "face"))
        parts.append(SceneFramesSheet.count(pick.lines.count, "line"))
        if !pick.alike.isEmpty { parts.append("\(pick.alike.count) similar left out") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                editor.showSceneFrame(at: pick.frame.time)
            } label: {
                FrameImage(frame: pick.frame, showsFaces: true)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(pick.isWidest ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), lineWidth: pick.isWidest ? 2 : 1))
            }
            .buttonStyle(.plain)
            .help("Show this frame in the video")
            .accessibilityLabel("Frame at \(editor.timecode(pick.frame.time))")
            .accessibilityValue(reason)
            Text(editor.timecode(pick.frame.time)).font(.caption.monospacedDigit())
            Text(reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if showsAlike, !pick.alike.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 62, maximum: 80), spacing: 3)], alignment: .leading, spacing: 3) {
                    ForEach(pick.alike) { frame in
                        FrameImage(frame: frame, showsFaces: false)
                            .help(editor.timecode(frame.time))
                    }
                }
            }
        }
    }
}

/// A frame's picture, with the faces found in it outlined.
private struct FrameImage: View {
    let frame: SceneFramePicker.Frame
    let showsFaces: Bool

    var body: some View {
        let aspect = frame.height > 0 ? CGFloat(frame.width) / CGFloat(frame.height) : 16 / 9
        Group {
            if let image = NSImage(data: frame.jpeg) {
                Image(nsImage: image).resizable()
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .overlay {
            if showsFaces {
                GeometryReader { geometry in
                    ForEach(Array(frame.faces.enumerated()), id: \.offset) { _, face in
                        Rectangle()
                            .strokeBorder(.yellow, lineWidth: 1)
                            .frame(width: face.width * geometry.size.width, height: face.height * geometry.size.height)
                            .offset(x: face.x * geometry.size.width, y: face.y * geometry.size.height)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

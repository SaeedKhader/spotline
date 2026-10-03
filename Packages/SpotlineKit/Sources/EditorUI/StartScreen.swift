import AITools
import MediaAnalysis
import SpotlineAccessibility
import SubtitleCore
import SwiftUI
import UniformTypeIdentifiers

/// A new project window's start: recent projects and a drop area for a video, then which
/// subtitle to work from and whether to translate or just edit (`EditorState+Start`).
struct StartScreen: View {
    let editor: EditorState

    var body: some View {
        Group {
            switch editor.startPhase {
            case .chooseSubtitle: SubtitleQuestion(editor: editor)
            default: ChooseVideo(editor: editor)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Start.root)
    }
}

/// Recent projects on the left, the drop area in the middle.
private struct ChooseVideo: View {
    let editor: EditorState
    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            recents
                .frame(width: 280)
            Divider()
            VStack(spacing: 14) {
                Image(systemName: "film.stack").font(.system(size: 44)).foregroundStyle(.secondary)
                Text("Drop a video here").font(.title2.weight(.semibold))
                Text("With its subtitle file if you have one, or a Spotline project.")
                    .foregroundStyle(.secondary)
                Button("Open…") { editor.chooseStartVideo() }
                    .controlSize(.large)
                    .accessibilityIdentifier(AccessibilityID.Start.openButton)
            }
            .padding(48)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .foregroundStyle(isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityID.Start.dropArea)
        }
        .dropDestination(for: URL.self) { urls, _ in
            editor.dropOnStartScreen(urls)
            return true
        } isTargeted: { isTargeted = $0 }
    }

    private var recents: some View {
        let projects = EditorWorkspace.shared.recentProjects
        return VStack(alignment: .leading, spacing: 2) {
            Text("Recent").font(.headline).padding(.horizontal, 14).padding(.vertical, 10)
            if projects.isEmpty {
                Text("Projects you open show here.").font(.callout).foregroundStyle(.secondary).padding(.horizontal, 14)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(projects, id: \.self) { url in
                        Button { editor.openProjectFromStart?(url) } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(url.deletingPathExtension().lastPathComponent).lineLimit(2)
                                Text(url.deletingLastPathComponent().lastPathComponent).font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(AccessibilityID.Start.recent(url.lastPathComponent))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }
}

/// Which subtitle to work from, then Translate or Just Edit.
private struct SubtitleQuestion: View {
    let editor: EditorState
    /// The choice picked, nil to follow the recommendation (it comes in once the video's tracks are read).
    @State private var picked: StartSubtitle?
    /// With no subtitle found, Translate waits until a file is dropped or "Continue without one" is clicked.
    @State private var continuesWithout = false
    @State private var target = "ar"
    @State private var isTargeted = false

    private var choice: StartSubtitle? { picked ?? editor.recommendedStartSubtitle ?? (continuesWithout ? .transcribe : nil) }
    private var hasSubtitle: Bool { editor.recommendedStartSubtitle != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(editor.workTitle ?? editor.status.mediaURL?.deletingPathExtension().lastPathComponent ?? "Video")
                    .font(.title2.weight(.semibold))
                if let duration = editor.status.duration {
                    Text("\(Int(duration.seconds / 60)) min").foregroundStyle(.secondary)
                }
            }
            if hasSubtitle { found } else { dropZone }
            Divider()
            HStack {
                Button("Just Edit") { editor.finishStart(with: choice == .transcribe ? nil : choice, translatingTo: nil) }
                    .accessibilityIdentifier(AccessibilityID.Start.justEditButton)
                Spacer()
                Text("Translate to")
                Picker("Translate to", selection: $target) {
                    ForEach(editor.targetLanguageChoices.filter { $0 != "und" }, id: \.self) { Text(EditorState.languageName($0)).tag($0) }
                }
                .labelsHidden()
                .frame(width: 140)
                .accessibilityIdentifier(AccessibilityID.Start.targetLanguage)
                Button("Translate") { editor.finishStart(with: choice, translatingTo: target) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(choice == nil)
                    .accessibilityIdentifier(AccessibilityID.Start.translateButton)
            }
        }
        .padding(32)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            if let added = editor.dropOnStartScreen(urls) { picked = .file(added) }
            return true
        } isTargeted: { isTargeted = $0 }
        .onAppear { target = editor.defaultTargetLanguage(avoiding: editor.briefSourceLanguage) }
    }

    /// The video has a subtitle: use it (recommended), another, or transcribe.
    private var found: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(foundText).fixedSize(horizontal: false, vertical: true)
            ForEach(editor.startSubtitleChoices) { option in
                Button { picked = option.subtitle } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: choice == option.subtitle ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(choice == option.subtitle ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(option.title).fontWeight(option.subtitle == editor.recommendedStartSubtitle ? .semibold : .regular)
                            Text(option.subtitle == editor.recommendedStartSubtitle ? "Recommended · \(option.detail)" : option.detail)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 7).fill(choice == option.subtitle ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(.clear)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.Start.choice(String(describing: option.subtitle)))
            }
            Button("Choose Another File…") { if let added = editor.chooseStartSubtitleFile() { picked = .file(added) } }
                .buttonStyle(.link)
                .accessibilityIdentifier(AccessibilityID.Start.chooseFileButton)
        }
    }

    private var foundText: String {
        "This video has a subtitle. Working from it gives a better translation than transcribing the audio: its words, and the names in them, are already right."
    }

    /// The video has none: a drop area, and continuing without one.
    private var dropZone: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 8) {
                Text("Drop the subtitle for this video here").font(.headline)
                Text("A real subtitle gives a better translation: names and words come out right, and it costs less.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Choose a File…") { if let added = editor.chooseStartSubtitleFile() { picked = .file(added) } }
                    .accessibilityIdentifier(AccessibilityID.Start.chooseFileButton)
            }
            .padding(28)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .foregroundStyle(isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
            )
            Toggle(isOn: $continuesWithout) {
                Text("Continue without one: Spotline transcribes the audio. It can mishear names and quiet lines, and you get more lines to check.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)
            .accessibilityIdentifier(AccessibilityID.Start.continueWithout)
        }
    }
}

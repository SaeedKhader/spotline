import Foundation
import SubtitleCore
import Testing
@testable import MediaAnalysis

struct SceneFramesTests {
    typealias Picker = SceneFramePicker

    static func time(_ seconds: Double) -> MediaTime { MediaTime(seconds: seconds) }

    /// A frame that is `level` all over: frames of one level look alike, others do not.
    static func frame(_ id: Int, at seconds: Double, line: Int? = nil, level: UInt8, faces: Int = 1) -> Picker.Frame {
        let signature = FrameSignature(pixels: [UInt8](repeating: level, count: FrameSignature.width * FrameSignature.height * 3))
        let boxes = (0..<faces).map { _ in FaceBox(x: 0.4, y: 0.3, width: 0.1, height: 0.2) }
        return Picker.Frame(id: id, time: time(seconds), line: line, signature: signature, faces: boxes)
    }

    static func lines(_ count: Int, every seconds: Double = 2) -> [Picker.Line] {
        (0..<count).map { Picker.Line(start: time(Double($0) * seconds), end: time(Double($0) * seconds + 1.5)) }
    }

    // MARK: Where frames are read

    @Test func aShortLineGetsOneFrameAndALongOneTwo() {
        let lines = [Picker.Line(start: Self.time(10), end: Self.time(12)), Picker.Line(start: Self.time(20), end: Self.time(24))]
        let samples = Picker.samples(lines: lines, shotChanges: [])
        #expect(samples.map(\.line) == [0, 1, 1])
        #expect(samples.map { ($0.time.seconds * 10).rounded() / 10 } == [11, 21, 23])
    }

    @Test func shotChangesAroundTheLinesGetAFrameToo() {
        let lines = [Picker.Line(start: Self.time(100), end: Self.time(102))]
        // Far before, just before (the wide view of the room), during the line, just after, far after.
        let samples = Picker.samples(lines: lines, shotChanges: [50, 92, 100.5, 110, 200].map(Self.time))
        #expect(samples.filter { $0.line == nil }.map { $0.time.seconds } == [92.5, 110.5])
    }

    // MARK: Scenes

    @Test func aSceneGoesOnWhileItsSetupsComeBack() {
        // Two people in shot and reverse shot, then somewhere else.
        let frames = [
            Self.frame(0, at: 0, line: 0, level: 40), Self.frame(1, at: 2, line: 1, level: 120), Self.frame(2, at: 4, line: 2, level: 40),
            Self.frame(3, at: 6, line: 3, level: 120), Self.frame(4, at: 8, line: 4, level: 200), Self.frame(5, at: 10, line: 5, level: 240),
            Self.frame(6, at: 12, line: 6, level: 200),
        ]
        let scenes = Picker.scenes(frames: frames, lines: Self.lines(7))
        #expect(scenes.map(\.lines) == [0...3, 4...6])
        #expect(scenes.map(\.frameCount) == [4, 3])
        #expect(scenes.map(\.setupCount) == [2, 2])
        #expect(scenes[0].start == Self.time(0))
        #expect(scenes[0].end == Self.time(7.5))
    }

    @Test func aSetupSeenLongAgoDoesNotHoldASceneTogether() {
        var options = Picker.Options()
        options.linkSeconds = 30
        options.minimumSceneLines = 1
        let frames = [Self.frame(0, at: 0, line: 0, level: 40), Self.frame(1, at: 5, line: 1, level: 120), Self.frame(2, at: 100, line: 2, level: 40)]
        let lines = [0.0, 5, 100].map { Picker.Line(start: Self.time($0), end: Self.time($0 + 1)) }
        #expect(Picker.scenes(frames: frames, lines: lines, options: options).map(\.lines) == [0...0, 1...1, 2...2])
    }

    @Test func aStretchWithFewLinesJoinsTheSceneNextToIt() {
        // A cutaway with one line between two scenes, right after the first.
        let frames = [
            Self.frame(0, at: 0, line: 0, level: 40), Self.frame(1, at: 2, line: 1, level: 40), Self.frame(2, at: 4, line: 2, level: 40),
            Self.frame(3, at: 6, line: 3, level: 120),
            Self.frame(4, at: 30, line: 4, level: 200), Self.frame(5, at: 32, line: 5, level: 200), Self.frame(6, at: 34, line: 6, level: 200),
        ]
        let lines = [0.0, 2, 4, 6, 30, 32, 34].map { Picker.Line(start: Self.time($0), end: Self.time($0 + 1)) }
        #expect(Picker.scenes(frames: frames, lines: lines).map(\.lines) == [0...3, 4...6])
    }

    @Test func stretchesWithoutLinesAndFadesGiveNoScene() {
        let frames = [
            Self.frame(0, at: 0, level: 40), Self.frame(1, at: 100, line: 0, level: 120), Self.frame(2, at: 102, line: 1, level: 120),
            Self.frame(3, at: 104, line: 2, level: 120), Self.frame(4, at: 106, line: 3, level: 1),
        ]
        let lines = [100.0, 102, 104, 106].map { Picker.Line(start: Self.time($0), end: Self.time($0 + 1)) }
        let scenes = Picker.scenes(frames: frames, lines: lines)
        #expect(scenes.map(\.lines) == [0...2])
        #expect(scenes[0].frameCount == 3, "The black frame is not counted")
    }

    // MARK: Picks

    @Test func oneFramePerSetupWithTheOthersLeftOut() {
        let frames = [
            Self.frame(0, at: 0, line: 0, level: 40), Self.frame(1, at: 2, line: 1, level: 120), Self.frame(2, at: 4, line: 2, level: 40),
            Self.frame(3, at: 6, line: 3, level: 40), Self.frame(4, at: 8, line: 4, level: 120),
        ]
        let scene = Picker.scenes(frames: frames, lines: Self.lines(5))[0]
        #expect(scene.picks.count == 2)
        #expect(scene.picks.map(\.lines) == [[0, 2, 3], [1, 4]])
        #expect(scene.picks.map { $0.alike.map(\.id) }.map { $0.count } == [2, 1])
        #expect(scene.picks.allSatisfy { !$0.isWidest }, "Nobody is shown with someone else")
    }

    @Test func theFrameWithTheMostFacesStandsForItsSetupAndTheWidestViewIsKept() {
        let frames = [
            Self.frame(0, at: 0, line: 0, level: 40, faces: 1), Self.frame(1, at: 2, line: 1, level: 40, faces: 2),
            Self.frame(2, at: 4, line: 2, level: 100, faces: 1), Self.frame(3, at: 6, line: 3, level: 40, faces: 1),
            // The room, shown once, with nobody speaking over it.
            Self.frame(4, at: 7, level: 200, faces: 4), Self.frame(5, at: 8, line: 4, level: 100, faces: 1),
        ]
        var options = Picker.Options()
        options.maxFramesPerScene = 2
        let scene = Picker.scenes(frames: frames, lines: Self.lines(5), options: options)[0]
        #expect(scene.picks.map(\.frame.id) == [1, 4])
        #expect(scene.picks.map(\.isWidest) == [false, true])
        #expect(scene.picks[0].lines == [0, 1, 2, 3, 4], "The setup left out counts with the kept one it looks most like")
    }

    @Test func aLongerSceneGetsMoreFrames() {
        let options = Picker.Options()
        #expect(Picker.budget(lines: 1, options: options) == 2)
        #expect(Picker.budget(lines: 9, options: options) == 4)
        #expect(Picker.budget(lines: 25, options: options) == 6)
        #expect(Picker.budget(lines: 400, options: options) == options.maxFramesPerScene)
    }

    @Test func inADarkSceneCloserFramesStillCountAsDifferentSetups() {
        // Levels 10, 16 and 22: alike by the usual measure, but this scene's frames are all that close.
        let levels: [UInt8] = [10, 16, 22, 10, 16, 22]
        let frames = levels.enumerated().map { Self.frame($0.offset, at: Double($0.offset) * 2, line: $0.offset, level: $0.element) }
        let scene = Picker.scenes(frames: frames, lines: Self.lines(6))[0]
        #expect(scene.setupCount == 3)
    }

    // MARK: Reading frames

    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../../Fixtures").standardizedFileURL

    /// cuts-25.mp4: 4 s at 25 fps with cuts at frames 40 and 75.
    @Test func readsTheFramesAskedFor() throws {
        var options = MediaAnalyzer.FrameOptions()
        options.longEdge = 160
        let times = [3.2, 0.5, 2.0, 0.6, 60].map(Self.time)
        let frames = try MediaAnalyzer.frames(in: Self.fixtures.appending(path: "cuts-25.mp4"), at: times, options: options)
        #expect(frames.map(\.index) == [0, 1, 2, 3], "In the order asked for; nothing past the end")
        for (frame, asked) in zip(frames, times) {
            #expect(frame.time >= asked)
            #expect(frame.time.seconds - asked.seconds < 0.5)
            #expect(max(frame.width, frame.height) == 160)
            #expect(frame.jpeg.starts(with: [0xFF, 0xD8]), "A JPEG")
            #expect(frame.signature.pixels.count == FrameSignature.width * FrameSignature.height * 3)
        }
        // 0.5 s and 0.6 s are in the first shot; 2.0 s and 3.2 s in the second and third.
        #expect(frames[1].signature.distance(to: frames[3].signature) < 14)
        #expect(frames[1].signature.distance(to: frames[2].signature) > 14)
        #expect(frames[2].signature.distance(to: frames[0].signature) > 14)
    }

    @Test func readingFramesCanBeCancelled() {
        #expect(throws: MediaAnalyzer.Error.self) {
            try MediaAnalyzer.frames(in: Self.fixtures.appending(path: "cuts-25.mp4"), at: [Self.time(1), Self.time(3)]) { _ in false }
        }
    }

    @Test func hdrIsBroughtToSDR() {
        // PQ code values for black, SDR white (203 nits, about 58% of the range) and a 1000-nit highlight.
        func pixel(_ code: Double) -> [UInt16] { [UInt16](repeating: UInt16(code * 65535), count: 3) }
        var rgb = [UInt8](repeating: 0, count: 9)
        ToneMap.toSDR(pixel(0) + pixel(0.58) + pixel(0.75), into: &rgb)
        #expect(rgb[0] == 0)
        #expect((225...250).contains(rgb[3]), "SDR white stays bright: \(rgb[3])")
        #expect(rgb[6] > rgb[3], "Highlights roll off above it")
    }
}

import Foundation
import SubtitleCore

/// Picks the few frames of each scene worth showing a vision model, all on this
/// Mac: frames are read while the lines are spoken, grouped into scenes, and the
/// many frames of one camera setup (a scene cuts back and forth between a few)
/// become one, the widest view first. See docs/ARCHITECTURE.md, section 7d.
public enum SceneFramePicker {
    public struct Options: Sendable, Equatable {
        /// The most frames kept for a scene; a short one gets fewer.
        public var maxFramesPerScene = 9
        /// Frames whose signatures are this close (`FrameSignature.distance`) show the same camera setup.
        public var alike = 14.0
        /// In a scene whose frames all look much the same (a dark room), only frames closer than this share
        /// of the scene's typical distance are one setup, down to `minimumAlike`.
        public var alikeInScene = 0.7
        public var minimumAlike = 2.0
        /// A scene goes on while a setup comes back within this many seconds.
        public var linkSeconds = 45.0
        /// Lines this long (seconds) get two frames, a quarter and three quarters in; shorter ones one, halfway.
        public var longLineSeconds = 2.5
        /// Shot changes this close (seconds) to a line get a frame too: the wide view of a room is often shown before anyone speaks.
        public var establishingSeconds = 12.0
        /// How far (seconds) into a shot its frame is taken, past the cut and any dissolve.
        public var shotLeadSeconds = 0.5
        /// Frames darker than this (0 to 255) are fades to black.
        public var minimumBrightness = 3.0
        /// A stretch with fewer lines joins the scene next to it, when no further than `mergeSeconds`.
        public var minimumSceneLines = 3
        public var mergeSeconds = 8.0

        public init() {}
    }

    /// When a line is spoken.
    public struct Line: Sendable, Equatable {
        public var start: MediaTime
        public var end: MediaTime

        public init(start: MediaTime, end: MediaTime) {
            self.start = start
            self.end = end
        }
    }

    /// A time to read a frame at, and the line spoken then (its index), if any.
    public struct Sample: Sendable, Equatable {
        public var time: MediaTime
        public var line: Int?

        public init(time: MediaTime, line: Int? = nil) {
            self.time = time
            self.line = line
        }
    }

    /// A frame read for a sample.
    public struct Frame: Sendable, Equatable, Identifiable {
        public var id: Int
        public var time: MediaTime
        public var line: Int?
        public var signature: FrameSignature
        public var faces: [FaceBox]
        public var jpeg: Data
        public var width: Int
        public var height: Int

        public init(
            id: Int, time: MediaTime, line: Int? = nil, signature: FrameSignature, faces: [FaceBox] = [], jpeg: Data = Data(),
            width: Int = 0, height: Int = 0
        ) {
            self.id = id
            self.time = time
            self.line = line
            self.signature = signature
            self.faces = faces
            self.jpeg = jpeg
            self.width = width
            self.height = height
        }
    }

    /// A frame kept for a scene, standing for one camera setup.
    public struct Pick: Sendable, Equatable, Identifiable {
        public var frame: Frame
        /// True for the scene's widest view: the frame with the most faces.
        public var isWidest: Bool
        /// The lines spoken over this setup, by index.
        public var lines: [Int]
        /// The other frames of the setup, left out as near-duplicates.
        public var alike: [Frame]

        public var id: Int { frame.id }
    }

    public struct Scene: Sendable, Equatable, Identifiable {
        public var id: Int
        public var start: MediaTime
        public var end: MediaTime
        /// The scene's lines, by index.
        public var lines: ClosedRange<Int>
        /// The frames kept, in time order.
        public var picks: [Pick]
        /// How many frames were read for the scene, and how many camera setups they showed.
        public var frameCount: Int
        public var setupCount: Int
    }

    /// The times to read frames at: while each line is spoken, and just after the shot changes around the lines.
    public static func samples(lines: [Line], shotChanges: [MediaTime], options: Options = Options()) -> [Sample] {
        var samples: [Sample] = []
        for (index, line) in lines.enumerated() {
            let start = line.start.seconds, length = max(line.end.seconds - line.start.seconds, 0)
            let parts = length >= options.longLineSeconds ? [0.25, 0.75] : [0.5]
            for part in parts { samples.append(Sample(time: MediaTime(seconds: start + length * part), line: index)) }
        }
        for change in shotChanges {
            let time = change.seconds
            let isSpokenOver = lines.contains { $0.start.seconds <= time + options.shotLeadSeconds && time + options.shotLeadSeconds <= $0.end.seconds }
            let isNearLine = lines.contains {
                $0.start.seconds - options.establishingSeconds <= time && time <= $0.end.seconds + options.establishingSeconds
            }
            if !isSpokenOver, isNearLine { samples.append(Sample(time: MediaTime(seconds: time + options.shotLeadSeconds))) }
        }
        return samples.sorted { $0.time < $1.time }
    }

    /// Groups the frames into scenes and keeps the best frame of each camera setup,
    /// at most `maxFramesPerScene` a scene. Stretches without lines give no scene.
    public static func scenes(frames: [Frame], lines: [Line], options: Options = Options()) -> [Scene] {
        let frames = frames.filter { $0.signature.brightness >= options.minimumBrightness }.sorted { $0.time < $1.time }
        guard !frames.isEmpty else { return [] }
        var groups = merged(split(frames, options: options), options: options)
        groups.removeAll { group in !group.contains { $0.line != nil } }
        return groups.enumerated().map { index, group in
            let spoken = group.compactMap(\.line)
            let range = spoken.min()!...spoken.max()!
            let setups = setups(in: group, options: options)
            return Scene(
                id: index, start: min(lines[range.lowerBound].start, group[0].time), end: max(lines[range.upperBound].end, group[group.count - 1].time),
                lines: range, picks: picks(from: setups, lineCount: Set(spoken).count, options: options), frameCount: group.count, setupCount: setups.count
            )
        }
    }

    /// Cuts where no camera setup comes back: a scene's shots keep returning to the
    /// same few setups, and the next scene's frames look like none of them.
    static func split(_ frames: [Frame], options: Options) -> [[Frame]] {
        var groups: [[Frame]] = []
        var current: [Frame] = []
        /// The last frame any frame so far is alike with.
        var reach = 0
        for (index, frame) in frames.enumerated() {
            if index > reach, !current.isEmpty {
                groups.append(current)
                current = []
            }
            current.append(frame)
            reach = max(reach, index)
            var later = index + 1
            while later < frames.count, frames[later].time.seconds - frame.time.seconds <= options.linkSeconds {
                if later > reach, frames[later].signature.distance(to: frame.signature) <= options.alike { reach = later }
                later += 1
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    /// Joins stretches with too few lines to be a scene to the nearer neighbour.
    static func merged(_ groups: [[Frame]], options: Options) -> [[Frame]] {
        var groups = groups
        func lineCount(_ group: [Frame]) -> Int { Set(group.compactMap(\.line)).count }
        func gap(_ earlier: [Frame], _ later: [Frame]) -> Double { later[0].time.seconds - earlier[earlier.count - 1].time.seconds }
        while true {
            // The smallest first, so a run of fragments grows together.
            let small = groups.indices.filter { index in
                guard lineCount(groups[index]) < options.minimumSceneLines else { return false }
                let before = index > 0 ? gap(groups[index - 1], groups[index]) : .infinity
                let after = index + 1 < groups.count ? gap(groups[index], groups[index + 1]) : .infinity
                return min(before, after) <= options.mergeSeconds
            }
            guard let index = small.min(by: { groups[$0].count < groups[$1].count }) else { return groups }
            let before = index > 0 ? gap(groups[index - 1], groups[index]) : .infinity
            let after = index + 1 < groups.count ? gap(groups[index], groups[index + 1]) : .infinity
            if before <= after {
                groups[index - 1] += groups[index]
                groups.remove(at: index)
            } else {
                groups[index] += groups[index + 1]
                groups.remove(at: index + 1)
            }
        }
    }

    /// How far apart the scene's frames typically are: the median distance between pairs.
    /// A dark scene's frames are all close, a bright one's far apart.
    static func spread(of frames: [Frame]) -> Double {
        var distances: [Double] = []
        for first in frames.indices {
            for second in frames.indices where second > first {
                distances.append(frames[first].signature.distance(to: frames[second].signature))
            }
        }
        distances.sort()
        return distances.isEmpty ? 0 : distances[distances.count / 2]
    }

    /// The scene's frames by camera setup, in the order the setups first show. Frames are
    /// one setup when they are `alike`, or, in a scene whose frames all look much the same
    /// (a dark room), closer than the scene's frames typically are.
    static func setups(in frames: [Frame], options: Options) -> [[Frame]] {
        let alike = min(options.alike, max(spread(of: frames) * options.alikeInScene, options.minimumAlike))
        var setups: [[Frame]] = []
        for frame in frames {
            // A setup drifts as the camera and the people move: its first and latest frames both count.
            let distances = setups.map { setup in
                min(setup[0].signature.distance(to: frame.signature), setup[setup.count - 1].signature.distance(to: frame.signature))
            }
            if let nearest = distances.indices.min(by: { distances[$0] < distances[$1] }), distances[nearest] <= alike {
                setups[nearest].append(frame)
            } else {
                setups.append([frame])
            }
        }
        return setups
    }

    /// How many frames a scene with `lines` lines gets: three for a short exchange, up to `maxFramesPerScene`.
    static func budget(lines: Int, options: Options) -> Int {
        min(max(Int(Double(lines).squareRoot().rounded()) + 1, 2), options.maxFramesPerScene)
    }

    /// One frame per setup worth showing: the widest view first, then, again and again, the
    /// setup that adds most, which is one many lines are spoken over that looks least like
    /// those already kept. The setups not kept count with the kept one they look most like.
    static func picks(from setups: [[Frame]], lineCount: Int, options: Options) -> [Pick] {
        struct Setup {
            var frame: Frame
            var frames: [Frame]
            var lines: Set<Int>
        }
        let all = setups.map { setup -> Setup in
            // The frame with the most faces; among equals, the one in the middle of the setup.
            let most = setup.map(\.faces.count).max() ?? 0
            let best = setup.filter { $0.faces.count == most }
            return Setup(frame: best[best.count / 2], frames: setup, lines: Set(setup.compactMap(\.line)))
        }
        func faceHeight(_ setup: Setup) -> Double {
            setup.frame.faces.isEmpty ? 1 : setup.frame.faces.reduce(0) { $0 + $1.height } / Double(setup.frame.faces.count)
        }
        // The widest view shows the most people, and shows them smallest.
        let widest = all.indices.filter { all[$0].frame.faces.count > 1 }.max { first, second in
            let a = all[first], b = all[second]
            if a.frame.faces.count != b.frame.faces.count { return a.frame.faces.count < b.frame.faces.count }
            return faceHeight(a) > faceHeight(b)
        }
        var kept: [Int] = widest.map { [$0] } ?? []
        let budget = budget(lines: lineCount, options: options)
        while kept.count < min(budget, all.count) {
            func worth(_ index: Int) -> Double {
                let setup = all[index]
                let novelty = kept.map { all[$0].frame.signature.distance(to: setup.frame.signature) }.min() ?? 1
                // People matter more than views of things, and a setup with no line is only scenery.
                let people = setup.frame.faces.isEmpty ? 0.5 : 1
                return novelty * Double(setup.lines.count + 1).squareRoot() * people
            }
            guard let next = all.indices.filter({ !kept.contains($0) }).max(by: { worth($0) < worth($1) }) else { break }
            kept.append(next)
        }
        var picks = kept.map { index -> Pick in
            let setup = all[index]
            return Pick(frame: setup.frame, isWidest: index == widest, lines: setup.lines.sorted(), alike: setup.frames.filter { $0.id != setup.frame.id })
        }
        for index in all.indices where !kept.contains(index) {
            let nearest = picks.indices.min { first, second in
                picks[first].frame.signature.distance(to: all[index].frame.signature) < picks[second].frame.signature.distance(to: all[index].frame.signature)
            }
            guard let nearest else { continue }
            picks[nearest].alike += all[index].frames
            picks[nearest].lines = Set(picks[nearest].lines).union(all[index].lines).sorted()
        }
        for index in picks.indices { picks[index].alike.sort { $0.time < $1.time } }
        return picks.sorted { $0.frame.time < $1.frame.time }
    }
}

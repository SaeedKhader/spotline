import AppKit
import CMPV
import PlaybackCore
import SubtitleCore

/// Plays media with libmpv and reports what is on screen as `PlaybackStatus`.
///
/// Seeks are exact (`hr-seek`) and aim just before the target frame's start, so
/// rounded container timestamps still land on the right frame. Frame steps are
/// exact seeks too: rapid steps add up from the last requested frame instead of
/// the last displayed one, so ten clicks always move ten frames.
@MainActor
public final class MPVPlayer: PlaybackEngine {
    public struct Configuration: Sendable {
        /// Draw into the view from `videoView()`. Turn off for headless tests.
        public var showsVideo = true
        public var playsAudio = true
        /// VideoToolbox decoding. Tests turn it off for identical results on every machine.
        public var usesHardwareDecoding = true

        public init(showsVideo: Bool = true, playsAudio: Bool = true, usesHardwareDecoding: Bool = true) {
            self.showsVideo = showsVideo
            self.playsAudio = playsAudio
            self.usesHardwareDecoding = usesHardwareDecoding
        }
    }

    public private(set) var status = PlaybackStatus()
    public var onStatusChange: (@MainActor (PlaybackStatus) -> Void)?

    private let configuration: Configuration
    private var handle: MPVHandle!
    private var view: MPVVideoView?
    private var isRenderContextReady = false
    /// A load waiting for the video view's render context; mpv drops the video
    /// track of files opened before one exists.
    private var pendingLoad: URL?
    private var loadingURL: URL?
    /// The frame (at the media's rate) of the newest seek that has not shown yet.
    private var requestedFrame: Int64?

    public init(configuration: Configuration = Configuration()) throws {
        self.configuration = configuration
        handle = try MPVHandle(
            options: [
                "vo": configuration.showsVideo ? "libmpv" : "null",
                "ao": configuration.playsAudio ? "coreaudio" : "null",
                "hwdec": configuration.usesHardwareDecoding ? "videotoolbox" : "no",
                "hr-seek": "yes",
                "hr-seek-framedrop": "no",
                "keep-open": "always",
                "idle": "yes",
                "pause": "yes",
                "config": "no",
                "load-scripts": "no",
                "ytdl": "no",
                "osc": "no",
                "input-default-bindings": "no",
                "input-vo-keyboard": "no",
            ],
            onEvents: { [weak self] events in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.apply(events) }
                }
            }
        )
    }

    public func load(_ url: URL) {
        guard !configuration.showsVideo || isRenderContextReady else {
            pendingLoad = url
            return
        }
        loadingURL = url
        requestedFrame = nil
        handle.command(["loadfile", url.path, "replace"])
    }

    public func setPaused(_ paused: Bool) {
        guard status.hasMedia else { return }
        if !paused {
            requestedFrame = nil
            if status.isAtEnd { handle.command(["seek", "0", "absolute+exact"]) }
        }
        handle.command(["set", "pause", paused ? "yes" : "no"])
    }

    public func seek(toFrame frame: Int64, rate: FrameRate) {
        guard status.hasMedia else { return }
        let mediaRate = status.frameRate ?? rate
        var target = MediaTime(midpointOfFrame: frame, rate: rate).frame(at: mediaRate)
        target = max(target, 0)
        if let lastFrame { target = min(target, lastFrame) }
        requestedFrame = target
        // An exact seek shows the first frame whose timestamp is at or after the
        // target, less mpv's 5 ms tolerance. Aiming a quarter frame early lands on
        // `target` even when container timestamps are rounded to the millisecond.
        let seekTime = MediaTime(
            value: (4 * target - 1) * Int64(mediaRate.denominator),
            timescale: 4 * Int64(mediaRate.numerator)
        )
        let seconds = max(seekTime.seconds, 0)
        handle.command(["seek", String(format: "%.9f", seconds), "absolute+exact"])
    }

    public func step(by frames: Int) {
        guard status.hasMedia, let rate = status.frameRate else { return }
        let current = requestedFrame ?? status.position.nearestFrame(at: rate)
        handle.command(["set", "pause", "yes"])
        seek(toFrame: current + Int64(frames), rate: rate)
    }

    public func videoView() -> NSView? {
        guard configuration.showsVideo else { return nil }
        if let view { return view }
        let layer = MPVVideoLayer(handle: handle) { [weak self] in self?.renderContextDidBecomeReady() }
        let view = MPVVideoView(videoLayer: layer)
        self.view = view
        return view
    }

    /// The last frame of the media, when mpv knows the duration.
    private var lastFrame: Int64? {
        guard let rate = status.frameRate, let duration = status.duration else { return nil }
        return max(duration.nearestFrame(at: rate) - 1, 0)
    }

    private func renderContextDidBecomeReady() {
        isRenderContextReady = true
        if let url = pendingLoad {
            pendingLoad = nil
            load(url)
        }
    }

    private func apply(_ events: [MPVEvent]) {
        var next = status
        for event in events {
            switch event {
            case .fileLoaded:
                next = PlaybackStatus(mediaURL: loadingURL, isPaused: next.isPaused)
            case .fileEnded:
                next = PlaybackStatus(isPaused: next.isPaused)
                requestedFrame = nil
            case .propertyChanged(let name, let value):
                apply(value, to: name, in: &next)
            }
        }
        if let requestedFrame, let rate = next.frameRate,
           next.position.nearestFrame(at: rate) == requestedFrame || next.isAtEnd {
            self.requestedFrame = nil
        }
        guard next != status else { return }
        status = next
        onStatusChange?(next)
    }

    private func apply(_ value: MPVValue, to property: String, in status: inout PlaybackStatus) {
        switch (property, value) {
        case ("pause", .flag(let paused)):
            status.isPaused = paused
        case ("time-pos", .double(let seconds)):
            status.position = MediaTime(seconds: max(seconds, 0))
        case ("duration", .double(let seconds)):
            status.duration = MediaTime(seconds: seconds)
        case ("duration", .unavailable):
            status.duration = nil
        case ("container-fps", .double(let fps)):
            status.frameRate = FrameRate(approximately: fps)
        case ("eof-reached", .flag(let atEnd)):
            status.isAtEnd = atEnd
        case ("current-tracks/audio/ff-index", .integer(let index)):
            status.audioStreamIndex = Int(index)
        case ("current-tracks/audio/ff-index", .unavailable):
            status.audioStreamIndex = nil
        default:
            break
        }
    }
}

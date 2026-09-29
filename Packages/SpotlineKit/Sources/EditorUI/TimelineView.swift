import AppKit
import EditorCommands
import MediaAnalysis
import SpotlineAccessibility
import SubtitleCore
import SwiftUI

/// What the timeline draws, copied from `EditorState` on every change.
struct TimelineContent: Equatable {
    var cues: [Cue] = []
    var selectedCueID: Cue.ID?
    var playhead: MediaTime = .zero
    var hasMedia = false
    var duration: MediaTime?
    var frameRate: FrameRate = .fps23_976
    var shotChanges: [Int64] = []
    var waveform: Waveform?
    /// When set, speech is drawn brightly and everything else dimmed.
    var speech: [SpeechRegion]?
    /// While speech detection runs, how far it has got; later audio is drawn undimmed.
    var speechAnalyzedUntil: MediaTime?
    /// While analysis runs, the time it has reached; later media is drawn as pending.
    var analyzedUntil: MediaTime?
    /// Points per second.
    var scale: Double = 100
    /// The latest request to show a time (from the mini-map).
    var scrollRequest: TimelineScrollRequest?
}

/// Bridges `TimelineView` into SwiftUI.
struct TimelineRepresentable: NSViewRepresentable {
    let editor: EditorState
    let content: TimelineContent

    func makeNSView(context: Context) -> TimelineView {
        TimelineView(editor: editor)
    }

    func updateNSView(_ view: TimelineView, context: Context) {
        view.content = content
    }
}

/// The timeline: time ruler, audio waveform, shot changes, cue blocks and the playhead.
///
/// Click to move the playhead, click a cue to select it, drag a cue to move it
/// and drag its edges to trim. Scroll to pan; pinch or Command-scroll to zoom.
/// Drawn by hand for speed, so it exposes cues, their edges, shot changes and
/// the playhead as accessibility elements for automation.
final class TimelineView: NSView {
    private let editor: EditorState
    var content = TimelineContent() {
        didSet { contentDidChange(from: oldValue) }
    }

    /// Seconds at the left edge. View geometry only; edits use frames.
    private var originSeconds = 0.0
    private var drag: ActiveDrag?
    /// Set by pinch and Command-scroll so the zoom keeps the time under the pointer in place.
    private var zoomAnchor: (seconds: Double, x: CGFloat)?
    private var trackingArea: NSTrackingArea?

    private struct ActiveDrag {
        let cueID: Cue.ID
        let model: CueDrag
        let startX: CGFloat
        var preview: (start: MediaTime, end: MediaTime)?
    }

    static let rulerHeight: CGFloat = 20
    static let edgeGrabWidth: CGFloat = 6
    static let snapDistance: CGFloat = 8

    init(editor: EditorState) {
        self.editor = editor
        super.init(frame: .zero)
        setAccessibilityIdentifier(AccessibilityID.Timeline.root)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 110) }

    // MARK: - Geometry

    private var scale: Double { content.scale }

    private func x(for time: MediaTime) -> CGFloat {
        CGFloat((time.seconds - originSeconds) * scale)
    }

    private func x(forFrame frame: Int64) -> CGFloat {
        x(for: MediaTime(frame: frame, rate: content.frameRate))
    }

    private func frame(atX x: CGFloat) -> Int64 {
        MediaTime(seconds: originSeconds + Double(x) / scale).frame(at: content.frameRate)
    }

    private var laneRect: NSRect {
        NSRect(x: 0, y: Self.rulerHeight, width: bounds.width, height: max(bounds.height - Self.rulerHeight, 0))
    }

    private func blockRect(start: MediaTime, end: MediaTime) -> NSRect {
        let lane = laneRect
        let top = lane.minY + lane.height * 0.45
        let left = x(for: start)
        return NSRect(x: left, y: top, width: max(x(for: end) - left, 2), height: lane.maxY - top - 4)
    }

    private var visibleSeconds: Double { Double(bounds.width) / scale }

    /// The end of what can be scrolled to: the media, or the last cue plus a margin.
    private var contentEndSeconds: Double {
        let lastCue = content.cues.map(\.end.seconds).max() ?? 0
        return max(content.duration?.seconds ?? 0, lastCue + 5)
    }

    private func clampOrigin() {
        originSeconds = min(max(originSeconds, 0), max(contentEndSeconds - visibleSeconds * 0.5, 0))
    }

    private func timing(of cue: Cue) -> (start: MediaTime, end: MediaTime) {
        if let drag, drag.cueID == cue.id, let preview = drag.preview { return preview }
        return (cue.start, cue.end)
    }

    // MARK: - Updates

    private func contentDidChange(from old: TimelineContent) {
        guard content != old else { return }
        let originBefore = originSeconds
        if content.scale != old.scale, let anchor = zoomAnchor {
            originSeconds = anchor.seconds - Double(anchor.x) / scale
            zoomAnchor = nil
        } else if content.scale != old.scale {
            // Keep the playhead where it was on screen while zooming.
            let anchorX = CGFloat((old.playhead.seconds - originSeconds) * old.scale)
            let anchor = (0...bounds.width).contains(anchorX) ? anchorX : bounds.width / 2
            originSeconds = old.playhead.seconds - Double(anchor) / scale
        }
        if content.playhead != old.playhead { keepVisible(content.playhead.seconds) }
        if let request = content.scrollRequest, request != old.scrollRequest {
            originSeconds = request.centerSeconds - visibleSeconds / 2
        }
        if content.selectedCueID != old.selectedCueID, let cue = content.cues.first(where: { $0.id == content.selectedCueID }) {
            keepVisible(cue.start.seconds)
        }
        var waveformDescription: String? = switch content.waveform?.source {
        case .centerChannel: "Waveform: center channel (dialogue)"
        case .mix: "Waveform: all channels mixed"
        case nil: nil
        }
        if let description = waveformDescription, content.speech != nil {
            waveformDescription = description + ", speech highlighted"
        }
        if toolTip != waveformDescription { toolTip = waveformDescription }
        clampOrigin()
        needsDisplay = true
        // While playing, only the playhead moves every frame. Announcing a new
        // layout that often floods accessibility clients and stalls menus.
        var playheadOnly = old
        playheadOnly.playhead = content.playhead
        invalidateAccessibility(announce: playheadOnly != content || originSeconds != originBefore)
        reportViewport()
    }

    private var reportedViewport: ClosedRange<Double>?

    /// Tells the editor what is visible (for the mini-map), after the current view update.
    private func reportViewport() {
        let viewport = originSeconds...(originSeconds + visibleSeconds)
        guard viewport != reportedViewport else { return }
        reportedViewport = viewport
        DispatchQueue.main.async { [editor] in editor.timelineDidShow(viewport) }
    }

    /// Pages the view when `seconds` is off screen, leaving it a tenth of the way in.
    private func keepVisible(_ seconds: Double) {
        guard bounds.width > 0 else { return }
        if seconds < originSeconds || seconds > originSeconds + visibleSeconds {
            originSeconds = seconds - visibleSeconds * 0.1
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        clampOrigin()
        invalidateAccessibility()
        reportViewport()
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        drawWaveform()
        drawPendingAnalysis()
        drawShotChanges()
        drawCues()
        drawRuler()
        drawPlayhead()
    }

    private func drawRuler() {
        let ruler = NSRect(x: 0, y: 0, width: bounds.width, height: Self.rulerHeight)
        NSColor.windowBackgroundColor.setFill()
        ruler.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: ruler.maxY - 1, width: bounds.width, height: 1).fill()

        let rate = content.frameRate
        let frameSeconds = 1 / rate.framesPerSecond
        let steps = [frameSeconds, frameSeconds * 5, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600]
        let step = steps.first { $0 * scale >= 90 } ?? 3600
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        var tick = (originSeconds / step).rounded(.down) * step
        while tick <= originSeconds + visibleSeconds {
            let tickX = CGFloat((tick - originSeconds) * scale)
            NSColor.tertiaryLabelColor.setFill()
            NSRect(x: tickX, y: ruler.maxY - 7, width: 1, height: 6).fill()
            NSRect(x: tickX + CGFloat(step * scale / 2), y: ruler.maxY - 4, width: 1, height: 3).fill()
            let frame = MediaTime(seconds: tick).nearestFrame(at: rate)
            if frame >= 0 {
                let label = Timecode(frameNumber: frame, rate: rate).description as NSString
                label.draw(at: NSPoint(x: tickX + 3, y: 3), withAttributes: attributes)
            }
            tick += step
        }
    }

    private func drawWaveform() {
        guard let waveform = content.waveform else { return }
        let lane = laneRect
        // Normalize to the loudest peak so quiet mixes stay readable.
        let loudest = max(Double(waveform.peaks.max() ?? 0) / 255, 0.05)
        let gain = 0.95 / loudest
        let middle = lane.midY
        let halfHeight = lane.height / 2
        let plain = NSColor.secondaryLabelColor.withAlphaComponent(0.45)
        let spoken = NSColor.systemMint.withAlphaComponent(0.85)
        let dimmed = NSColor.secondaryLabelColor.withAlphaComponent(0.12)
        let regions = content.speech ?? []
        let classifiedUntil = content.speech == nil ? -Double.infinity : content.speechAnalyzedUntil?.seconds ?? .infinity
        var regionIndex = 0
        let secondsPerPoint = 1 / scale
        var column: CGFloat = 0
        while column < bounds.width {
            let start = originSeconds + Double(column) * secondsPerPoint
            let end = start + secondsPerPoint
            let peak = min(Double(waveform.peak(from: start, to: end)) * gain, 1)
            let height = max(CGFloat(peak) * halfHeight, 0.5)
            // Speech bright, music and effects dimmed, where speech detection has run.
            if start < classifiedUntil {
                while regionIndex < regions.count, regions[regionIndex].end.seconds <= start { regionIndex += 1 }
                let isSpeech = regionIndex < regions.count && regions[regionIndex].start.seconds < end
                (isSpeech ? spoken : dimmed).setFill()
            } else {
                plain.setFill()
            }
            NSRect(x: column, y: middle - height, width: 1, height: height * 2).fill()
            column += 1
        }
    }

    /// Hatches the part of the lane the analysis has not reached yet.
    private func drawPendingAnalysis() {
        guard let analyzedUntil = content.analyzedUntil else { return }
        let lane = laneRect
        let left = max(x(for: analyzedUntil), 0)
        guard left < bounds.width else { return }
        let pending = NSRect(x: left, y: lane.minY, width: bounds.width - left, height: lane.height)
        NSColor.secondaryLabelColor.withAlphaComponent(0.06).setFill()
        pending.fill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: pending).addClip()
        let stripes = NSBezierPath()
        var stripeX = left - lane.height
        while stripeX < bounds.width {
            stripes.move(to: NSPoint(x: stripeX, y: lane.maxY))
            stripes.line(to: NSPoint(x: stripeX + lane.height, y: lane.minY))
            stripeX += 10
        }
        NSColor.secondaryLabelColor.withAlphaComponent(0.12).setStroke()
        stripes.lineWidth = 1
        stripes.stroke()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.secondaryLabelColor.withAlphaComponent(0.5).setFill()
        NSRect(x: left, y: lane.minY, width: 1, height: lane.height).fill()
    }

    private func drawShotChanges() {
        NSColor.systemYellow.withAlphaComponent(0.85).setFill()
        let lane = laneRect
        for frame in content.shotChanges {
            let lineX = x(forFrame: frame)
            guard lineX >= -1, lineX <= bounds.width + 1 else { continue }
            NSRect(x: lineX - 0.5, y: lane.minY, width: 1.5, height: lane.height).fill()
        }
    }

    private func drawCues() {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
        ]
        for cue in content.cues {
            let (start, end) = timing(of: cue)
            let rect = blockRect(start: start, end: end)
            guard rect.maxX >= 0, rect.minX <= bounds.width else { continue }
            let isSelected = cue.id == content.selectedCueID
            let color = isSelected ? NSColor.controlAccentColor : NSColor.systemTeal
            let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            color.withAlphaComponent(isSelected ? 0.55 : 0.3).setFill()
            path.fill()
            color.setStroke()
            path.lineWidth = isSelected ? 2 : 1
            path.stroke()
            if isSelected {
                // Edge grips.
                color.setFill()
                NSRect(x: rect.minX, y: rect.minY, width: 3, height: rect.height).fill()
                NSRect(x: rect.maxX - 3, y: rect.minY, width: 3, height: rect.height).fill()
            }
            let text = SubtitleText.visibleLines(of: cue.text).joined(separator: " / ") as NSString
            let textRect = rect.insetBy(dx: 5, dy: 3)
            if textRect.width > 12 {
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: textRect).addClip()
                text.draw(in: textRect, withAttributes: attributes)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }

    private func drawPlayhead() {
        guard content.hasMedia else { return }
        let playheadX = x(for: content.playhead)
        guard playheadX >= -1, playheadX <= bounds.width + 1 else { return }
        NSColor.systemRed.setFill()
        NSRect(x: playheadX - 0.5, y: 0, width: 1.5, height: bounds.height).fill()
        let marker = NSBezierPath()
        marker.move(to: NSPoint(x: playheadX - 5, y: 0))
        marker.line(to: NSPoint(x: playheadX + 5, y: 0))
        marker.line(to: NSPoint(x: playheadX, y: 7))
        marker.close()
        marker.fill()
    }

    // MARK: - Mouse

    /// The cue and part under a point, preferring the selected cue's edges.
    private func hit(at point: NSPoint) -> (cue: Cue, part: CueDrag.Part)? {
        let ordered = content.cues.sorted { a, _ in a.id == content.selectedCueID }
        for cue in ordered {
            let rect = blockRect(start: cue.start, end: cue.end)
            let grab = rect.insetBy(dx: -Self.edgeGrabWidth / 2, dy: 0)
            guard grab.contains(point) else { continue }
            let edge = min(Self.edgeGrabWidth, rect.width / 3)
            if abs(point.x - rect.minX) <= edge { return (cue, .inPoint) }
            if abs(point.x - rect.maxX) <= edge { return (cue, .outPoint) }
            return (cue, .body)
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let (cue, part) = hit(at: point) {
            editor.select(cue.id)
            drag = ActiveDrag(
                cueID: cue.id,
                model: CueDrag(
                    part: part, start: cue.start, end: cue.end, rate: content.frameRate,
                    earliestStart: editor.room(for: cue.id).earliestStart, latestEnd: editor.room(for: cue.id).latestEnd
                ),
                startX: point.x
            )
            cursor(for: part).set()
        } else {
            drag = nil
            editor.seek(toFrame: frame(atX: point.x))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard var active = drag else {
            editor.seek(toFrame: frame(atX: point.x))
            return
        }
        let frames = MediaTime(seconds: Double(point.x - active.startX) / scale).nearestFrame(at: content.frameRate)
        let tolerance = MediaTime(seconds: Double(Self.snapDistance) / scale)
        active.preview = active.model.timing(
            movedBy: frames,
            snapTargets: editor.snapTargets(excluding: active.cueID),
            tolerance: tolerance
        )
        drag = active
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            drag = nil
            needsDisplay = true
        }
        guard let active = drag, let preview = active.preview,
              preview.start != active.model.start || preview.end != active.model.end
        else { return }
        editor.setTiming(start: preview.start, end: preview.end, forCue: active.cueID, actionName: active.model.actionName)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            zoom(by: 1 + event.scrollingDeltaY * 0.01, at: convert(event.locationInWindow, from: nil).x)
            return
        }
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        let points = event.hasPreciseScrollingDeltas ? delta : delta * 10
        originSeconds -= Double(points) / scale
        clampOrigin()
        needsDisplay = true
        invalidateAccessibility()
        reportViewport()
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, at: convert(event.locationInWindow, from: nil).x)
    }

    /// Zooms keeping the time under `anchorX` in place.
    private func zoom(by factor: CGFloat, at anchorX: CGFloat) {
        zoomAnchor = (originSeconds + Double(anchorX) / scale, anchorX)
        editor.setTimelineScale(scale * Double(factor))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard drag == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        (hit(at: point).map { cursor(for: $0.part) } ?? .arrow).set()
    }

    override func cursorUpdate(with event: NSEvent) {
        mouseMoved(with: event)
    }

    private func cursor(for part: CueDrag.Part) -> NSCursor {
        switch part {
        case .body: drag == nil ? .openHand : .closedHand
        case .inPoint, .outPoint: .resizeLeftRight
        }
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Timeline" }
    /// Which channels the waveform shows, as in the tooltip.
    override func accessibilityValue() -> Any? { toolTip ?? "" }

    /// Elements must outlive the call that returns them, so they are kept until the layout changes.
    private var accessibilityElementsCache: [NSAccessibilityElement]?

    private func invalidateAccessibility(announce: Bool = true) {
        accessibilityElementsCache = nil
        if announce { NSAccessibility.post(element: self, notification: .layoutChanged) }
    }

    override func accessibilityChildren() -> [Any]? {
        if accessibilityElementsCache == nil { accessibilityElementsCache = makeAccessibilityElements() }
        return accessibilityElementsCache
    }

    private func makeAccessibilityElements() -> [NSAccessibilityElement] {
        var children: [NSAccessibilityElement] = []
        let rate = content.frameRate
        func label(_ time: MediaTime) -> String {
            Timecode(frameNumber: max(time.firstFrame(at: rate), 0), rate: rate).description
        }

        if content.hasMedia {
            let playheadX = x(for: content.playhead)
            children.append(TimelineElement(
                parent: self, parentHeight: bounds.height, role: .valueIndicator, identifier: AccessibilityID.Timeline.playhead,
                label: "Playhead", value: label(content.playhead),
                rect: NSRect(x: playheadX - 2, y: 0, width: 4, height: bounds.height)
            ))
        }
        for (index, frame) in content.shotChanges.enumerated() {
            let lineX = x(forFrame: frame)
            guard lineX >= 0, lineX <= bounds.width else { continue }
            children.append(TimelineElement(
                parent: self, parentHeight: bounds.height, role: .splitter, identifier: AccessibilityID.Timeline.shotChange(index),
                label: "Shot change", value: Timecode(frameNumber: frame, rate: rate).description,
                rect: NSRect(x: lineX - 2, y: laneRect.minY, width: 4, height: laneRect.height)
            ))
        }
        for cue in content.cues {
            let rect = blockRect(start: cue.start, end: cue.end)
            guard rect.maxX >= 0, rect.minX <= bounds.width else { continue }
            let id = cue.id
            let element = TimelineElement(
                parent: self, parentHeight: bounds.height, role: .group, identifier: AccessibilityID.Timeline.cue(id),
                label: SubtitleText.visibleLines(of: cue.text).joined(separator: " "),
                value: "\(label(cue.start)) – \(label(cue.end))",
                rect: rect
            )
            element.onPress = { [weak self] in self?.editor.select(id) }
            let handleWidth = min(Self.edgeGrabWidth * 2, rect.width / 2)
            let inHandle = TimelineElement(
                parent: self, parentHeight: bounds.height, role: .handle, identifier: AccessibilityID.Timeline.inHandle(id),
                label: "In", value: label(cue.start),
                rect: NSRect(x: rect.minX - handleWidth / 2, y: rect.minY, width: handleWidth, height: rect.height)
            )
            inHandle.onAdjust = { [weak self] frames in self?.nudge(id, part: .inPoint, by: frames) }
            let outHandle = TimelineElement(
                parent: self, parentHeight: bounds.height, role: .handle, identifier: AccessibilityID.Timeline.outHandle(id),
                label: "Out", value: label(cue.end),
                rect: NSRect(x: rect.maxX - handleWidth / 2, y: rect.minY, width: handleWidth, height: rect.height)
            )
            outHandle.onAdjust = { [weak self] frames in self?.nudge(id, part: .outPoint, by: frames) }
            // Handles are siblings of their cue so their frames share the view's coordinates.
            children.append(contentsOf: [element, inHandle, outHandle])
        }
        return children
    }

    /// Moves a cue edge by whole frames (accessibility increment and decrement).
    private func nudge(_ id: Cue.ID, part: CueDrag.Part, by frames: Int64) {
        guard let cue = content.cues.first(where: { $0.id == id }) else { return }
        let model = CueDrag(
                    part: part, start: cue.start, end: cue.end, rate: content.frameRate,
                    earliestStart: editor.room(for: cue.id).earliestStart, latestEnd: editor.room(for: cue.id).latestEnd
                )
        let timing = model.timing(movedBy: frames, snapTargets: [], tolerance: .zero)
        editor.setTiming(start: timing.start, end: timing.end, forCue: id, actionName: model.actionName)
    }

}

/// One accessible part of the timeline, positioned in the timeline view's coordinates.
private final class TimelineElement: NSAccessibilityElement {
    var onPress: (() -> Void)?
    var onAdjust: ((Int64) -> Void)?

    init(parent: NSView, parentHeight: CGFloat, role: NSAccessibility.Role, identifier: String, label: String, value: String, rect: NSRect) {
        super.init()
        setAccessibilityParent(parent)
        // The frame is in unflipped view coordinates; the timeline view is flipped.
        setAccessibilityFrameInParentSpace(NSRect(x: rect.minX, y: parentHeight - rect.maxY, width: rect.width, height: rect.height))
        setAccessibilityRole(role)
        setAccessibilityIdentifier(identifier)
        setAccessibilityLabel(label)
        setAccessibilityValue(value)
    }

    override func isAccessibilityEnabled() -> Bool { true }

    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        onPress()
        return true
    }

    override func accessibilityPerformIncrement() -> Bool {
        guard let onAdjust else { return false }
        onAdjust(1)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        guard let onAdjust else { return false }
        onAdjust(-1)
        return true
    }
}

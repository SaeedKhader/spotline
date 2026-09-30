import AppKit
import EditorCommands
import MediaAnalysis
import SpotlineAccessibility
import SubtitleCore
import SubtitleTranslation
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
    /// Cues with something to check (QC issues, words to check): an orange dot.
    var attentionCueIDs: Set<Cue.ID> = []
    /// Cues with an AI suggestion to decide (a proposed change, a translation choice): a purple dot.
    var suggestionCueIDs: Set<Cue.ID> = []
    /// Points per second.
    var scale: Double = 100
    /// The latest request to show a time (from the mini-map, with no media open).
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

/// The timeline: time ruler, cue blocks in the middle, the audio waveform along
/// the bottom, shot changes, and the playhead fixed in the centre.
///
/// The media moves under the playhead: drag empty space (or scroll) to scrub,
/// click the ruler to go to a time. Click a cue to select it and go to it, drag
/// a cue to move it and drag its edges to trim; click empty space to deselect.
/// Pinch or Command-scroll to zoom. Drawn by hand for speed, so it exposes cues,
/// their edges, shot changes and the playhead as accessibility elements for automation.
final class TimelineView: NSView {
    private let editor: EditorState
    var content = TimelineContent() {
        didSet { contentDidChange(from: oldValue) }
    }

    /// The time under the playhead while the view leads the player: during a
    /// scrub, and until the player's position catches up after one.
    private var localCenter: Double?
    /// The time in the centre with no media open, where scrolling only moves the view.
    private var freeCenter = 0.0
    private var drag: ActiveDrag?
    private var scrub: Scrub?
    private var trackingArea: NSTrackingArea?
    private var releaseLocalCenter: DispatchWorkItem?

    private struct ActiveDrag {
        let cueID: Cue.ID
        let model: CueDrag
        let startX: CGFloat
        var preview: (start: MediaTime, end: MediaTime)?
    }

    /// A press on empty space or the ruler: a drag scrubs, a click deselects (or, on the ruler, goes there).
    private struct Scrub {
        let startX: CGFloat
        let startCenter: Double
        let inRuler: Bool
        var moved = false
    }

    static let rulerHeight: CGFloat = 20
    static let edgeGrabWidth: CGFloat = 6
    static let snapDistance: CGFloat = 8
    static let lineHeight: CGFloat = 14

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

    /// The time under the playhead, which is always in the middle of the view.
    private var centerSeconds: Double {
        localCenter ?? (content.hasMedia ? content.playhead.seconds : freeCenter)
    }

    /// Seconds at the left edge. View geometry only; edits use frames.
    private var originSeconds: Double { centerSeconds - visibleSeconds / 2 }

    private func x(for time: MediaTime) -> CGFloat {
        x(forSeconds: time.seconds)
    }

    private func x(forSeconds seconds: Double) -> CGFloat {
        CGFloat((seconds - originSeconds) * scale)
    }

    private func x(forFrame frame: Int64) -> CGFloat {
        x(for: MediaTime(frame: frame, rate: content.frameRate))
    }

    private func seconds(atX x: CGFloat) -> Double {
        originSeconds + Double(x) / scale
    }

    private var laneRect: NSRect {
        NSRect(x: 0, y: Self.rulerHeight, width: bounds.width, height: max(bounds.height - Self.rulerHeight, 0))
    }

    /// The band along the bottom the waveform grows up from.
    private var waveformRect: NSRect {
        let lane = laneRect
        let height = min(max(lane.height * 0.35, 20), 90)
        return NSRect(x: 0, y: lane.maxY - height, width: lane.width, height: height)
    }

    /// Where cue blocks sit: between the ruler and the waveform, centred.
    private var cueBand: (mid: CGFloat, height: CGFloat) {
        let top = laneRect.minY + 6
        let bottom = waveformRect.minY - 4
        let room = max(bottom - top, 12)
        // Two lines of text when there is room.
        let height = min(max(Self.lineHeight * 2 + 10, room * 0.6), 60, room)
        return ((top + bottom) / 2, height)
    }

    /// A cue's block. A top cue and a bottom cue on screen together sit one
    /// above the other around the middle, so neither hides the other.
    private func blockRect(for cue: Cue, start: MediaTime, end: MediaTime) -> NSRect {
        let band = cueBand
        var top = band.mid - band.height / 2
        var height = band.height
        if stackedCueIDs.contains(cue.id) {
            height = min(band.height, max(waveformRect.minY - laneRect.minY - 12, 8) / 2)
            top = cue.position == .top ? band.mid - height - 1 : band.mid + 1
        }
        let left = x(for: start)
        return NSRect(x: left, y: top, width: max(x(for: end) - left, 2), height: height)
    }

    private func blockRect(for cue: Cue) -> NSRect {
        let (start, end) = timing(of: cue)
        return blockRect(for: cue, start: start, end: end)
    }

    /// Cues that overlap a cue in the other position (a sign over dialogue).
    private var stackedCueIDs: Set<Cue.ID> = []

    static func stackedCueIDs(in cues: [Cue]) -> Set<Cue.ID> {
        let sorted = cues.sorted { $0.start < $1.start }
        var stacked: Set<Cue.ID> = []
        for (index, cue) in sorted.enumerated() {
            for other in sorted[(index + 1)...] {
                guard other.start < cue.end else { break }
                if other.position != cue.position, cue.start < other.end {
                    stacked.insert(cue.id)
                    stacked.insert(other.id)
                }
            }
        }
        return stacked
    }

    private var visibleSeconds: Double { Double(bounds.width) / scale }

    /// The end of what can be scrubbed to: the media, or the last cue plus a margin.
    private var contentEndSeconds: Double {
        if let duration = content.duration, content.hasMedia { return duration.seconds }
        let lastCue = content.cues.map(\.end.seconds).max() ?? 0
        return max(content.duration?.seconds ?? 0, lastCue + 5)
    }

    private func clamp(_ seconds: Double) -> Double {
        min(max(seconds, 0), contentEndSeconds)
    }

    private func timing(of cue: Cue) -> (start: MediaTime, end: MediaTime) {
        if let drag, drag.cueID == cue.id, let preview = drag.preview { return preview }
        return (cue.start, cue.end)
    }

    // MARK: - Updates

    private func contentDidChange(from old: TimelineContent) {
        guard content != old else { return }
        if content.cues != old.cues { stackedCueIDs = Self.stackedCueIDs(in: content.cues) }
        if let request = content.scrollRequest, request != old.scrollRequest {
            freeCenter = clamp(request.centerSeconds)
        }
        // After a scrub the view keeps its own time until the player gets there.
        if let local = localCenter, scrub == nil, content.playhead != old.playhead,
           abs(content.playhead.seconds - local) < 1 / content.frameRate.framesPerSecond {
            localCenter = nil
        }
        if !content.hasMedia { localCenter = nil }
        var waveformDescription: String? = switch content.waveform?.source {
        case .centerChannel: "Waveform: center channel (dialogue)"
        case .mix: "Waveform: all channels mixed"
        case nil: nil
        }
        if let description = waveformDescription, content.speech != nil {
            waveformDescription = description + ", speech highlighted"
        }
        if toolTip != waveformDescription { toolTip = waveformDescription }
        needsDisplay = true
        // While playing, only the playhead moves every frame. Announcing a new
        // layout that often floods accessibility clients and stalls menus.
        var playheadOnly = old
        playheadOnly.playhead = content.playhead
        invalidateAccessibility(announce: playheadOnly != content)
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

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        invalidateAccessibility()
        reportViewport()
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        drawOutsideMedia()
        drawWaveform()
        drawPendingAnalysis()
        drawShotChanges()
        drawCues()
        drawRuler()
        drawPlayhead()
    }

    /// Before the start and after the end: hatched, so the playhead can stay in the middle at both ends.
    private func drawOutsideMedia() {
        let lane = laneRect
        let startX = x(forSeconds: 0)
        let endX = x(forSeconds: contentEndSeconds)
        for (left, right) in [(CGFloat(0), min(startX, bounds.width)), (max(endX, 0), bounds.width)] where right > left {
            let rect = NSRect(x: left, y: lane.minY, width: right - left, height: lane.height)
            hatch(rect, stroke: NSColor.secondaryLabelColor.withAlphaComponent(0.08), fill: NSColor.windowBackgroundColor.withAlphaComponent(0.6))
        }
    }

    private func hatch(_ rect: NSRect, stroke: NSColor, fill: NSColor) {
        fill.setFill()
        rect.fill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        let stripes = NSBezierPath()
        var stripeX = rect.minX - rect.height
        while stripeX < rect.maxX {
            stripes.move(to: NSPoint(x: stripeX, y: rect.maxY))
            stripes.line(to: NSPoint(x: stripeX + rect.height, y: rect.minY))
            stripeX += 10
        }
        stroke.setStroke()
        stripes.lineWidth = 1
        stripes.stroke()
        NSGraphicsContext.restoreGraphicsState()
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
            let tickX = x(forSeconds: tick)
            NSColor.tertiaryLabelColor.setFill()
            NSRect(x: tickX, y: ruler.maxY - 7, width: 1, height: 6).fill()
            NSRect(x: tickX + CGFloat(step * scale / 2), y: ruler.maxY - 4, width: 1, height: 3).fill()
            let frame = MediaTime(seconds: tick).nearestFrame(at: rate)
            if frame >= 0, tick <= contentEndSeconds {
                let label = Timecode(frameNumber: frame, rate: rate).description as NSString
                label.draw(at: NSPoint(x: tickX + 3, y: 3), withAttributes: attributes)
            }
            tick += step
        }
        // Shot changes also get a tick in the ruler, so they read apart from the playhead.
        NSColor.secondaryLabelColor.setFill()
        for frame in content.shotChanges {
            let lineX = x(forFrame: frame)
            guard lineX >= -1, lineX <= bounds.width + 1 else { continue }
            NSRect(x: lineX - 0.5, y: ruler.maxY - 6, width: 1.5, height: 5).fill()
        }
    }

    /// The waveform grows up from the bottom edge.
    private func drawWaveform() {
        guard let waveform = content.waveform else { return }
        let band = waveformRect
        // Normalize to the loudest peak so quiet mixes stay readable.
        let loudest = max(Double(waveform.peaks.max() ?? 0) / 255, 0.05)
        let gain = 0.95 / loudest
        let plain = NSColor.secondaryLabelColor.withAlphaComponent(0.4)
        let spoken = NSColor.labelColor.withAlphaComponent(0.55)
        let dimmed = NSColor.secondaryLabelColor.withAlphaComponent(0.15)
        let regions = content.speech ?? []
        let classifiedUntil = content.speech == nil ? -Double.infinity : content.speechAnalyzedUntil?.seconds ?? .infinity
        var regionIndex = 0
        let secondsPerPoint = 1 / scale
        var column = max(x(forSeconds: 0).rounded(.down), 0)
        let lastColumn = min(x(forSeconds: contentEndSeconds), bounds.width)
        while column < lastColumn {
            let start = seconds(atX: column)
            let end = start + secondsPerPoint
            let peak = min(Double(waveform.peak(from: start, to: end)) * gain, 1)
            let height = max(CGFloat(peak) * band.height, 0.5)
            // Speech bright, music and effects dimmed, where speech detection has run.
            if start < classifiedUntil {
                while regionIndex < regions.count, regions[regionIndex].end.seconds <= start { regionIndex += 1 }
                let isSpeech = regionIndex < regions.count && regions[regionIndex].start.seconds < end
                (isSpeech ? spoken : dimmed).setFill()
            } else {
                plain.setFill()
            }
            NSRect(x: column, y: band.maxY - height, width: 1, height: height).fill()
            column += 1
        }
    }

    /// Hatches the part of the lane the analysis has not reached yet.
    private func drawPendingAnalysis() {
        guard let analyzedUntil = content.analyzedUntil else { return }
        let lane = laneRect
        let left = max(x(for: analyzedUntil), 0)
        let right = min(x(forSeconds: contentEndSeconds), bounds.width)
        guard left < right else { return }
        let pending = NSRect(x: left, y: lane.minY, width: right - left, height: lane.height)
        hatch(pending, stroke: NSColor.secondaryLabelColor.withAlphaComponent(0.12), fill: NSColor.secondaryLabelColor.withAlphaComponent(0.06))
        NSColor.secondaryLabelColor.withAlphaComponent(0.5).setFill()
        NSRect(x: left, y: lane.minY, width: 1, height: lane.height).fill()
    }

    private func drawShotChanges() {
        NSColor.secondaryLabelColor.withAlphaComponent(0.35).setFill()
        let lane = laneRect
        for frame in content.shotChanges {
            let lineX = x(forFrame: frame)
            guard lineX >= -1, lineX <= bounds.width + 1 else { continue }
            NSRect(x: lineX - 0.5, y: lane.minY, width: 1, height: lane.height).fill()
        }
    }

    private func drawCues() {
        for cue in content.cues {
            let rect = blockRect(for: cue)
            guard rect.maxX >= 0, rect.minX <= bounds.width else { continue }
            let isSelected = cue.id == content.selectedCueID
            let isAI = cue.isAIGenerated == true
            // Grey blocks; the selection in the accent colour; text an AI tool wrote outlined in the AI tint until edited.
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            (isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.45) : NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.9)).setFill()
            path.fill()
            (isSelected ? NSColor.controlAccentColor : isAI ? NSColor.aiTint : NSColor.separatorColor).setStroke()
            path.lineWidth = isSelected ? 2 : 1
            path.stroke()
            if isSelected {
                // Edge grips.
                NSColor.controlAccentColor.setFill()
                NSRect(x: rect.minX, y: rect.minY, width: 3, height: rect.height).fill()
                NSRect(x: rect.maxX - 3, y: rect.minY, width: 3, height: rect.height).fill()
            }
            // Something to review: a dot in the corner, orange to check, purple to decide.
            let dot: NSColor? = content.attentionCueIDs.contains(cue.id) ? .attentionTint
                : content.suggestionCueIDs.contains(cue.id) ? .aiTint : nil
            if let dot, rect.width > 14 {
                dot.setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.maxX - 9, y: rect.minY + 4, width: 5, height: 5)).fill()
            }
            drawText(of: cue, in: rect.insetBy(dx: 6, dy: 3), isAI: isAI && !isSelected)
        }
    }

    /// Each visible line on its own row, cut short on its own; right-aligned for Arabic and Hebrew.
    private func drawText(of cue: Cue, in rect: NSRect, isAI: Bool) {
        guard rect.width > 12 else { return }
        let lines = SubtitleText.visibleLines(of: cue.text)
        let rows = max(min(lines.count, Int(rect.height / Self.lineHeight)), 1)
        let shown = Array(lines.prefix(rows))
        guard !shown.isEmpty else { return }
        let isRightToLeft = TextDirection.of(text: shown.joined(separator: " ")) == .rightToLeft
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = isRightToLeft ? .right : .left
        paragraph.baseWritingDirection = isRightToLeft ? .rightToLeft : .leftToRight
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: isAI ? NSColor.aiTint.blended(withFraction: 0.45, of: .labelColor) ?? .labelColor : NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        let top = rect.midY - CGFloat(shown.count) * Self.lineHeight / 2
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        for (index, line) in shown.enumerated() {
            let lineRect = NSRect(x: rect.minX, y: top + CGFloat(index) * Self.lineHeight, width: rect.width, height: Self.lineHeight)
            // A line cut off by the row limit ends with an ellipsis.
            let text = index == shown.count - 1 && lines.count > shown.count ? line + " …" : line
            (text as NSString).draw(with: lineRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawPlayhead() {
        let playheadX = (bounds.width / 2).rounded()
        NSColor.labelColor.setFill()
        NSRect(x: playheadX - 0.75, y: 0, width: 1.5, height: bounds.height).fill()
        let marker = NSBezierPath()
        marker.move(to: NSPoint(x: playheadX - 6, y: 0))
        marker.line(to: NSPoint(x: playheadX + 6, y: 0))
        marker.line(to: NSPoint(x: playheadX, y: 8))
        marker.close()
        marker.fill()
    }

    // MARK: - Mouse

    /// The cue and part under a point, preferring the selected cue's edges.
    private func hit(at point: NSPoint) -> (cue: Cue, part: CueDrag.Part)? {
        let ordered = content.cues.sorted { a, _ in a.id == content.selectedCueID }
        for cue in ordered {
            let rect = blockRect(for: cue, start: cue.start, end: cue.end)
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
        // A click here ends typing in the cue list.
        window?.makeFirstResponder(nil)
        let point = convert(event.locationInWindow, from: nil)
        if point.y > Self.rulerHeight, let (cue, part) = hit(at: point) {
            // Selecting does not move the playhead yet, so the block stays under the pointer while it is dragged.
            editor.select(cue.id, seeking: false)
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
            scrub = Scrub(startX: point.x, startCenter: centerSeconds, inRuler: point.y <= Self.rulerHeight)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if var active = scrub {
            if !active.moved, abs(point.x - active.startX) < 3 { return }
            if !active.moved {
                active.moved = true
                if editor.isPlaying { editor.perform(.pause) }
                NSCursor.closedHand.set()
            }
            scrub = active
            // Dragging the media right goes back in time.
            move(to: active.startCenter - Double(point.x - active.startX) / scale)
            return
        }
        guard var active = drag else { return }
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
            scrub = nil
            needsDisplay = true
            mouseMoved(with: event)
        }
        if let active = scrub {
            if active.moved {
                holdLocalCenter()
            } else if active.inRuler {
                // A click in the ruler goes to that time.
                move(to: seconds(atX: convert(event.locationInWindow, from: nil).x))
                holdLocalCenter()
            } else {
                // A click on empty space deselects.
                editor.select(nil)
            }
            return
        }
        guard let active = drag else { return }
        if let preview = active.preview, preview.start != active.model.start || preview.end != active.model.end {
            editor.setTiming(start: preview.start, end: preview.end, forCue: active.cueID, actionName: active.model.actionName)
        } else if active.preview == nil, let cue = content.cues.first(where: { $0.id == active.cueID }) {
            // A click (no drag) on a cue goes to it, as selecting it in the list does.
            editor.seek(toFrame: cue.start.firstFrame(at: content.frameRate))
        }
    }

    /// Puts `seconds` under the playhead: the player seeks there, and the view shows it at once.
    private func move(to seconds: Double) {
        let target = clamp(seconds)
        if content.hasMedia {
            let frame = MediaTime(seconds: target).nearestFrame(at: content.frameRate)
            localCenter = MediaTime(frame: frame, rate: content.frameRate).seconds
            releaseLocalCenter?.cancel()
            editor.seek(toFrame: frame)
        } else {
            freeCenter = target
        }
        needsDisplay = true
        invalidateAccessibility()
        reportViewport()
    }

    /// Lets the player's position take over again once it has had time to arrive.
    private func holdLocalCenter() {
        releaseLocalCenter?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, scrub == nil else { return }
            localCenter = nil
            needsDisplay = true
        }
        releaseLocalCenter = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            editor.setTimelineScale(scale * Double(1 + event.scrollingDeltaY * 0.01))
            return
        }
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        let points = event.hasPreciseScrollingDeltas ? delta : delta * 10
        guard points != 0 else { return }
        if editor.isPlaying { editor.perform(.pause) }
        move(to: centerSeconds - Double(points) / scale)
        holdLocalCenter()
    }

    /// Zooms around the playhead, which stays in the middle.
    override func magnify(with event: NSEvent) {
        editor.setTimelineScale(scale * Double(1 + event.magnification))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard drag == nil, scrub == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        if point.y <= Self.rulerHeight {
            NSCursor.pointingHand.set()
        } else {
            (hit(at: point).map { cursor(for: $0.part) } ?? .openHand).set()
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        mouseMoved(with: event)
    }

    private func cursor(for part: CueDrag.Part) -> NSCursor {
        switch part {
        case .body: drag == nil ? .arrow : .closedHand
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
            let playheadX = bounds.width / 2
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
            let rect = blockRect(for: cue, start: cue.start, end: cue.end)
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

import SubtitleCore

/// The timing a cue gets while one of its parts is dragged on the timeline.
///
/// Drags move in whole frames: the dragged edge lands on a frame start, or
/// exactly on a snap target (shot change, playhead, another cue's edge) when
/// one is within `tolerance`. Cues keep at least one frame of duration and
/// never start before zero.
struct CueDrag: Equatable {
    enum Part: Equatable {
        case body
        case inPoint
        case outPoint
    }

    let part: Part
    let start: MediaTime
    let end: MediaTime
    let rate: FrameRate
    /// The room the cue may use without overlapping its neighbours (see `EditorState.room(for:)`).
    var earliestStart: MediaTime = .zero
    var latestEnd: MediaTime?

    var actionName: String {
        switch part {
        case .body: "Move Cue"
        case .inPoint: "Trim In"
        case .outPoint: "Trim Out"
        }
    }

    /// The cue's timing after moving the pointer by `frames`.
    func timing(movedBy frames: Int64, snapTargets: [MediaTime], tolerance: MediaTime) -> (start: MediaTime, end: MediaTime) {
        let oneFrame = MediaTime(frame: 1, rate: rate)
        switch part {
        case .inPoint:
            var proposed = MediaTime(frame: max(start.firstFrame(at: rate) + frames, 0), rate: rate)
            if let target = nearest(to: proposed, in: snapTargets, within: tolerance) { proposed = target }
            let latest = MediaTime(frame: (end - oneFrame).firstFrame(at: rate), rate: rate)
            return (max(min(proposed, latest), earliestStart, .zero), end)
        case .outPoint:
            var proposed = MediaTime(frame: end.firstFrame(at: rate) + frames, rate: rate)
            if let target = nearest(to: proposed, in: snapTargets, within: tolerance) { proposed = target }
            let earliest = MediaTime(frame: (start + oneFrame).firstFrame(at: rate), rate: rate)
            if let latestEnd { proposed = min(proposed, latestEnd) }
            return (start, max(proposed, earliest))
        case .body:
            let duration = end - start
            var newStart = MediaTime(frame: max(start.firstFrame(at: rate) + frames, 0), rate: rate)
            // Snap whichever edge is closer to a target.
            let startSnap = nearest(to: newStart, in: snapTargets, within: tolerance)
            let endSnap = nearest(to: newStart + duration, in: snapTargets, within: tolerance)
            switch (startSnap, endSnap) {
            case let (s?, e?):
                newStart = distance(s, newStart) <= distance(e, newStart + duration) ? s : e - duration
            case let (s?, nil):
                newStart = s
            case let (nil, e?):
                newStart = e - duration
            case (nil, nil):
                break
            }
            if let latestEnd, newStart + duration > latestEnd { newStart = latestEnd - duration }
            newStart = max(newStart, earliestStart, .zero)
            return (newStart, newStart + duration)
        }
    }

    private func nearest(to time: MediaTime, in targets: [MediaTime], within tolerance: MediaTime) -> MediaTime? {
        targets
            .filter { distance($0, time) <= tolerance }
            .min { distance($0, time) < distance($1, time) }
    }

    private func distance(_ a: MediaTime, _ b: MediaTime) -> MediaTime {
        a < b ? b - a : a - b
    }
}

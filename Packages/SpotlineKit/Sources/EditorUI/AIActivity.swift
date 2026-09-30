import AppKit
import UserNotifications

/// AI tools outside the window: their progress on the Dock icon, and a
/// notification when one finishes or stops while Spotline is in the background.
@MainActor
final class AIActivity {
    static let shared = AIActivity()

    /// The running tool of each project window.
    private var tasks: [ObjectIdentifier: AITaskStatus] = [:]
    /// The order windows started their tools, so the Dock shows the first still running.
    private var order: [ObjectIdentifier] = []
    private var askedForNotifications = false

    func update(_ task: AITaskStatus?, for window: ObjectIdentifier) {
        if let task {
            if tasks[window] == nil {
                order.append(window)
                askForNotifications()
            }
            tasks[window] = task
        } else {
            tasks[window] = nil
            order.removeAll { $0 == window }
        }
        updateDock()
    }

    func ended(_ end: AITaskEnd) {
        guard !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = end.title
        content.body = end.message
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Asked when the first tool starts, not at launch: by then it is clear what the notifications are for.
    private func askForNotifications() {
        guard !askedForNotifications else { return }
        askedForNotifications = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func updateDock() {
        let tile = NSApp.dockTile
        if let window = order.first, let task = tasks[window] {
            let view = tile.contentView as? DockProgressView ?? DockProgressView()
            view.progress = DockProgressView.Progress(stages: task.stages.count, stage: task.stage, fraction: task.fraction)
            tile.contentView = view
        } else {
            tile.contentView = nil
        }
        tile.display()
    }
}

/// The app icon with a ring around it, a segment per stage, like the AI bar.
final class DockProgressView: NSView {
    struct Progress: Equatable {
        var stages: Int
        var stage: Int
        /// Nil when nothing measures the stage: its segment is drawn faint.
        var fraction: Double?
    }

    var progress = Progress(stages: 1, stage: 0, fraction: 0)

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)
        let inset = bounds.width * 0.06
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width / 2
        let width = bounds.width * 0.07
        let tint = NSColor.aiTint
        // A dark track so the ring reads on any icon.
        track(center: center, radius: radius, from: 0, to: 1, color: NSColor.black.withAlphaComponent(0.55), width: width + 3)
        let count = max(progress.stages, 1)
        let gap = count > 1 ? 0.015 : 0
        for index in 0..<count {
            let start = Double(index) / Double(count) + gap / 2
            let end = Double(index + 1) / Double(count) - gap / 2
            track(center: center, radius: radius, from: start, to: end, color: tint.withAlphaComponent(0.3), width: width)
            if index < progress.stage {
                track(center: center, radius: radius, from: start, to: end, color: tint, width: width)
            } else if index == progress.stage {
                if let fraction = progress.fraction {
                    track(center: center, radius: radius, from: start, to: start + (end - start) * min(max(fraction, 0), 1), color: tint, width: width)
                } else {
                    track(center: center, radius: radius, from: start, to: end, color: tint.withAlphaComponent(0.6), width: width)
                }
            }
        }
    }

    /// An arc clockwise from the top, `from` and `to` in turns (0 to 1).
    private func track(center: NSPoint, radius: CGFloat, from: Double, to: Double, color: NSColor, width: CGFloat) {
        guard to > from else { return }
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: radius, startAngle: 90 - from * 360, endAngle: 90 - to * 360, clockwise: true)
        path.lineWidth = width
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()
    }
}

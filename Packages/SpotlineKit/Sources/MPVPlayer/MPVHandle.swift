import CMPV
import Foundation

/// An error code returned by libmpv.
public struct MPVError: Error, CustomStringConvertible {
    public let code: Int32
    public let context: String

    public var description: String { "\(context): \(String(cString: mpv_error_string(code)))" }

    static func check(_ code: Int32, _ context: @autoclosure () -> String) throws {
        if code < 0 { throw MPVError(code: code, context: context()) }
    }
}

/// A property value or event read from mpv, copied out of mpv's memory.
enum MPVEvent: Sendable {
    case fileLoaded
    case fileEnded
    case propertyChanged(name: String, value: MPVValue)
}

enum MPVValue: Sendable {
    case unavailable
    case flag(Bool)
    case double(Double)
}

/// Owns an initialized `mpv_handle`.
///
/// libmpv's client API is thread-safe, so the handle can be used from any
/// thread. Events are drained on a private queue and handed to `onEvents`
/// in batches, in the order mpv produced them.
final class MPVHandle: @unchecked Sendable {
    let raw: OpaquePointer
    private let eventQueue = DispatchQueue(label: "io.github.saeedkhader.spotline.mpv-events")
    private let onEvents: @Sendable ([MPVEvent]) -> Void
    private let wakeup = WakeupRelay()

    /// Properties observed for `PlaybackStatus`, with the format mpv reports them in.
    static let observedProperties: [(name: String, format: mpv_format)] = [
        ("pause", MPV_FORMAT_FLAG),
        ("time-pos", MPV_FORMAT_DOUBLE),
        ("duration", MPV_FORMAT_DOUBLE),
        ("container-fps", MPV_FORMAT_DOUBLE),
        ("eof-reached", MPV_FORMAT_FLAG),
    ]

    init(options: KeyValuePairs<String, String>, onEvents: @escaping @Sendable ([MPVEvent]) -> Void) throws {
        guard let raw = mpv_create() else { throw MPVError(code: MPV_ERROR_NOMEM.rawValue, context: "mpv_create") }
        self.raw = raw
        self.onEvents = onEvents
        do {
            for (name, value) in options {
                try MPVError.check(mpv_set_option_string(raw, name, value), "option \(name)=\(value)")
            }
            try MPVError.check(mpv_initialize(raw), "mpv_initialize")
            for property in Self.observedProperties {
                try MPVError.check(mpv_observe_property(raw, 0, property.name, property.format), "observe \(property.name)")
            }
        } catch {
            mpv_terminate_destroy(raw)
            throw error
        }
        wakeup.handle = self
        mpv_set_wakeup_callback(raw, { context in
            guard let context else { return }
            Unmanaged<WakeupRelay>.fromOpaque(context).takeUnretainedValue().wake()
        }, Unmanaged.passUnretained(wakeup).toOpaque())
    }

    deinit {
        // No flush of `eventQueue` here: the last reference can drop inside a
        // drain block on that queue, and syncing onto it from there traps.
        // Queued drains hold the handle weakly, so they find nil once it is gone.
        mpv_set_wakeup_callback(raw, nil, nil)
        mpv_terminate_destroy(raw)
    }

    /// Runs an mpv input command such as `["seek", "1.5", "absolute+exact"]`
    /// without waiting for it. Commands run in the order they are sent.
    func command(_ arguments: [String]) {
        let owned = arguments.map { strdup($0) }
        defer { owned.forEach { free($0) } }
        var pointers: [UnsafePointer<CChar>?] = owned.map { UnsafePointer($0) } + [nil]
        let result = mpv_command_async(raw, 0, &pointers)
        if result < 0 {
            print("mpv: \(MPVError(code: result, context: arguments.joined(separator: " ")))")
        }
    }

    fileprivate func scheduleDrain() {
        eventQueue.async { [weak self] in self?.drainEvents() }
    }

    private func drainEvents() {
        var events: [MPVEvent] = []
        while let event = mpv_wait_event(raw, 0)?.pointee, event.event_id != MPV_EVENT_NONE {
            switch event.event_id {
            case MPV_EVENT_FILE_LOADED:
                events.append(.fileLoaded)
            case MPV_EVENT_END_FILE:
                events.append(.fileEnded)
            case MPV_EVENT_PROPERTY_CHANGE:
                guard let data = event.data else { continue }
                let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
                events.append(.propertyChanged(name: String(cString: property.name), value: Self.value(of: property)))
            default:
                continue
            }
        }
        if !events.isEmpty { onEvents(events) }
    }

    private static func value(of property: mpv_event_property) -> MPVValue {
        guard let data = property.data else { return .unavailable }
        switch property.format {
        case MPV_FORMAT_FLAG: return .flag(data.load(as: Int32.self) != 0)
        case MPV_FORMAT_DOUBLE: return .double(data.load(as: Double.self))
        default: return .unavailable
        }
    }
}

/// The context pointer handed to mpv's wakeup callback. It holds the handle
/// weakly so a callback racing with deinit finds nil instead of a freed object.
private final class WakeupRelay: @unchecked Sendable {
    weak var handle: MPVHandle?

    func wake() { handle?.scheduleDrain() }
}

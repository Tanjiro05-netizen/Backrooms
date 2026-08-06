import Foundation

/// A scheduled parameter curve, matching `AudioParam`'s automation.
///
/// The web build's sounds are almost entirely shaped by three calls —
/// `setValueAtTime`, `linearRampToValueAtTime`, `exponentialRampToValueAtTime` —
/// so those are the three primitives here, with the same semantics: a ramp
/// interpolates from the *previous* event's value and time, and an exponential
/// ramp is a geometric sweep, which is why the web build always ramps to
/// 0.0001 rather than 0.
public struct Envelope {
    private enum Curve { case step, linear, exponential }
    private struct Event {
        let time: Double
        let value: Float
        let curve: Curve
    }

    private var events: [Event] = []

    public init(startingAt value: Float = 0) {
        events.append(Event(time: 0, value: value, curve: .step))
    }

    public mutating func set(_ value: Float, at time: Double) {
        insert(Event(time: time, value: value, curve: .step))
    }

    public mutating func linearRamp(to value: Float, at time: Double) {
        insert(Event(time: time, value: value, curve: .linear))
    }

    /// An exponential sweep cannot reach or cross zero, so both endpoints are
    /// clamped away from it — the same reason the web build ramps to 0.0001.
    public mutating func exponentialRamp(to value: Float, at time: Double) {
        insert(Event(time: time, value: max(value, 1e-5), curve: .exponential))
    }

    private mutating func insert(_ event: Event) {
        if let last = events.last, event.time < last.time {
            // Out-of-order scheduling is a caller bug, not something to
            // silently reorder — a sound built that way would not match the
            // web build anyway. Clamp so it stays monotonic and audible.
            events.append(Event(time: last.time, value: event.value, curve: event.curve))
        } else {
            events.append(event)
        }
    }

    /// The value at `time`, holding the last event's value past the end.
    public func value(at time: Double) -> Float {
        guard let first = events.first else { return 0 }
        if time <= first.time { return first.value }

        var previous = first
        for event in events.dropFirst() {
            if time <= event.time {
                let span = event.time - previous.time
                guard span > 1e-12 else { return event.value }
                let t = Float((time - previous.time) / span)
                switch event.curve {
                case .step:
                    return previous.value
                case .linear:
                    return previous.value + (event.value - previous.value) * t
                case .exponential:
                    let from = max(previous.value, 1e-5)
                    return from * powf(event.value / from, t)
                }
            }
            previous = event
        }
        return previous.value
    }

    /// When the last scheduled event lands — how long a voice needs to live.
    public var duration: Double { events.last?.time ?? 0 }
}

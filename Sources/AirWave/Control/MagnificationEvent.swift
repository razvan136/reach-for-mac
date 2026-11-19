import CoreGraphics

/// Quartz carries the AppKit magnify subtype inside a trackpad gesture event.
/// Keep these fields isolated from the ordinary mouse event path.
enum MagnificationEvent {
    enum Phase: Int64 { case began = 1, changed = 2, ended = 4 }

    static func make(_ phase: Phase, amount: Double, at point: CGPoint, source: CGEventSource?) -> CGEvent? {
        guard let event = CGEvent(source: source),
              let gesture = CGEventType(rawValue: 29),
              let subtype = CGEventField(rawValue: 0x6e),
              let gesturePhase = CGEventField(rawValue: 0x84),
              let magnification = CGEventField(rawValue: 0x71) else { return nil }
        event.type = gesture
        event.location = point
        event.flags = []
        event.setIntegerValueField(subtype, value: 8)
        event.setIntegerValueField(gesturePhase, value: phase.rawValue)
        event.setDoubleValueField(magnification, value: amount)
        return event
    }
}

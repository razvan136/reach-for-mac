import CoreGraphics

/// Sends the displayed pointer position and gesture actions to macOS.
final class SystemInput {
    private let pointerSource = CGEventSource(stateID: .privateState)
    private let deliver: (CGEvent) -> Void
    private var position: CGPoint?
    private var dragging = false
    private var eventNumber: Int64 = 0
    private var zoomPoint: CGPoint?

    init(deliver: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }) {
        self.deliver = deliver
    }

    func move(to point: CGPoint) {
        guard position != point else { return }
        if dragging {
            guard let previous = position, let event = button(.leftMouseDragged, at: point) else { return }
            event.setIntegerValueField(.mouseEventDeltaX, value: Int64((point.x - previous.x).rounded()))
            event.setIntegerValueField(.mouseEventDeltaY, value: Int64((point.y - previous.y).rounded()))
            position = point
            deliver(event)
        } else {
            moveSystemPointer(to: point)
        }
    }

    func click(at point: CGPoint) {
        guard !dragging, zoomPoint == nil else { return }
        eventNumber += 1
        guard let down = button(.leftMouseDown, at: point),
              let up = button(.leftMouseUp, at: point) else { return }
        moveSystemPointer(to: point)
        deliver(down)
        deliver(up)
    }

    func beginDrag(at point: CGPoint) {
        guard !dragging, zoomPoint == nil else { return }
        eventNumber += 1
        guard let down = button(.leftMouseDown, at: point) else { return }
        moveSystemPointer(to: point)
        position = point
        dragging = true
        deliver(down)
    }

    func endDrag() {
        guard dragging, let position else { return }
        dragging = false
        if let event = button(.leftMouseUp, at: position) { deliver(event) }
    }

    func reset() {
        endZoom()
        endDrag()
        position = nil
    }

    /// Positive values scroll toward the top of the page.
    func scroll(pixels: Int32, at point: CGPoint) {
        guard pixels != 0,
              let event = CGEvent(scrollWheelEvent2Source: pointerSource, units: .pixel,
                                  wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0) else { return }
        event.location = point
        deliver(event)
    }

    func beginZoom(at point: CGPoint) {
        guard !dragging, zoomPoint == nil,
              let event = MagnificationEvent.make(.began, amount: 0, at: point, source: pointerSource) else { return }
        move(to: point)
        zoomPoint = point
        deliver(event)
    }

    func zoom(by amount: Double) {
        guard let point = zoomPoint,
              let event = MagnificationEvent.make(.changed, amount: amount, at: point, source: pointerSource) else { return }
        deliver(event)
    }

    func endZoom() {
        guard let point = zoomPoint else { return }
        zoomPoint = nil
        if let event = MagnificationEvent.make(.ended, amount: 0, at: point, source: pointerSource) { deliver(event) }
    }

    private func moveSystemPointer(to point: CGPoint) {
        if let event = CGEvent(mouseEventSource: pointerSource, mouseType: .mouseMoved,
                               mouseCursorPosition: point, mouseButton: .left) {
            position = point
            deliver(event)
        }
    }

    private func button(_ type: CGEventType, at point: CGPoint) -> CGEvent? {
        let event = CGEvent(mouseEventSource: pointerSource, mouseType: type,
                            mouseCursorPosition: point, mouseButton: .left)
        // A pinch always sends a primary click, even if macOS has Control latched.
        event?.flags = []
        event?.setIntegerValueField(.mouseEventNumber, value: eventNumber)
        event?.setIntegerValueField(.mouseEventClickState, value: 1)
        return event
    }
}

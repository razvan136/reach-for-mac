import CoreGraphics
import Foundation

/// Resolves a confirmed pinch into a click on release or a held mouse button.
struct PinchInteraction {
    enum Update: Equatable { case waiting, beginDrag, drag }
    enum Release: Equatable { case click, endDrag }

    private let dragHoldDuration: TimeInterval = 0.32
    private let movingDragHoldDuration: TimeInterval = 0.16
    private let maxSampleGap: TimeInterval = 0.15
    private var firmHoldDuration: TimeInterval = 0
    private var lastFirmSampleAt: TimeInterval?
    private var motionStart: (point: CGPoint, time: TimeInterval)?
    private var lastMotionPoint: CGPoint?
    private(set) var isActive = false
    private(set) var isDragging = false

    mutating func update(at time: TimeInterval, firmlyClosed: Bool, handPoint: CGPoint? = nil) -> Update {
        if isDragging { return .drag }
        isActive = true

        // A loosening pinch can still be a click. It clears the evidence of
        // a deliberate hold before macOS has received a mouse-down.
        guard firmlyClosed else {
            firmHoldDuration = 0
            pauseHold()
            return .waiting
        }
        if let previous = lastFirmSampleAt {
            let elapsed = time - previous
            guard elapsed > 0 else { return .waiting }
            if elapsed <= maxSampleGap {
                firmHoldDuration += elapsed
            } else {
                pauseHold()
            }
        }
        lastFirmSampleAt = time
        let movingDrag = handPoint.map { confirmsMovement($0, at: time) } ?? false
        guard firmHoldDuration >= dragHoldDuration || movingDrag else { return .waiting }
        isDragging = true
        return .beginDrag
    }

    mutating func pauseHold() {
        lastFirmSampleAt = nil
        motionStart = nil
        lastMotionPoint = nil
    }

    private mutating func confirmsMovement(_ point: CGPoint, at time: TimeInterval) -> Bool {
        defer { lastMotionPoint = point }
        guard let start = motionStart, let previous = lastMotionPoint else {
            motionStart = (point, time)
            return false
        }
        guard time - start.time >= movingDragHoldDuration else { return false }

        // Require two displaced observations in the same direction, so a single
        // landmark jump or small tremor can't turn a click into a drag.
        let dx = point.x - start.point.x
        let dy = point.y - start.point.y
        let priorX = previous.x - start.point.x
        let priorY = previous.y - start.point.y
        let travel = hypot(dx, dy)
        let priorTravel = hypot(priorX, priorY)
        return travel >= 18 && priorTravel >= 9 &&
            dx * priorX + dy * priorY >= 0.85 * travel * priorTravel
    }

    mutating func release() -> Release? {
        defer { cancel() }
        if isDragging { return .endDrag }
        return isActive ? .click : nil
    }

    mutating func cancel() {
        isActive = false
        isDragging = false
        firmHoldDuration = 0
        pauseHold()
    }
}

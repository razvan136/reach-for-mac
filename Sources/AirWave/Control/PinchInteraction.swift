import Foundation

/// Resolves a confirmed pinch into a click on release or a held mouse button.
struct PinchInteraction {
    enum Update: Equatable { case waiting, beginDrag, drag }
    enum Release: Equatable { case click, endDrag }

    private let dragHoldDuration: TimeInterval = 0.32
    private let maxSampleGap: TimeInterval = 0.15
    private var firmHoldDuration: TimeInterval = 0
    private var lastFirmSampleAt: TimeInterval?
    private(set) var isActive = false
    private(set) var isDragging = false

    mutating func update(at time: TimeInterval, firmlyClosed: Bool) -> Update {
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
            if elapsed > 0, elapsed <= maxSampleGap { firmHoldDuration += elapsed }
        }
        lastFirmSampleAt = time
        guard firmHoldDuration >= dragHoldDuration else { return .waiting }
        isDragging = true
        return .beginDrag
    }

    mutating func pauseHold() {
        lastFirmSampleAt = nil
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

import CoreGraphics

/// Translates a drag relative to the grab and returns to absolute aiming after a drop.
struct PrecisionCursor {
    static let dragGainRange = 0.05...0.45
    private let deadband: CGFloat = 0.8
    private var position: CGPoint?
    private var grab: (cursor: CGPoint, hand: CGPoint, display: CGRect)?
    private var resumePoint: (point: CGPoint, display: CGRect)?
    private var horizontalRecovery: RecoveryAxis?
    private var verticalRecovery: RecoveryAxis?

    var needsHandReference: Bool { resumePoint != nil }

    mutating func beginDrag(at point: CGPoint, hand: CGPoint, within display: CGRect) {
        self = PrecisionCursor()
        position = point
        grab = (point, hand, display)
    }

    mutating func resumeAiming(from point: CGPoint, within display: CGRect) {
        self = PrecisionCursor()
        position = point
        resumePoint = (point, display)
    }

    /// The hand is already mapped through the user's calibration and speed settings.
    mutating func update(raw: CGPoint, gain: Double = 1) -> CGPoint {
        if let grab {
            let gain = min(max(gain, Self.dragGainRange.lowerBound), Self.dragGainRange.upperBound)
            return track(CGPoint(
                x: Self.dragAxis(raw.x, hand: grab.hand.x, cursor: grab.cursor.x, gain: gain,
                                 bounds: grab.display.minX...(grab.display.maxX - 1)),
                y: Self.dragAxis(raw.y, hand: grab.hand.y, cursor: grab.cursor.y, gain: gain,
                                 bounds: grab.display.minY...(grab.display.maxY - 1))
            ))
        }
        if let resumePoint {
            horizontalRecovery = RecoveryAxis(cursor: resumePoint.point.x, hand: raw.x,
                                              bounds: resumePoint.display.minX...(resumePoint.display.maxX - 1))
            verticalRecovery = RecoveryAxis(cursor: resumePoint.point.y, hand: raw.y,
                                            bounds: resumePoint.display.minY...(resumePoint.display.maxY - 1))
            self.resumePoint = nil
            return resumePoint.point
        }
        let x = horizontalRecovery?.map(raw.x) ?? raw.x
        let y = verticalRecovery?.map(raw.y) ?? raw.y
        if x == raw.x { horizontalRecovery = nil }
        if y == raw.y { verticalRecovery = nil }
        return track(CGPoint(x: x, y: y))
    }

    private mutating func track(_ target: CGPoint) -> CGPoint {
        if let position, distance(target, position) < deadband { return position }
        position = target
        return target
    }

    private static func dragAxis(_ value: CGFloat, hand: CGFloat, cursor: CGFloat, gain: CGFloat,
                                 bounds: ClosedRange<CGFloat>) -> CGFloat {
        guard value != hand else { return cursor }
        let edge = value < hand ? bounds.lowerBound : bounds.upperBound
        let progress = min(1, (value - hand) / (edge - hand))
        let remainder = 1 - progress
        let taper = remainder * remainder * remainder * remainder
        // Fine adjustments near the grab, with the full reach available on either side.
        return cursor + (edge - cursor) * progress * (1 - (1 - gain) * taper)
    }

    private struct RecoveryAxis {
        private var offset: CGFloat
        private var movementReference: CGFloat
        private let correctionRate: CGFloat
        private let bounds: ClosedRange<CGFloat>

        init(cursor: CGFloat, hand: CGFloat, bounds: ClosedRange<CGFloat>) {
            offset = cursor - hand
            movementReference = hand
            correctionRate = min(0.5, abs(offset) / 140)
            self.bounds = bounds
        }

        mutating func map(_ value: CGFloat) -> CGFloat {
            // Credit intentional travel in either direction without letting idle jitter erase the offset.
            let previousReference = movementReference
            let jitterAllowance: CGFloat = 3
            movementReference = min(max(movementReference, value - jitterAllowance), value + jitterAllowance)
            let correction = min(abs(offset), abs(movementReference - previousReference) * correctionRate)
            offset += offset < 0 ? correction : -correction

            let target = value + offset
            let clamped = min(max(target, bounds.lowerBound), bounds.upperBound)
            // Discard travel beyond the display edge so the next reversal moves the cursor immediately.
            if clamped != target { offset = clamped - value }
            return clamped
        }
    }
}

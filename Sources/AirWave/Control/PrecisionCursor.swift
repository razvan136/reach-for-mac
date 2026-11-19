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
        let x = horizontalRecovery?.map(raw.x)
        let y = verticalRecovery?.map(raw.y)
        if x == nil { horizontalRecovery = nil }
        if y == nil { verticalRecovery = nil }
        return track(CGPoint(x: x ?? raw.x, y: y ?? raw.y))
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
        let offset: CGFloat
        let hand: CGFloat
        let span: CGFloat
        let bounds: ClosedRange<CGFloat>

        init(cursor: CGFloat, hand: CGFloat, bounds: ClosedRange<CGFloat>) {
            offset = cursor - hand
            self.hand = hand
            self.bounds = bounds
            // Keeps the correction slower than intentional hand travel, including near screen edges.
            span = max(140, 2 * abs(offset))
        }

        func map(_ value: CGFloat) -> CGFloat? {
            let progress = abs(value - hand) / span
            guard progress < 1 else { return nil }
            // At the edge in the direction of the offset, both mappings are already clipped to the same point.
            if (offset < 0 && value <= bounds.lowerBound) || (offset > 0 && value >= bounds.upperBound) {
                return nil
            }
            return min(max(value + offset * (1 - progress), bounds.lowerBound), bounds.upperBound)
        }
    }
}

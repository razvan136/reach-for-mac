import CoreGraphics

/// Uses the wrist and middle knuckle for the palm center. If the middle
/// knuckle disappears, reconstruct it from the neighboring knuckles using the
/// proportions most recently measured on this hand.
struct PalmAnchor {
    struct Measurement {
        let center: CGPoint
        let scale: CGFloat
    }

    private var ringOffset: CGPoint?
    private var littleOffset: CGPoint?

    mutating func reset() {
        ringOffset = nil
        littleOffset = nil
    }

    mutating func measure(_ frame: HandFrame) -> Measurement? {
        guard let wrist = frame.wrist else { return nil }
        let index = frame.points[.indexMCP].map(frame.metric)
        let ring = frame.points[.ringMCP].map(frame.metric)
        let little = frame.points[.littleMCP].map(frame.metric)

        let middle: CGPoint
        if let measured = frame.points[.middleMCP] {
            middle = frame.metric(measured)
            if let index, let ring { Self.learn(&ringOffset, middle: middle, from: index, to: ring) }
            if let index, let little { Self.learn(&littleOffset, middle: middle, from: index, to: little) }
        } else if let index, let ring {
            middle = Self.estimate(from: index, to: ring, offset: ringOffset ?? CGPoint(x: 0.5, y: 0))
        } else if let index, let little {
            middle = Self.estimate(from: index, to: little, offset: littleOffset ?? CGPoint(x: 1.0 / 3, y: 0))
        } else {
            return nil
        }

        var scale = distance(frame.metric(wrist), middle)
        if let index, let little { scale = max(scale, distance(index, little)) }
        guard scale > 0.008 else { return nil }
        let center = interpolate(wrist, CGPoint(x: middle.x / frame.aspectRatio, y: middle.y), 0.5)
        return Measurement(center: center, scale: scale)
    }

    // Store the middle knuckle in coordinates relative to the neighboring
    // knuckles so the estimate follows hand rotation and scale.
    private static func learn(_ offset: inout CGPoint?, middle: CGPoint, from index: CGPoint, to outer: CGPoint) {
        let x = outer.x - index.x
        let y = outer.y - index.y
        let lengthSquared = x * x + y * y
        guard lengthSquared > 0.00012 else { return }
        let dx = middle.x - index.x
        let dy = middle.y - index.y
        let along = (x * dx + y * dy) / lengthSquared
        let across = (x * dy - y * dx) / lengthSquared
        guard (-0.25...1.25).contains(along), abs(across) <= 0.7 else { return }
        let measured = CGPoint(x: along, y: across)
        offset = offset.map { interpolate($0, measured, 0.28) } ?? measured
    }

    private static func estimate(from index: CGPoint, to outer: CGPoint, offset: CGPoint) -> CGPoint {
        let x = outer.x - index.x
        let y = outer.y - index.y
        return CGPoint(x: index.x + x * offset.x - y * offset.y,
                       y: index.y + x * offset.y + y * offset.x)
    }
}

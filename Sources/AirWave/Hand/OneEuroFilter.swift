import CoreGraphics
import Foundation

/// Speed-adaptive smoothing with one cutoff for both axes. Sharing the cutoff
/// keeps diagonal motion from bending when one axis moves faster than the other.
final class OneEuroFilter {
    var minCutoff: Double
    private let beta: Double
    private let derivativeCutoff: Double
    private let velocityNoiseFloor = 0.17

    private struct Sample {
        let input: CGPoint
        let filtered: CGPoint
        let velocity: CGPoint
        let time: TimeInterval
    }
    private var previous: Sample?

    init(minCutoff: Double = 1.4, beta: Double = 5.5, derivativeCutoff: Double = 2.4) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    func reset() {
        previous = nil
    }

    func filter(_ point: CGPoint, at time: TimeInterval) -> CGPoint {
        guard let last = previous else {
            previous = Sample(input: point, filtered: point, velocity: .zero, time: time)
            return point
        }
        guard time > last.time else { return last.filtered }

        let dt = max(1.0 / 240.0, time - last.time)
        let derivative = CGPoint(x: (point.x - last.input.x) / dt, y: (point.y - last.input.y) / dt)
        let velocity = interpolate(last.velocity, derivative, weight(cutoff: derivativeCutoff, dt: dt))
        let speed = hypot(velocity.x, velocity.y)
        let cutoff = minCutoff + beta * max(0, speed - velocityNoiseFloor)
        let filtered = interpolate(last.filtered, point, weight(cutoff: cutoff, dt: dt))

        previous = Sample(input: point, filtered: filtered, velocity: velocity, time: time)
        return filtered
    }

    private func weight(cutoff: Double, dt: TimeInterval) -> Double {
        let scaledCutoff = 2 * Double.pi * max(0.0001, cutoff) * dt
        return scaledCutoff / (1 + scaledCutoff)
    }
}

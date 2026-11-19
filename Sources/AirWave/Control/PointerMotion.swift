import CoreGraphics
import Foundation

/// Eases the rendered pointer toward camera samples at display refresh rate.
struct PointerMotion {
    private(set) var position: CGPoint?
    private var target: CGPoint?
    private var lastStep: TimeInterval?

    var isMoving: Bool { target != nil }

    mutating func aim(at point: CGPoint, time: TimeInterval) {
        guard let position else {
            place(at: point)
            return
        }
        guard target != point else { return }
        if target == nil {
            guard distance(position, point) > 0.45 else { return }
            lastStep = time
        }
        target = point
    }

    mutating func advance(to time: TimeInterval) {
        guard let position, let target, let lastStep, time > lastStep else { return }
        let elapsed = min(time - lastStep, 1.0 / 20)
        let remaining = distance(position, target)
        // Catch up faster on large moves and ease gently into small adjustments.
        let timeConstant = 0.025 - 0.011 * min(1, remaining / 48)
        let residual = exp(-elapsed / timeConstant)
        if residual * remaining < 0.45 {
            place(at: target)
        } else {
            self.position = interpolate(position, target, 1 - residual)
            self.lastStep = time
        }
    }

    mutating func place(at point: CGPoint) {
        position = point
        freeze()
    }

    mutating func freeze() {
        target = nil
        lastStep = nil
    }
}

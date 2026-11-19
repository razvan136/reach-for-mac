import CoreGraphics
import Foundation

/// Uses palm translation while the index fingertip curls and opens around a pinch.
struct PinchTracking {
    struct Aim {
        let point: CGPoint
        let palm: CGPoint
        let time: TimeInterval
    }

    struct Reference {
        let pointer: CGPoint
        let hand: CGPoint

        private func displacement(to destination: CGPoint) -> CGPoint {
            CGPoint(x: destination.x - hand.x, y: destination.y - hand.y)
        }

        func position(following destination: CGPoint) -> CGPoint {
            let delta = displacement(to: destination)
            guard hypot(delta.x, delta.y) >= 3 else { return pointer }
            return CGPoint(x: pointer.x + delta.x, y: pointer.y + delta.y)
        }

        func continuation(afterClickAt destination: CGPoint) -> CGPoint {
            let target = position(following: destination)
            let travel = distance(pointer, target)
            guard travel > 72 else { return target }
            return interpolate(pointer, target, 72 / travel)
        }
    }

    let aim: Aim
    let approach: Reference
    var contact: Reference?

    func aim(following palm: CGPoint) -> CGPoint {
        CGPoint(x: aim.point.x + palm.x - aim.palm.x,
                y: aim.point.y + palm.y - aim.palm.y)
    }
}

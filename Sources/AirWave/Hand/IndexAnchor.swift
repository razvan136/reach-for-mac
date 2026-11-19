import CoreGraphics
import Foundation

/// Uses the visible fingertip and bridges brief occlusions with its last offset from the palm.
struct IndexAnchor {
    private var reference: (offset: CGPoint, time: TimeInterval)?

    mutating func measure(tip: CGPoint?, palm: CGPoint, at time: TimeInterval) -> CGPoint? {
        if let tip {
            reference = (CGPoint(x: tip.x - palm.x, y: tip.y - palm.y), time)
            return tip
        }
        guard let reference, time - reference.time <= 0.14 else { return nil }
        return CGPoint(x: palm.x + reference.offset.x, y: palm.y + reference.offset.y)
    }
}

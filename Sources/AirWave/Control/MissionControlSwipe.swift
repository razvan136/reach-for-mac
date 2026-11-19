import CoreGraphics
import Foundation

/// Recognizes one sideways swipe while the four-finger pose is held.
struct MissionControlSwipe {
    private var origin: CGPoint?
    private var lastSampleAt: TimeInterval?
    private var didSwipe = false

    var isActive: Bool { origin != nil }

    mutating func update(_ palm: CGPoint, at time: TimeInterval, reach: CGFloat) -> Bool {
        guard !didSwipe else { return false }
        if let lastSampleAt, time - lastSampleAt > 0.22 { origin = nil }
        lastSampleAt = time
        guard let origin else {
            origin = palm
            return false
        }

        let threshold = min(0.075, max(0.028, reach * 0.085))
        let dx = palm.x - origin.x
        let dy = abs(palm.y - origin.y)
        guard abs(dx) >= threshold, abs(dx) >= dy * 1.5 else { return false }
        didSwipe = true
        return true
    }
}

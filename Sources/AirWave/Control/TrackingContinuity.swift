import Foundation

/// A partially visible hand gets more time to recover than a hand that left
/// the camera. These are gaps between observations, never gesture durations.
struct TrackingContinuity {
    private(set) var lastConfirmed: TimeInterval?
    private var lastVisible: TimeInterval?

    mutating func sawHand(at time: TimeInterval) { lastVisible = time }

    mutating func confirmed(at time: TimeInterval) {
        sawHand(at: time)
        lastConfirmed = time
    }

    func expired(at time: TimeInterval, dragging: Bool) -> Bool {
        guard let lastConfirmed else { return false }
        if !dragging { return time - lastConfirmed >= 0.45 }
        return time - (lastVisible ?? lastConfirmed) >= 0.24 || time - lastConfirmed >= 0.55
    }
}

import Foundation

/// Watches for a stalled stream even when no hand is in view. Each outage
/// gets one automatic restart, followed by a user-visible retry if needed.
struct CameraFrameWatchdog {
    enum Timeout { case restart, needsRetry }

    private let timeout: TimeInterval = 2.5
    private var deadline: TimeInterval?
    private var restarted = false

    mutating func start(at time: TimeInterval) {
        deadline = time + timeout
        restarted = false
    }

    mutating func stop() {
        deadline = nil
        restarted = false
    }

    mutating func receivedFrame(at time: TimeInterval) {
        start(at: time)
    }

    mutating func poll(at time: TimeInterval) -> Timeout? {
        guard let deadline, time >= deadline else { return nil }
        if restarted {
            self.deadline = nil
            return .needsRetry
        }
        restarted = true
        self.deadline = time + timeout
        return .restart
    }
}

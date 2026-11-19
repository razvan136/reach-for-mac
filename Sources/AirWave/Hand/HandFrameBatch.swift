import Foundation

/// A short queue preserves gesture edges during a busy UI frame. The overlay
/// still draws once per refresh and frames too old for input are dropped.
struct HandFrameBatch {
    struct Frame {
        let hand: HandFrame?
        let secondHand: HandFrame?
        let time: TimeInterval

        init(hand: HandFrame?, secondHand: HandFrame? = nil, time: TimeInterval) {
            self.hand = hand
            self.secondHand = secondHand
            self.time = time
        }
    }

    static let maxAge: TimeInterval = 0.20
    private let capacity = 4
    private var frames: [Frame] = []
    private var latestTime: TimeInterval?

    mutating func append(_ frame: Frame) {
        if let latestTime, frame.time <= latestTime { return }
        latestTime = frame.time
        if frames.count == capacity { frames.removeFirst() }
        frames.append(frame)
    }

    mutating func take() -> [Frame] {
        let batch = frames
        frames = []
        return batch
    }

    static func isFresh(_ time: TimeInterval, at now: TimeInterval) -> Bool {
        let age = now - time
        return (0..<maxAge).contains(age)
    }
}

import CoreGraphics
import Foundation

/// Owns both pinches through release so lifting either hand cannot become a click.
struct TwoHandZoom {
    enum Update: Equatable {
        case idle, captured, began(CGPoint), changed(Double), ended, released
    }

    private struct Grip {
        enum Contact { case closed, open, uncertain }

        let thumbAndIndex: CGPoint
        let wrist: CGPoint
        let scale: CGFloat
        let canStart: Bool
        let contact: Contact

        init?(_ hand: HandFrame) {
            var anchor = PalmAnchor()
            guard let wrist = hand.wrist, let palm = anchor.measure(hand),
                  let thumb = hand.thumbTip, let index = hand.indexTip,
                  let pinch = PinchGeometry(frame: hand, scale: palm.scale) else { return nil }
            self.wrist = hand.metric(wrist)
            scale = palm.scale
            thumbAndIndex = interpolate(thumb, index, 0.5)
            canStart = pinch.canStart
            if pinch.hasReliableTips, pinch.gap >= 0.26 || pinch.looksRelaxed {
                contact = .open
            } else if pinch.hasReliableTips, pinch.gap <= 0.235, pinch.retainsContactShape {
                contact = .closed
            } else {
                contact = .uncertain
            }
        }
    }

    private struct Pair {
        let midpoint: CGPoint
        let span: CGFloat
        let minimumSpan: CGFloat

        init?(_ first: Grip?, _ second: Grip?, frame: HandFrame?) {
            guard let first, let second, let frame,
                  distance(first.wrist, second.wrist) > min(first.scale, second.scale) * 0.45 else { return nil }
            midpoint = interpolate(first.thumbAndIndex, second.thumbAndIndex, 0.5)
            span = distance(frame.metric(first.thumbAndIndex), frame.metric(second.thumbAndIndex))
            minimumSpan = max(0.035, (first.scale + second.scale) * 0.25)
        }
    }

    private struct Motion {
        private let gain = 0.8
        let minimumSpan: CGFloat
        var lastSampleAt: TimeInterval
        var filtered: Double
        var sent: Double

        init(pair: Pair, time: TimeInterval) {
            minimumSpan = pair.minimumSpan
            lastSampleAt = time
            filtered = log(hypot(pair.span, minimumSpan))
            sent = filtered
        }

        mutating func update(span: CGFloat, at time: TimeInterval) -> Double? {
            let sample = log(hypot(span, minimumSpan))
            let elapsed = time - lastSampleAt
            guard elapsed > 0 else { return nil }
            lastSampleAt = time
            if elapsed > 0.10 {
                // Resume at the observed distance after occlusion without a catch-up zoom.
                filtered = sample
                sent = sample
                return nil
            }
            filtered += (sample - filtered) * (1 - exp(-elapsed / 0.055))
            let remaining = (filtered - sent) * gain
            guard abs(remaining) >= 0.012 else { return nil }
            let change = min(max(remaining, -0.09), 0.09)
            sent += change / gain
            return expm1(change)
        }
    }

    private enum State { case idle, confirming(TimeInterval), active(Motion), releasing }
    private var state = State.idle

    var isCaptured: Bool {
        if case .idle = state { return false }
        return true
    }

    mutating func update(_ firstHand: HandFrame?, _ secondHand: HandFrame?, at time: TimeInterval) -> Update {
        if secondHand == nil, !isCaptured { return .idle }
        let first = firstHand.flatMap(Grip.init)
        let second = secondHand.flatMap(Grip.init)
        let pair = Pair(first, second, frame: firstHand)
        let canStart = pair != nil && first?.canStart == true && second?.canStart == true

        switch state {
        case .idle:
            guard canStart else { return .idle }
            state = .confirming(time)
            return .captured
        case .confirming(let previous):
            guard canStart, let pair else {
                state = .releasing
                return .captured
            }
            guard time > previous, time - previous <= 0.15 else {
                state = .confirming(time)
                return .captured
            }
            state = .active(Motion(pair: pair, time: time))
            return .began(pair.midpoint)
        case .active(var motion):
            if first?.contact == .open || second?.contact == .open || time - motion.lastSampleAt > 0.18 {
                state = .releasing
                return .ended
            }
            guard let pair, first?.contact == .closed, second?.contact == .closed else { return .captured }
            let amount = motion.update(span: pair.span, at: time)
            state = .active(motion)
            return amount.map(Update.changed) ?? .captured
        case .releasing:
            if (firstHand == nil || first?.contact == .open), (secondHand == nil || second?.contact == .open) {
                state = .idle
                return .released
            }
            return .captured
        }
    }
}

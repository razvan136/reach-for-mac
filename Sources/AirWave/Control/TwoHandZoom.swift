import CoreGraphics
import Foundation

/// Owns both pinches through release so lifting either hand cannot become a click.
struct TwoHandZoom {
    enum Update: Equatable {
        case idle, confirming, began(CGPoint), ready, changed(Double), paused, ended, releasing, released
    }

    private struct Grip {
        enum Contact { case closed, open, wideOpen, uncertain }

        let palm: CGPoint
        let wrist: CGPoint
        let scale: CGFloat
        let pinchPoint: CGPoint?
        let canStart: Bool
        let contact: Contact

        init?(_ hand: HandFrame) {
            var anchor = PalmAnchor()
            guard let wrist = hand.wrist, let palm = anchor.measure(hand) else { return nil }
            self.palm = palm.center
            self.wrist = hand.metric(wrist)
            scale = palm.scale
            if let thumb = hand.thumbTip, let index = hand.indexTip {
                pinchPoint = interpolate(thumb, index, 0.5)
            } else {
                pinchPoint = nil
            }
            guard let pinch = PinchGeometry(frame: hand, scale: palm.scale), pinch.hasReliableTips else {
                canStart = false
                contact = .uncertain
                return
            }
            // Two distinct pinches can use a little more tolerance than a click.
            // Nearly coincident tips still count when Vision misses a finger joint.
            let touching = pinch.retainsContactShape || (!pinch.hasAlignment && pinch.gap <= 0.075)
            if pinch.gap >= 0.37 {
                contact = .wideOpen
            } else if pinch.gap >= 0.27 || pinch.looksRelaxed {
                contact = .open
            } else {
                contact = touching && pinch.gap <= 0.24 ? .closed : .uncertain
            }
            canStart = contact == .closed && pinch.gap <= 0.20
        }
    }

    private struct Pair {
        let first: Grip
        let second: Grip
        let aspect: CGFloat

        var canStart: Bool { first.canStart && second.canStart }
        var midpoint: CGPoint {
            interpolate(first.pinchPoint ?? first.palm, second.pinchPoint ?? second.palm, 0.5)
        }
        var minimumSpan: CGFloat { max(0.035, (first.scale + second.scale) * 0.25) }

        init?(_ first: Grip?, _ second: Grip?, aspect: CGFloat) {
            guard let first, let second,
                  distance(first.wrist, second.wrist) > min(first.scale, second.scale) * 0.32 else { return nil }
            self.init(first: first, second: second, aspect: aspect)
        }

        private init(first: Grip, second: Grip, aspect: CGFloat) {
            self.first = first
            self.second = second
            self.aspect = aspect
        }

        func aligned(to previous: Pair) -> Pair {
            let direct = distance(first.wrist, previous.first.wrist) + distance(second.wrist, previous.second.wrist)
            let reversed = distance(first.wrist, previous.second.wrist) + distance(second.wrist, previous.first.wrist)
            return direct <= reversed ? self : Pair(first: second, second: first, aspect: aspect)
        }
    }

    private struct Motion {
        private let gain = 0.8
        private let minimumSpan: CGFloat
        private let firstOffset: CGPoint
        private let secondOffset: CGPoint
        private var previous: Pair
        private var lastSampleAt: TimeInterval
        private var firstClosedAt: TimeInterval
        private var secondClosedAt: TimeInterval
        private var filtered: Double
        private var sent: Double
        private var missedPair = false
        var sawOpening = false

        init(pair: Pair, time: TimeInterval) {
            let first = pair.first.pinchPoint ?? pair.first.palm
            let second = pair.second.pinchPoint ?? pair.second.palm
            firstOffset = CGPoint(x: first.x - pair.first.palm.x, y: first.y - pair.first.palm.y)
            secondOffset = CGPoint(x: second.x - pair.second.palm.x, y: second.y - pair.second.palm.y)
            minimumSpan = pair.minimumSpan
            previous = pair
            lastSampleAt = time
            firstClosedAt = time
            secondClosedAt = time
            filtered = Self.logSpan(x: (first.x - second.x) * pair.aspect,
                                    y: first.y - second.y, minimum: minimumSpan)
            sent = filtered
        }

        mutating func update(_ pair: Pair?, at time: TimeInterval) -> Update {
            let elapsed = time - lastSampleAt
            guard elapsed > 0 else { return .ready }
            guard let pair else {
                missedPair = true
                return elapsed <= 0.26 ? .paused : .ended
            }

            let aligned = pair.aligned(to: previous)
            if aligned.first.contact == .closed { firstClosedAt = time }
            if aligned.second.contact == .closed { secondClosedAt = time }
            guard time - firstClosedAt <= 0.40, time - secondClosedAt <= 0.40 else { return .ended }
            previous = aligned
            lastSampleAt = time

            // Keep each starting pinch point attached to its palm. Tip jitter
            // and brief finger occlusion don't interrupt movement or change span.
            let dx = (aligned.first.palm.x + firstOffset.x) - (aligned.second.palm.x + secondOffset.x)
            let dy = (aligned.first.palm.y + firstOffset.y) - (aligned.second.palm.y + secondOffset.y)
            let sample = Self.logSpan(x: dx * aligned.aspect, y: dy, minimum: minimumSpan)
            defer { missedPair = false }
            if missedPair && elapsed > 0.13 {
                filtered = sample
                sent = sample
                return .ready
            }
            filtered += (sample - filtered) * (1 - exp(-elapsed / 0.045))
            let remaining = (filtered - sent) * gain
            guard abs(remaining) >= 0.008 else { return .ready }
            let change = min(max(remaining, -0.09), 0.09)
            sent += change / gain
            return .changed(expm1(change))
        }

        private static func logSpan(x: CGFloat, y: CGFloat, minimum: CGFloat) -> Double {
            0.5 * log(x * x + y * y + minimum * minimum)
        }
    }

    private enum State { case idle, confirming(Pair, TimeInterval), active(Motion), releasing }
    private var state = State.idle

    var isCaptured: Bool {
        if case .idle = state { return false }
        return true
    }

    mutating func update(_ firstHand: HandFrame?, _ secondHand: HandFrame?, at time: TimeInterval) -> Update {
        if secondHand == nil, !isCaptured { return .idle }
        let first = firstHand.flatMap(Grip.init)
        let second = secondHand.flatMap(Grip.init)
        let pair = Pair(first, second, aspect: firstHand?.aspectRatio ?? 1)
        let opening = first?.contact == .open || second?.contact == .open
        let wideOpen = first?.contact == .wideOpen || second?.contact == .wideOpen

        switch state {
        case .idle:
            guard let pair, pair.canStart else { return .idle }
            state = .confirming(pair, time)
            return .confirming
        case .confirming(let start, let previous):
            if pair != nil, !opening, !wideOpen, (first?.contact == .closed || second?.contact == .closed),
               time > previous, time - previous <= 0.20 {
                state = .active(Motion(pair: start, time: time))
                return .began(start.midpoint)
            }
            if let pair, pair.canStart, time - previous > 0.20 {
                state = .confirming(pair, time)
                return .confirming
            }
            if wideOpen || time - previous > 0.20 {
                state = .idle
                return .released
            }
            return .confirming
        case .active(var motion):
            if wideOpen || (opening && motion.sawOpening) {
                state = .releasing
                return .ended
            }
            motion.sawOpening = opening
            let update = opening ? .paused : motion.update(pair, at: time)
            state = update == .ended ? .releasing : .active(motion)
            return update
        case .releasing:
            if first?.contact != .closed, second?.contact != .closed {
                state = .idle
                return .released
            }
            return .releasing
        }
    }
}

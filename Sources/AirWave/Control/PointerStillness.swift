import CoreGraphics
import Foundation

/// Holds the visible pointer when recent samples cluster without sustained travel.
struct PointerStillness {
    private struct Sample {
        let point: CGPoint
        let time: TimeInterval
    }

    private struct Hold {
        let center: CGPoint
        let visible: CGPoint
        let wakeDistance: CGFloat
    }

    private var samples: [Sample] = []
    private var lastTime: TimeInterval?
    private var hold: Hold?
    private var departure: (delta: CGPoint, length: CGFloat, count: Int)?

    var isSteady: Bool { hold != nil }

    mutating func update(_ point: CGPoint, visible: CGPoint?, at time: TimeInterval) -> CGPoint {
        if let lastTime, time - lastTime > 0.14 { self = PointerStillness() }
        lastTime = time

        if let hold { return updateHold(hold, point: point, at: time) }

        samples.append(Sample(point: point, time: time))
        while samples.count > 2 && time - samples[1].time >= 0.20 {
            samples.removeFirst()
        }
        guard samples.count >= 4, time - samples[0].time >= 0.19 else { return point }

        let mid = samples.count / 2
        let earlier = Self.center(of: samples[..<mid])
        let recent = Self.center(of: samples[mid...])
        guard distance(earlier, recent) <= 3.6 else { return point }

        let center = Self.center(of: samples[...])
        let radii = samples.map { distance($0.point, center) }.sorted()
        guard radii[radii.count * 3 / 4] <= 8 else { return point }

        let held = visible ?? point
        let wakeDistance = min(5.2, max(3.2, 0.85 * radii[radii.count / 2]))
        hold = Hold(center: center, visible: held, wakeDistance: wakeDistance)
        samples.removeAll(keepingCapacity: true)
        return held
    }

    private mutating func updateHold(_ hold: Hold, point: CGPoint, at time: TimeInterval) -> CGPoint {
        let delta = CGPoint(x: point.x - hold.center.x, y: point.y - hold.center.y)
        let length = hypot(delta.x, delta.y)
        guard length >= hold.wakeDistance else {
            departure = nil
            return hold.visible
        }

        var count = 1
        if let departure {
            let alignment = delta.x * departure.delta.x + delta.y * departure.delta.y
            if alignment >= 0.75 * length * departure.length {
                count = departure.count + 1
                // Let sustained small adjustments through, and wake sooner for a broad move.
                if count >= 3 || (length >= 8 && departure.length >= 6) {
                    self.hold = nil
                    self.departure = nil
                    samples.append(Sample(point: point, time: time))
                    return point
                }
            }
        }
        departure = (delta, length, count)
        return hold.visible
    }

    private static func center(of samples: ArraySlice<Sample>) -> CGPoint {
        func median(_ values: [CGFloat]) -> CGFloat {
            let sorted = values.sorted()
            return (sorted[(sorted.count - 1) / 2] + sorted[sorted.count / 2]) * 0.5
        }
        return CGPoint(x: median(samples.map(\.point.x)), y: median(samples.map(\.point.y)))
    }
}

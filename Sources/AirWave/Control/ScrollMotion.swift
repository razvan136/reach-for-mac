import CoreGraphics
import Foundation

/// Scrolls at a rate proportional to how far the hand moves from its starting height.
struct ScrollMotion {
    private let deadZone: CGFloat = 0.025
    private var center: CGFloat?
    private var lastTime: TimeInterval?
    private var filteredOffset: CGFloat = 0
    private var remainder: CGFloat = 0

    var isActive: Bool { center != nil }

    mutating func update(y: CGFloat, at time: TimeInterval, reach: CGFloat, speed: CGFloat) -> Int32 {
        guard let center else {
            center = y
            lastTime = time
            return 0
        }
        let elapsed = lastTime.map { min(time - $0, 1.0 / 15) } ?? 0
        lastTime = time
        guard elapsed > 0 else { return 0 }

        let offset = (center - y) / max(0.25, reach)
        if abs(offset) <= deadZone || offset * filteredOffset < 0 {
            filteredOffset = 0
            remainder = 0
        }
        guard abs(offset) > deadZone else { return 0 }
        filteredOffset += (offset - filteredOffset) * (1 - exp(-elapsed / 0.055))
        let amount = min(1, max(0, abs(filteredOffset) - deadZone) / 0.21)
        let rate = 1300 * speed * amount * (0.30 + 0.70 * amount)
        remainder += (offset > 0 ? rate : -rate) * elapsed
        let pixels = Int32(remainder.rounded(.towardZero))
        remainder -= CGFloat(pixels)
        return pixels
    }

    mutating func pause() {
        lastTime = nil
    }
}

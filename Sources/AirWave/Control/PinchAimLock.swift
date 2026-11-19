import Foundation

/// Keeps index-finger aim fixed during the brief movement into a pinch.
struct PinchAimLock {
    private var recent: [(evidence: PinchGeometry.AimEvidence, time: TimeInterval)] = []
    private var lastClosingAt: TimeInterval?

    mutating func shouldHold(_ evidence: PinchGeometry.AimEvidence?, at time: TimeInterval) -> Bool {
        recent.removeAll { time - $0.time > 0.11 }
        if let evidence {
            let opening = recent.last.map { evidence.gap - $0.evidence.gap >= 0.055 } ?? false
            if opening || evidence.gap > 0.95 {
                lastClosingAt = nil
                recent.removeAll(keepingCapacity: true)
            } else if evidence.gap <= 0.90, recent.contains(where: { previous in
                // Both changes are measured relative to hand size. Translating
                // the hand or keeping the fingers close won't meet both tests.
                previous.evidence.gap - evidence.gap >= 0.035 &&
                    previous.evidence.indexReach - evidence.indexReach >= 0.022
            }) {
                lastClosingAt = time
                recent.removeAll(keepingCapacity: true)
            }
            recent.append((evidence, time))
        }
        return lastClosingAt.map { time - $0 < 0.12 } ?? false
    }
}

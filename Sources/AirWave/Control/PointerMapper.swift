import CoreGraphics
import Foundation

/// Where your hand reaches, in normalized camera space.
struct Calibration: Codable, Equatable {
    var minX: Double = 0.18
    var maxX: Double = 0.82
    var minY: Double = 0.28
    var maxY: Double = 0.84

    static let `default` = Calibration()

    var width: Double { max(0.05, maxX - minX) }
    var height: Double { max(0.05, maxY - minY) }

    /// Grows the box to include a sampled point.
    mutating func include(_ point: CGPoint) {
        minX = min(minX, Double(point.x))
        maxX = max(maxX, Double(point.x))
        minY = min(minY, Double(point.y))
        maxY = max(maxY, Double(point.y))
    }

    func normalized(_ point: CGPoint) -> CGPoint {
        let nx = (Double(point.x) - minX) / width
        let ny = (Double(point.y) - minY) / height
        return CGPoint(x: min(max(0, nx), 1), y: min(max(0, ny), 1))
    }
}

/// Maps the aiming point onto the main display, with smoothing.
final class PointerMapper {
    static let defaultSmoothing = 0.62

    var calibration: Calibration {
        didSet { filter.reset() }
    }
    var smoothing: Double {
        didSet { filter.minCutoff = Self.cutoff(for: smoothing) }
    }

    private let filter: OneEuroFilter

    init(calibration: Calibration = .default, smoothing: Double = PointerMapper.defaultSmoothing) {
        self.calibration = calibration
        self.smoothing = smoothing
        filter = OneEuroFilter(minCutoff: Self.cutoff(for: smoothing))
    }

    static func smoothing(fromLegacyCutoff cutoff: Double) -> Double {
        log(6 / min(max(cutoff, 0.4), 6)) / log(15)
    }

    private static func cutoff(for smoothing: Double) -> Double {
        3 * pow(10, -min(max(smoothing, 0), 1))
    }

    func map(_ handPoint: CGPoint, onto display: CGRect, timestamp: TimeInterval, speed: Double = 1.0) -> CGPoint {
        let normalized = calibration.normalized(handPoint)
        let smoothed = filter.filter(normalized, at: timestamp)

        // Preserve full reach without a sharp rise in sensitivity at the edges.
        let gain = min(max(speed, 0.01), 2)
        func shape(_ value: CGFloat) -> CGFloat {
            let centered = value * 2 - 1
            let adjusted = centered * (gain + (1 - gain) * abs(centered))
            return (adjusted + 1) * 0.5
        }

        return CGPoint(
            x: display.minX + shape(smoothed.x) * display.width,
            y: display.minY + shape(smoothed.y) * display.height
        )
    }

    func resetFilters() {
        filter.reset()
    }
}

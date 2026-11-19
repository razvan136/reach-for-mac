import CoreGraphics
import Vision

/// Hand landmarks in normalized, mirrored camera coordinates with a top-left origin.
struct HandFrame {
    var points: [VNHumanHandPoseObservation.JointName: CGPoint] = [:]
    var aspectRatio: CGFloat = 1
    var thumbIndexConfidence: Float = 1
    var indexTipConfidence: Float = 1

    var indexTip: CGPoint? { points[.indexTip] }
    var aimTip: CGPoint? { indexTipConfidence >= 0.36 ? indexTip : nil }
    var thumbTip: CGPoint? { points[.thumbTip] }
    var wrist: CGPoint? { points[.wrist] }

    /// Distances and angles should use camera pixels with equal horizontal and vertical units.
    func metric(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * aspectRatio, y: point.y)
    }
}

func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    hypot(a.x - b.x, a.y - b.y)
}

func interpolate(_ a: CGPoint, _ b: CGPoint, _ fraction: CGFloat) -> CGPoint {
    CGPoint(x: a.x + (b.x - a.x) * fraction, y: a.y + (b.y - a.y) * fraction)
}

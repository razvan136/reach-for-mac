import CoreGraphics
import Vision

/// Evidence for thumb-to-index contact in the camera image. A small tip gap
/// alone also occurs when the two fingers lie next to each other.
struct PinchGeometry {
    struct AimEvidence {
        let gap: CGFloat
        let indexReach: CGFloat
    }

    private struct Alignment {
        let cosine: CGFloat
        let jointGap: CGFloat
    }

    let gap: CGFloat
    private let confidence: Float
    private let alignment: Alignment?

    init?(frame: HandFrame, scale: CGFloat) {
        guard let thumb = frame.thumbTip.map(frame.metric),
              let index = frame.indexTip.map(frame.metric) else { return nil }
        gap = distance(thumb, index) / scale
        confidence = frame.thumbIndexConfidence
        alignment = Self.alignment(in: frame, thumb: thumb, index: index, scale: scale)
    }

    var hasReliableTips: Bool { confidence >= 0.32 }
    var hasAlignment: Bool { alignment != nil }
    var canStart: Bool { confidence >= 0.44 && gap <= 0.18 && converges }
    var isFirm: Bool { confidence >= 0.40 && gap <= 0.16 && converges }
    var canRearm: Bool { hasReliableTips && gap >= 0.29 }

    func aimEvidence(in frame: HandFrame, palmScale: CGFloat) -> AimEvidence? {
        guard confidence >= 0.36, let tip = frame.aimTip, let knuckle = frame.points[.indexMCP] else {
            return nil
        }
        let reach = distance(frame.metric(tip), frame.metric(knuckle)) / palmScale
        return AimEvidence(gap: gap, indexReach: reach)
    }

    var retainsContactShape: Bool {
        guard let alignment else { return false }
        return alignment.cosine <= 0.86 && alignment.jointGap >= max(0.075, gap * 1.12)
    }

    var looksRelaxed: Bool {
        guard let alignment else { return false }
        return alignment.cosine > 0.82 && alignment.jointGap < max(0.09, gap * 1.18)
    }

    private var converges: Bool {
        guard let alignment else { return false }
        return alignment.cosine <= 0.72 && alignment.jointGap >= max(0.10, gap * 1.35)
    }

    private static func alignment(in frame: HandFrame, thumb: CGPoint, index: CGPoint,
                                  scale: CGFloat) -> Alignment? {
        guard let thumbJoint = frame.points[.thumbIP].map(frame.metric),
              let indexJoint = (frame.points[.indexDIP] ?? frame.points[.indexPIP]).map(frame.metric) else {
            return nil
        }
        let thumbAxis = CGPoint(x: thumb.x - thumbJoint.x, y: thumb.y - thumbJoint.y)
        let indexAxis = CGPoint(x: index.x - indexJoint.x, y: index.y - indexJoint.y)
        let lengthProduct = hypot(thumbAxis.x, thumbAxis.y) * hypot(indexAxis.x, indexAxis.y)
        guard lengthProduct >= 0.004 * scale * scale else { return nil }
        let cosine = (thumbAxis.x * indexAxis.x + thumbAxis.y * indexAxis.y) / lengthProduct
        return Alignment(cosine: cosine, jointGap: distance(thumbJoint, indexJoint) / scale)
    }
}

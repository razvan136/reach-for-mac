import CoreGraphics
import Vision

enum HandGesture: Equatable {
    case none, aim, pinch, scroll, missionControl, zoom

    var label: String {
        switch self {
        case .none: return "Idle"
        case .aim: return "Aim"
        case .pinch: return "Pinch"
        case .scroll: return "Peace sign"
        case .missionControl: return "Four fingers"
        case .zoom: return "Two-hand zoom"
        }
    }

    var hint: String {
        switch self {
        case .none: return "Open your hand or point to move"
        case .aim: return "Move the pointer"
        case .pinch: return "Release to click or keep pinching and move to drag"
        case .scroll: return "Move up or down from where you started the pose"
        case .missionControl: return "Swipe down to open Mission Control"
        case .zoom: return "Move the pinches apart or together"
        }
    }
}

struct GestureSample {
    let gesture: HandGesture
    let palmCenter: CGPoint
    let indexTip: CGPoint?
    var isFirmPinch = false
    var pinchAimEvidence: PinchGeometry.AimEvidence?
}

/// Movement tolerates partial finger occlusion. Click and scroll require stronger
/// evidence because an uncertain pose should never trigger an action.
final class GestureRecognizer {
    private enum Finger { case straight, curled, bent, unknown }
    private let pinchReleaseGap: CGFloat = 0.26
    private let dragReleaseGap: CGFloat = 0.235
    private var palmAnchor = PalmAnchor()
    private var stable: HandGesture = .none
    private var candidate: HandGesture = .none
    private var waitingForPinchRelease = false
    private var sawOpenPinch = false
    private var missionControlGraceFrames = 0

    private(set) var pendingPinch: GestureSample?
    var isConfirmingPinch: Bool { pendingPinch != nil }
    var isConfirmingMissionControl: Bool { candidate == .missionControl && stable != .missionControl }

    func reset(requiringPinchRelease: Bool = false) {
        stable = .none
        palmAnchor.reset()
        waitingForPinchRelease = waitingForPinchRelease || requiringPinchRelease
        missionControlGraceFrames = 0
        missedFrame()
    }

    func missedFrame() {
        candidate = .none
        sawOpenPinch = false
        pendingPinch = nil
    }

    func processed(_ frame: HandFrame, dragging: Bool = false) -> GestureSample? {
        pendingPinch = nil
        guard let palm = palmAnchor.measure(frame) else {
            missedFrame()
            return nil
        }

        let pinch = PinchGeometry(frame: frame, scale: palm.scale)
        if waitingForPinchRelease, pinch?.canRearm == true {
            waitingForPinchRelease = false
        }

        if stable == .pinch {
            return continuePinch(pinch, frame: frame, palm: palm, dragging: dragging)
        }

        let raw: HandGesture
        if pinch?.canStart == true {
            raw = waitingForPinchRelease ? .none : .pinch
        } else {
            raw = pose(in: frame, palmScale: palm.scale)
        }

        if raw != stable {
            let confirmed = raw == candidate
            candidate = raw
            if confirmed || raw == .aim && stable == .none {
                stable = raw
            } else {
                if raw == .pinch {
                    pendingPinch = GestureSample(gesture: .pinch, palmCenter: palm.center,
                                                 indexTip: frame.aimTip, isFirmPinch: pinch?.isFirm == true)
                }
                return nil
            }
        } else {
            candidate = raw
        }

        return GestureSample(gesture: stable, palmCenter: palm.center, indexTip: frame.aimTip,
                             isFirmPinch: stable == .pinch && pinch?.isFirm == true,
                             pinchAimEvidence: stable == .aim ? pinch?.aimEvidence(in: frame, palmScale: palm.scale) : nil)
    }

    private func continuePinch(_ pinch: PinchGeometry?, frame: HandFrame,
                               palm: PalmAnchor.Measurement, dragging: Bool) -> GestureSample? {
        let reliable = pinch?.hasReliableTips == true ? pinch : nil
        let releaseGap = dragging ? dragReleaseGap : pinchReleaseGap
        let visiblyOpen = dragging && (reliable == nil || (reliable?.gap ?? 0) >= 0.44)
            && isClearlyOpen(frame)

        if let reliable, reliable.gap <= releaseGap {
            guard reliable.hasAlignment else {
                sawOpenPinch = false
                return nil
            }
            if reliable.retainsContactShape {
                sawOpenPinch = false
                return GestureSample(gesture: .pinch, palmCenter: palm.center,
                                     indexTip: frame.aimTip, isFirmPinch: reliable.isFirm)
            }
            if dragging, !reliable.looksRelaxed {
                sawOpenPinch = false
                return nil
            }
        }

        guard reliable != nil || visiblyOpen else {
            sawOpenPinch = false
            return nil
        }
        // A clear, visible opening can drop immediately. Smaller separations,
        // a relaxed finger shape, and an obscured thumb need a second frame.
        guard sawOpenPinch || (visiblyOpen && reliable != nil) else {
            sawOpenPinch = true
            return nil
        }
        stable = .none
        sawOpenPinch = false
        waitingForPinchRelease = reliable?.canRearm != true
        candidate = pose(in: frame, palmScale: palm.scale)
        return GestureSample(gesture: .none, palmCenter: palm.center, indexTip: frame.aimTip)
    }

    private func isClearlyOpen(_ frame: HandFrame) -> Bool {
        finger(.indexMCP, .indexPIP, .indexTip, in: frame) == .straight &&
            finger(.middleMCP, .middlePIP, .middleTip, in: frame) == .straight &&
            (finger(.ringMCP, .ringPIP, .ringTip, in: frame) == .straight ||
             finger(.littleMCP, .littlePIP, .littleTip, in: frame) == .straight)
    }

    private func finger(_ base: VNHumanHandPoseObservation.JointName,
                        _ joint: VNHumanHandPoseObservation.JointName,
                        _ tip: VNHumanHandPoseObservation.JointName, in frame: HandFrame,
                        palmScale: CGFloat? = nil) -> Finger {
        guard let start = frame.points[base], let end = frame.points[tip] else { return .unknown }
        guard let middle = frame.points[joint] else {
            guard let palmScale else { return .unknown }
            let reach = distance(frame.metric(start), frame.metric(end)) / palmScale
            if reach >= 0.68 { return .straight }
            if reach <= 0.25 { return .curled }
            return .unknown
        }
        let a = frame.metric(CGPoint(x: middle.x - start.x, y: middle.y - start.y))
        let b = frame.metric(CGPoint(x: end.x - middle.x, y: end.y - middle.y))
        let lengths = hypot(a.x, a.y) * hypot(b.x, b.y)
        guard lengths > 0.00002 else { return .unknown }
        let cosine = (a.x * b.x + a.y * b.y) / lengths
        if cosine > 0.35 { return .straight }
        if cosine < -0.20 { return .curled }
        return .bent
    }

    private func pose(in frame: HandFrame, palmScale: CGFloat) -> HandGesture {
        let index = finger(.indexMCP, .indexPIP, .indexTip, in: frame, palmScale: palmScale)
        let middle = finger(.middleMCP, .middlePIP, .middleTip, in: frame, palmScale: palmScale)
        let ring = finger(.ringMCP, .ringPIP, .ringTip, in: frame, palmScale: palmScale)
        let little = finger(.littleMCP, .littlePIP, .littleTip, in: frame, palmScale: palmScale)
        if isMissionControlPose(in: frame, fingers: [index, middle, ring, little]) {
            return .missionControl
        }
        if ring != .straight, little != .straight {
            let bothRaised = index == .straight && middle == .straight
            let outerFolded = ring == .curled || little == .curled
            if bothRaised, outerFolded, ring != .unknown, little != .unknown { return .scroll }
            if stable == .scroll, index != .curled, middle != .curled {
                let aRaisedFingerRemains = index == .straight || middle == .straight
                let outerFingersHidden = ring == .unknown && little == .unknown
                if (aRaisedFingerRemains && outerFolded) || (bothRaised && outerFingersHidden) {
                    return .scroll
                }
            }
        }
        if middle == .curled, ring == .curled, little == .curled {
            return index == .straight ? .aim : .none
        }
        return .aim
    }

    private func isMissionControlPose(in frame: HandFrame, fingers: [Finger]) -> Bool {
        let raised = fingers.filter { $0 == .straight }.count
        let folded = thumbIsFolded(in: frame)
        if raised >= 3, !fingers.contains(.curled), !fingers.contains(.unknown), folded == true {
            missionControlGraceFrames = 3
            return true
        }
        // Once confirmed, tolerate a brief occlusion while the hand moves.
        if stable == .missionControl, raised >= 3, !fingers.contains(.curled), folded != false,
           missionControlGraceFrames > 0 {
            missionControlGraceFrames -= 1
            return true
        }
        missionControlGraceFrames = 0
        return false
    }

    private func thumbIsFolded(in frame: HandFrame) -> Bool? {
        guard frame.thumbIndexConfidence >= 0.32, let thumb = frame.thumbTip.map(frame.metric),
              let wrist = frame.wrist.map(frame.metric),
              let index = frame.points[.indexMCP].map(frame.metric),
              let little = frame.points[.littleMCP].map(frame.metric) else { return nil }
        let knuckles = interpolate(index, little, 0.5)

        func projection(from origin: CGPoint, toward end: CGPoint) -> CGFloat {
            let x = end.x - origin.x
            let y = end.y - origin.y
            let lengthSquared = x * x + y * y
            guard lengthSquared > 0.0001 else { return -.infinity }
            return ((thumb.x - origin.x) * x + (thumb.y - origin.y) * y) / lengthSquared
        }
        // Measure against the palm's own axes so either hand can make the pose.
        let across = projection(from: index, toward: little)
        let along = projection(from: wrist, toward: knuckles)
        guard (0.14...1.10).contains(along) else { return false }
        if (0.08...1.12).contains(across) { return true }
        return (-0.24...1.12).contains(across) &&
            finger(.thumbMP, .thumbIP, .thumbTip, in: frame) == .curled
    }
}

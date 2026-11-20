import AppKit
import CoreGraphics
import Vision

/// Deterministic checks that don't need a camera, a screen cursor, or any permission.
/// Run with `Reach --selftest` (exit code 0 = all good).
enum SelfTest {
    private static var failures = 0

    private static func check(_ name: String, _ condition: Bool) {
        print("\(condition ? "PASS" : "FAIL")  \(name)")
        if !condition { failures += 1 }
    }

    private static func near(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 0.5) -> Bool {
        abs(a - b) <= tolerance
    }

    static func run() -> Bool {
        failures = 0
        print("Reach self-test\n")

        testGestures()
        testPinchHysteresis()
        testPinchEvidence()
        testPinchAimLock()
        testPinchActions()
        testMovingPinch()
        testTwoHandZoom()
        testDragRelease()
        testTrackingContinuity()
        testSustainedDrag()
        testCameraWatchdog()
        testStandardPinch()
        testFrameBatch()
        testMouseEvents()
        testMagnificationEvents()
        testScrollPose()
        testScrollMotion()
        testMissionControlSwipe()
        testCursorBadges()
        testCalibration()
        testCalibrationPreview()
        testMapping()
        testFilter()
        testSmoothingControl()
        testPrecisionCursor()
        testPointerMotion()
        testPointerStillness()
        testIndexAnchor()
        testPoses()

        print("\n\(failures == 0 ? "All checks passed" : "\(failures) check(s) failed")")
        return failures == 0
    }

    // MARK: - Gestures

    private static func settle(_ recognizer: GestureRecognizer, with frame: HandFrame, times: Int = 4) -> HandGesture {
        var result: HandGesture = .none
        for _ in 0..<times { result = recognizer.processed(frame)?.gesture ?? .none }
        return result
    }

    private static func testGestures() {
        check("pointing can aim the cursor with the other fingers curled",
              settle(GestureRecognizer(), with: Fixture.pointing()) == .aim)
        check("open palm is recognised",
              settle(GestureRecognizer(), with: Fixture.palm()) == .aim)
        check("two-finger pose is recognised",
              settle(GestureRecognizer(), with: Fixture.twoFingers()) == .scroll)

        let recognizer = GestureRecognizer()
        check("a single pinch frame cannot click",
              recognizer.processed(Fixture.pinching()) == nil)
        check("a second pinch frame confirms the gesture",
              recognizer.processed(Fixture.pinching())?.gesture == .pinch)
        check("missing hand landmarks produce no observation",
              recognizer.processed(HandFrame()) == nil)

        let quick = GestureRecognizer()
        _ = quick.processed(Fixture.palm())
        check("an isolated apparent contact after an open hand cannot start a pinch",
              quick.processed(Fixture.pinching()) == nil)
        check("first contact exposes the palm and can anchor aim before a click is eligible",
              quick.isConfirmingPinch && quick.pendingPinch?.isFirmPinch == true)
        check("two frames of clear contact after an open hand start a pinch",
              quick.processed(Fixture.pinching())?.gesture == .pinch && !quick.isConfirmingPinch)
    }

    private static func testPinchHysteresis() {
        let recognizer = GestureRecognizer()
        check("pinch engages when the fingertips touch",
              settle(recognizer, with: Fixture.pinching(), times: 2) == .pinch)

        // Inside the hysteresis band: already pinching, so it must stay pinched.
        let loosePinch = recognizer.processed(Fixture.pinching(gap: 0.22))
        check("a loosening pinch stays active without qualifying for a drag",
              loosePinch?.gesture == .pinch && loosePinch?.isFirmPinch == false)

        var occluded = Fixture.pinching()
        occluded.points.removeValue(forKey: .thumbTip)
        check("an occluded thumb does not release a pinch",
              recognizer.processed(occluded) == nil)
        check("an observed pinch resumes after short occlusion",
              recognizer.processed(Fixture.pinching(gap: 0.22))?.gesture == .pinch)

        check("one open-looking frame does not release a pinch",
              recognizer.processed(Fixture.pinching(gap: 1.2)) == nil)
        check("pinch releases when the fingertips stay apart",
              recognizer.processed(Fixture.pinching(gap: 1.2))?.gesture == HandGesture.none)

        recognizer.reset(requiringPinchRelease: true)
        check("an interrupted pinch cannot reengage while held",
              settle(recognizer, with: Fixture.pinching()) == .none)
        _ = recognizer.processed(Fixture.palm())
        check("opening the hand rearms the next pinch",
              settle(recognizer, with: Fixture.pinching()) == .pinch)
    }

    private static func testPinchEvidence() {
        for frame in [Fixture.pinching(gap: 0.30), Fixture.parallelTips()] {
            check("nearby fingertips without contact evidence cannot start a pinch",
                  settle(GestureRecognizer(), with: frame, times: 20) != .pinch)
        }
        var uncertain = Fixture.pinching()
        uncertain.thumbIndexConfidence = 0.31
        check("low-confidence contact cannot engage a pinch",
              settle(GestureRecognizer(), with: uncertain) != .pinch)

        let soft = GestureRecognizer()
        _ = settle(soft, with: Fixture.pinching(gap: 0.17))
        let softSample = soft.processed(Fixture.pinching(gap: 0.17))
        check("borderline contact can click but cannot accumulate drag hold time",
              softSample?.gesture == .pinch && softSample?.isFirmPinch == false)

        let recognizer = GestureRecognizer()
        _ = settle(recognizer, with: Fixture.pinching(gap: 0.10))
        check("opposed tips at a small visible gap count as a firm pinch",
              recognizer.processed(Fixture.pinching(gap: 0.10))?.isFirmPinch == true)
        var hiddenJoint = Fixture.pinching()
        hiddenJoint.points.removeValue(forKey: .thumbIP)
        check("missing alignment pauses a pinch without confirming a release",
              recognizer.processed(hiddenJoint, dragging: true) == nil)
    }

    private static func testPinchAimLock() {
        func translate(_ frame: HandFrame) -> HandFrame {
            var moved = frame
            for (joint, point) in frame.points {
                moved.points[joint] = CGPoint(x: point.x + 0.03, y: point.y + 0.04)
            }
            return moved
        }

        func closingHand(gap: CGFloat, retraction: CGFloat) -> HandFrame {
            var frame = Fixture.pinching(gap: gap)
            for joint in [VNHumanHandPoseObservation.JointName.indexTip, .indexDIP, .thumbTip, .thumbIP] {
                if let point = frame.points[joint] {
                    frame.points[joint] = CGPoint(x: point.x, y: point.y + retraction)
                }
            }
            return frame
        }

        let recognizer = GestureRecognizer()
        var lock = PinchAimLock()
        let pointing = Fixture.pointing()
        let initial = recognizer.processed(pointing)
        check("an index pointing pose can move normally",
              initial?.pinchAimEvidence != nil && !lock.shouldHold(initial?.pinchAimEvidence, at: 0))

        let translated = translate(pointing)
        let moved = recognizer.processed(translated)
        check("moving the whole hand down does not lock aim",
              !lock.shouldHold(moved?.pinchAimEvidence, at: 1.0 / 30))

        let mapper = PointerMapper(calibration: AimPoint.indexFinger.defaultCalibration)
        let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let index = translated.aimTip ?? .zero
        let palm = moved?.palmCenter ?? .zero
        let target = mapper.map(index, onto: display, timestamp: 1.0 / 30)
        let approachReference = PinchTracking.Reference(pointer: target, hand: target)
        let tracking = PinchTracking(aim: .init(point: index, palm: palm, time: 1.0 / 30),
                                     approach: approachReference)
        var motion = PointerMotion()
        motion.place(at: target)
        var heldBeforeContact = true
        let approach = [closingHand(gap: 0.68, retraction: 0.017),
                        closingHand(gap: 0.40, retraction: 0.034),
                        closingHand(gap: 0.25, retraction: 0.050)].map(translate)
        for (index, frame) in approach.enumerated() {
            let time = Double(index + 2) / 30
            let sample = recognizer.processed(frame)
            let holds = lock.shouldHold(sample?.pinchAimEvidence, at: time)
            heldBeforeContact = heldBeforeContact && holds && sample?.gesture == .aim
            if holds, let sample {
                let aim = tracking.aim(following: sample.palmCenter)
                let projected = mapper.project(aim, onto: display, speed: 1)
                motion.aim(at: tracking.approach.position(following: projected), time: time)
            } else if let tip = sample?.indexTip {
                motion.aim(at: mapper.map(tip, onto: display, timestamp: time), time: time)
            }
            motion.advance(to: time + 1.0 / 60)
        }
        check("curling the index toward the thumb holds the displayed target before contact",
              heldBeforeContact && motion.position == target)

        let closingWhileMoving = recognizer.processed(translate(approach[2]))
        if let closingWhileMoving {
            let aim = tracking.aim(following: closingWhileMoving.palmCenter)
            let projected = mapper.project(aim, onto: display, speed: 1)
            let movedTarget = tracking.approach.position(following: projected)
            check("aim follows the moving palm while the index finger curls",
                  closingWhileMoving.gesture == .aim &&
                  near(movedTarget.x, target.x + 0.03 * display.width / mapper.calibration.width) &&
                  near(movedTarget.y, target.y + 0.04 * display.height / mapper.calibration.height))
        } else {
            check("aim follows the moving palm while the index finger curls", false)
        }

        var abandoned = lock
        let heldNearby = recognizer.processed(approach[2])
        for frame in 5..<9 {
            _ = abandoned.shouldHold(heldNearby?.pinchAimEvidence, at: Double(frame) / 30)
        }
        check("holding the fingers close without touching lets aim move again",
              heldNearby?.gesture == .aim && !abandoned.shouldHold(heldNearby?.pinchAimEvidence, at: 0.30))

        let reopened = recognizer.processed(translated)
        check("opening without a click restores aiming immediately",
              !lock.shouldHold(reopened?.pinchAimEvidence, at: 5.0 / 30))

        var gradual = PinchAimLock()
        let slowApproach = [closingHand(gap: 0.82, retraction: 0),
                            closingHand(gap: 0.80, retraction: 0.003),
                            closingHand(gap: 0.78, retraction: 0.006)]
        let graduallyHeld = slowApproach.enumerated().map { frame, observation in
            gradual.shouldHold(recognizer.processed(observation)?.pinchAimEvidence, at: Double(frame) / 60)
        }
        check("gradual closing registers across several faster camera frames", graduallyHeld == [false, false, true])

        let touching = translate(closingHand(gap: 0.06, retraction: 0.060))
        _ = recognizer.processed(touching)
        var pinch = PinchInteraction()
        if let contact = recognizer.processed(touching), contact.gesture == .pinch {
            _ = pinch.update(at: 0.5, firmlyClosed: contact.isFirmPinch)
        }
        _ = recognizer.processed(translated)
        let release = recognizer.processed(translated)
        var sent: [CGEvent] = []
        let mouse = SystemInput { sent.append($0) }
        if release?.gesture == HandGesture.none, pinch.release() == .click, let point = motion.position {
            mouse.click(at: point)
        }
        let buttons = sent.filter { $0.type == .leftMouseDown || $0.type == .leftMouseUp }
        check("touching and releasing clicks once at the aim point before the index curled",
              buttons.map(\.type) == [.leftMouseDown, .leftMouseUp] &&
              buttons.allSatisfy { distance($0.location, target) < 0.01 })
    }

    private static func testTwoHandZoom() {
        func grip(x: CGFloat, angle: CGFloat, gap: CGFloat = 0) -> HandFrame {
            var hand = Fixture.pinching(gap: gap)
            let center = interpolate(hand.thumbTip!, hand.indexTip!, 0.5)
            for (joint, point) in hand.points {
                let dx = point.x - center.x
                let dy = point.y - center.y
                hand.points[joint] = CGPoint(x: x + cos(angle) * dx - sin(angle) * dy,
                                             y: 0.43 + sin(angle) * dx + cos(angle) * dy)
            }
            return hand
        }

        let left = grip(x: 0.49, angle: 0.72)
        let right = grip(x: 0.51, angle: -0.72)
        let leftOpen = grip(x: 0.37, angle: 0.72, gap: 0.9)
        let rightOpen = grip(x: 0.63, angle: -0.72, gap: 0.9)
        var zoom = TwoHandZoom()
        check("one pinch and an open hand remain available to single-hand actions",
              zoom.update(left, rightOpen, at: 0) == .idle)
        check("duplicated observations of a single hand cannot start zoom",
              zoom.update(left, left, at: 0.025) == .idle)
        check("a candidate pair suppresses one-hand actions before zoom begins",
              zoom.update(left, right, at: 0.05) == .confirming && zoom.isCaptured)
        let begin = zoom.update(left, right, at: 0.083)
        check("a confirmed pair can begin with the two pinches nearly touching",
              begin == .began(CGPoint(x: 0.5, y: 0.43)))

        var outward = 0.0
        for index in 1...9 {
            let offset = Double(index) * 0.02
            let handLeft = grip(x: 0.49 - offset, angle: 0.72)
            let handRight = grip(x: 0.51 + offset, angle: -0.72)
            // Vision may return the two observations in a different order.
            if case .changed(let value) = zoom.update(handRight, handLeft, at: 0.083 + Double(index) / 30) {
                outward += value
            }
        }
        check("spreading the pinches progressively zooms in", outward > 0.3)

        var inward = 0.0
        var seconds = 0.383
        for index in 1...15 {
            seconds += 1.0 / 30
            let offset = max(0, 0.18 - Double(index) * 0.018)
            if case .changed(let value) = zoom.update(grip(x: 0.49 - offset, angle: 0.72),
                                                     grip(x: 0.51 + offset, angle: -0.72), at: seconds) {
                inward += value
            }
        }
        check("bringing the same pinches together reverses zoom", inward < -0.25)
        check("a brief occlusion holds the current zoom", zoom.update(left, nil, at: seconds + 0.035) == .paused)
        check("a returning hand does not deliver a large catch-up zoom",
              zoom.update(left, right, at: seconds + 0.142) == .ready)
        check("opening either pinch ends magnification immediately",
              zoom.update(leftOpen, right, at: seconds + 0.18) == .ended)
        check("the remaining pinch is suppressed until it opens",
              zoom.update(leftOpen, right, at: seconds + 0.22) == .releasing)
        check("opening both hands restores single-hand control",
              zoom.update(leftOpen, rightOpen, at: seconds + 0.25) == .released && !zoom.isCaptured)

        var softLeft = left
        var softRight = right
        softLeft.thumbIndexConfidence = 0.36
        softRight.thumbIndexConfidence = 0.38
        check("two distinct near-touching grips can prime zoom with lower landmark confidence",
              zoom.update(softLeft, softRight, at: 2) == .confirming)
        check("an obscured hand during confirmation does not lock out the pair",
              zoom.update(softLeft, nil, at: 2.04) == .confirming)
        var hiddenThumb = grip(x: 0.34, angle: 0.72)
        hiddenThumb.points.removeValue(forKey: .thumbTip)
        let expandedRight = grip(x: 0.66, angle: -0.72)
        check("both visible palms can confirm after one grip's fingertips are briefly hidden",
              zoom.update(hiddenThumb, expandedRight, at: 2.08) == .began(CGPoint(x: 0.5, y: 0.43)))
        if case .changed(let amount) = zoom.update(hiddenThumb, expandedRight, at: 2.12) {
            check("outward travel during confirmation still zooms in", amount > 0)
        } else {
            check("outward travel during confirmation still zooms in", false)
        }

        zoom = TwoHandZoom()
        _ = zoom.update(left, right, at: 3)
        _ = zoom.update(left, right, at: 3.13)
        var sparseChanges = 0
        for index in 1...7 {
            let spread = Double(index) * 0.02
            var a = grip(x: 0.49 - spread, angle: 0.72)
            var b = grip(x: 0.51 + spread, angle: -0.72)
            if index.isMultiple(of: 2) {
                a.points.removeValue(forKey: .thumbTip)
            } else {
                b.points.removeValue(forKey: .indexTip)
            }
            if case .changed(let amount) = zoom.update(b, a, at: 3.13 + Double(index) * 0.13), amount > 0 {
                sparseChanges += 1
            }
        }
        check("alternating fingertip loss and slower camera frames still produce sustained zoom", sparseChanges >= 6)
        let gap = grip(x: 0.35, angle: 0.72, gap: 0.29)
        let farRight = grip(x: 0.65, angle: -0.72)
        check("a single small apparent opening pauses without ending the zoom",
              zoom.update(gap, farRight, at: 4.08) == .paused)
        check("a confirmed opening ends the zoom",
              zoom.update(gap, farRight, at: 4.12) == .ended)
    }

    private static func testPinchActions() {
        var pinch = PinchInteraction()
        check("a pinch starts without pressing the mouse button",
              pinch.update(at: 0, firmlyClosed: true) == .waiting)
        _ = pinch.update(at: 0.13, firmlyClosed: true)
        check("a pinch held past the old drag threshold still waits",
              pinch.update(at: 0.26, firmlyClosed: true) == .waiting)
        check("a quick release clicks once", pinch.release() == .click)
        check("release after a completed click does nothing", pinch.release() == nil)

        _ = pinch.update(at: 1, firmlyClosed: true)
        _ = pinch.update(at: 1.1, firmlyClosed: true)
        _ = pinch.update(at: 1.2, firmlyClosed: true)
        check("a held pinch waits for the new drag threshold",
              pinch.update(at: 1.31, firmlyClosed: true) == .waiting)
        check("a firm pinch starts a drag after the threshold",
              pinch.update(at: 1.34, firmlyClosed: true) == .beginDrag)
        check("a partial opening during a drag does not press the button again",
              pinch.update(at: 1.4, firmlyClosed: false) == .drag)
        check("releasing a drag only releases the mouse button", pinch.release() == .endDrag)

        _ = pinch.update(at: 2, firmlyClosed: true)
        _ = pinch.update(at: 2.13, firmlyClosed: true)
        _ = pinch.update(at: 2.25, firmlyClosed: true)
        check("opening near the threshold keeps the pinch eligible for a click",
              pinch.update(at: 2.33, firmlyClosed: false) == .waiting)
        check("a brief tightening after fingers start opening cannot trigger a drag",
              pinch.update(at: 2.37, firmlyClosed: true) == .waiting)
        check("a loosening pinch still clicks when released", pinch.release() == .click)

        _ = pinch.update(at: 3, firmlyClosed: true)
        _ = pinch.update(at: 3.13, firmlyClosed: true)
        pinch.pauseHold()
        check("a moment without confirmed contact does not count toward the drag",
              pinch.update(at: 3.26, firmlyClosed: true) == .waiting &&
              pinch.update(at: 3.33, firmlyClosed: true) == .waiting)
        pinch.cancel()
        check("losing a pending pinch does not click", pinch.release() == nil)

        _ = pinch.update(at: 4, firmlyClosed: true)
        check("one stale interval cannot start a drag",
              pinch.update(at: 4.34, firmlyClosed: true) == .waiting)
        _ = pinch.update(at: 4.45, firmlyClosed: true)
        _ = pinch.update(at: 4.56, firmlyClosed: true)
        _ = pinch.update(at: 4.67, firmlyClosed: true)
        pinch.cancel()
        check("canceling clears a drag", !pinch.isActive && !pinch.isDragging)
    }

    private static func testMovingPinch() {
        func point(_ x: CGFloat, _ y: CGFloat = 200) -> CGPoint { CGPoint(x: 300 + x, y: y) }

        var quick = PinchInteraction()
        let quickUpdates = (0...4).map { frame in
            quick.update(at: Double(frame) / 30, firmlyClosed: true, handPoint: point(CGFloat(frame) * 10))
        }
        check("a quick moving pinch still clicks once on release",
              quickUpdates.allSatisfy { $0 == .waiting } && quick.release() == .click && quick.release() == nil)

        var moving = PinchInteraction()
        let movingUpdates = (0...5).map { frame in
            moving.update(at: Double(frame) / 30, firmlyClosed: true, handPoint: point(CGFloat(frame) * 5))
        }
        check("sustained travel starts a firm drag after five 30 fps intervals",
              Array(movingUpdates.prefix(5)) == Array(repeating: .waiting, count: 5) &&
              movingUpdates.last == .beginDrag)
        check("continued movement keeps one drag active until release",
              moving.update(at: 0.20, firmlyClosed: true, handPoint: point(46)) == .drag &&
              moving.release() == .endDrag && moving.release() == nil)

        var soft = PinchInteraction()
        let softUpdates = (0...15).map { frame in
            soft.update(at: Double(frame) / 30, firmlyClosed: false, handPoint: point(CGFloat(frame) * 6))
        }
        check("moving with a soft pinch never presses the drag button",
              softUpdates.allSatisfy { $0 == .waiting } && soft.release() == .click)

        var shaky = PinchInteraction()
        let jitter: [CGFloat] = [0, 4, -3, 3, -10, 44, -3]
        let jitterUpdates = jitter.enumerated().map { frame, dx in
            shaky.update(at: Double(frame) / 30, firmlyClosed: true, handPoint: point(dx))
        }
        check("a single large outlier amid offset reversals cannot accelerate a drag",
              jitterUpdates.allSatisfy { $0 == .waiting } && shaky.release() == .click)

        var interrupted = PinchInteraction()
        _ = interrupted.update(at: 0, firmlyClosed: true, handPoint: point(0))
        _ = interrupted.update(at: 0.13, firmlyClosed: true, handPoint: point(12))
        interrupted.pauseHold()
        check("a tracking gap clears fast-drag evidence from previous motion",
              interrupted.update(at: 0.20, firmlyClosed: true, handPoint: point(62)) == .waiting &&
              interrupted.update(at: 0.25, firmlyClosed: true, handPoint: point(66)) == .waiting &&
              interrupted.release() == .click)

        let contact = PinchTracking.Reference(pointer: point(0), hand: point(11))
        check("a stationary click ignores small palm changes during release",
              contact.continuation(afterClickAt: point(13)) == point(0))
        check("a moving click resumes in the direction the palm traveled",
              contact.continuation(afterClickAt: point(37, 190)) == point(26, 190))
        check("a large catch-up after a click is bounded from its original target",
              near(distance(contact.continuation(afterClickAt: point(180, 300)), contact.pointer), 72))
    }

    private static func testDragRelease() {
        let recognizer = GestureRecognizer()
        _ = settle(recognizer, with: Fixture.pinching())
        let partial = Fixture.pinching(gap: 0.25)
        check("one partial separation is not enough to drop",
              recognizer.processed(partial, dragging: true) == nil)
        check("two partial separations drop without opening the fingers as far",
              recognizer.processed(partial, dragging: true)?.gesture == HandGesture.none)
        check("a near release does not immediately reengage on the next contact",
              settle(recognizer, with: Fixture.pinching()) != .pinch)

        _ = settle(recognizer, with: Fixture.palm())
        _ = settle(recognizer, with: Fixture.pinching())
        check("a clearly open palm drops on the first frame",
              recognizer.processed(Fixture.palm(), dragging: true)?.gesture == HandGesture.none)

        _ = settle(recognizer, with: Fixture.pinching())
        check("a single wide gap without an open hand does not drop",
              recognizer.processed(Fixture.pinching(gap: 1.2), dragging: true) == nil)
        check("an outlier followed by a closed pinch continues the drag",
              recognizer.processed(Fixture.pinching(), dragging: true)?.gesture == .pinch)

        _ = recognizer.processed(Fixture.parallelTips(), dragging: true)
        check("a nearby parallel pair releases an active drag",
              recognizer.processed(Fixture.parallelTips(), dragging: true)?.gesture == HandGesture.none)

        _ = settle(recognizer, with: Fixture.palm())
        _ = settle(recognizer, with: Fixture.pinching())
        var openWithoutThumb = Fixture.palm()
        openWithoutThumb.points.removeValue(forKey: .thumbTip)
        _ = recognizer.processed(openWithoutThumb, dragging: true)
        check("an open palm can drop even with the thumb occluded",
              recognizer.processed(openWithoutThumb, dragging: true)?.gesture == HandGesture.none)
        check("an occluded release does not immediately rearm another pinch",
              settle(recognizer, with: Fixture.pinching()) == .none)
    }

    private static func testStandardPinch() {
        let recognizer = GestureRecognizer()
        check("the former L-shaped selection pose can only aim",
              settle(recognizer, with: Fixture.thumbAndIndexOut()) == .aim)
        check("standard thumb-to-index contact works with the other fingers curled",
              settle(recognizer, with: Fixture.pinching()) == .pinch)
    }

    private static func testTrackingContinuity() {
        for dragging in [false, true] {
            var tracking = TrackingContinuity()
            var expired = false
            for frame in 0..<900 {
                let time = Double(frame) / 30
                expired = expired || tracking.expired(at: time, dragging: dragging)
                tracking.confirmed(at: time)
            }
            check("steady \(dragging ? "drag" : "tracking") survives thirty seconds", !expired)
        }

        var tracking = TrackingContinuity()
        tracking.confirmed(at: 0)
        tracking.sawHand(at: 0.20)
        tracking.sawHand(at: 0.40)
        check("a partly obscured hand gets time to recover a drag", !tracking.expired(at: 0.45, dragging: true))
        check("uncertain contact eventually releases a drag", tracking.expired(at: 0.56, dragging: true))
        tracking.confirmed(at: 1)
        check("a hand leaving the camera releases faster", tracking.expired(at: 1.25, dragging: true))
    }

    private static func testSustainedDrag() {
        let recognizer = GestureRecognizer()
        var tracking = TrackingContinuity()
        var pinch = PinchInteraction()
        var obscured = Fixture.pinching()
        obscured.points.removeValue(forKey: .thumbIP)
        var interrupted = false
        for frame in 0..<600 {
            let time = Double(frame) / 30
            if tracking.expired(at: time, dragging: pinch.isDragging) { interrupted = true }
            tracking.sawHand(at: time)
            let hand = (frame % 150 >= 90 && frame % 150 < 102) ? obscured : Fixture.pinching(gap: 0.07)
            guard let sample = recognizer.processed(hand, dragging: pinch.isDragging) else {
                pinch.pauseHold()
                continue
            }
            if sample.gesture != .pinch { interrupted = true; break }
            tracking.confirmed(at: time)
            _ = pinch.update(at: time, firmlyClosed: sample.isFirmPinch)
        }
        check("a sustained drag survives repeated short alignment gaps", !interrupted && pinch.isDragging)
        let opening = recognizer.processed(Fixture.palm(), dragging: pinch.isDragging)
        check("a deliberate opening still ends a continued drag promptly",
              opening?.gesture == HandGesture.none && pinch.release() == .endDrag)
    }

    private static func testCameraWatchdog() {
        var watchdog = CameraFrameWatchdog()
        watchdog.start(at: 1)
        watchdog.receivedFrame(at: 3)
        check("live frames postpone camera recovery", watchdog.poll(at: 4) == nil)
        check("a stalled stream gets an automatic restart", watchdog.poll(at: 5.6) == .restart)
        check("continued failure offers manual retry", watchdog.poll(at: 8.2) == .needsRetry)
        check("a stalled camera cannot start a restart loop", watchdog.poll(at: 20) == nil)
        watchdog.receivedFrame(at: 21)
        check("frames returning after a stall restore the watchdog", watchdog.poll(at: 24) == .restart)
        watchdog.stop()
        check("pausing the camera cancels recovery", watchdog.poll(at: 28) == nil)
    }

    private static func testMouseEvents() {
        var sent: [CGEvent] = []
        let mouse = SystemInput { sent.append($0) }
        let point = CGPoint(x: 300, y: 200)
        let destination = CGPoint(x: 400, y: 250)
        mouse.move(to: point)
        mouse.move(to: point)
        mouse.move(to: destination)
        check("the system receives hover movement only when the displayed pointer moves",
              sent.map(\.type) == [.mouseMoved, .mouseMoved] && sent.map(\.location) == [point, destination])
        mouse.reset()
        mouse.move(to: destination)
        check("resuming controls resynchronizes the mouse at the same location",
              sent.count == 3 && sent.last?.location == destination)

        sent.removeAll()
        mouse.click(at: point)
        let buttons = sent.filter { $0.type == .leftMouseDown || $0.type == .leftMouseUp }
        check("a click sends a down and up at the Reach pointer",
              buttons.map(\.type) == [.leftMouseDown, .leftMouseUp] &&
              buttons.allSatisfy { $0.location == point })
        check("gesture clicks carry no modifier that could turn them into secondary clicks",
              buttons.allSatisfy { $0.flags.isEmpty })
        check("the mouse button pair is identified as one click",
              buttons.count == 2 && buttons.allSatisfy { $0.getIntegerValueField(.mouseEventClickState) == 1 } &&
              buttons[0].getIntegerValueField(.mouseEventNumber) == buttons[1].getIntegerValueField(.mouseEventNumber))

        sent.removeAll()
        mouse.beginDrag(at: point)
        mouse.move(to: point)
        mouse.move(to: destination)
        mouse.move(to: destination)
        mouse.endDrag()
        mouse.endDrag()
        mouse.move(to: destination)
        check("drag reports movement and releases once at the last position",
              sent.map(\.type) == [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp] &&
              sent.last?.location == destination)
        check("drag movement carries its signed distance from the prior cursor location",
              sent.first { $0.type == .leftMouseDragged }.map {
                  $0.getIntegerValueField(.mouseEventDeltaX) == 100 &&
                  $0.getIntegerValueField(.mouseEventDeltaY) == 50
              } == true)
    }

    private static func testMagnificationEvents() {
        var events: [CGEvent] = []
        let input = SystemInput { events.append($0) }
        let point = CGPoint(x: 160, y: 130)
        input.beginZoom(at: point)
        input.click(at: point)
        input.beginDrag(at: point)
        input.zoom(by: 0.10)
        input.zoom(by: -0.07)
        input.reset()
        input.endZoom()
        let native = events.compactMap { NSEvent(cgEvent: $0) }.filter { $0.type == .magnify }
        check("zoom sends one native begin, two changes, and one end",
              native.map(\.phase) == [.began, .changed, .changed, .ended])
        check("zoom events carry signed magnification amounts",
              native.count == 4 && near(native[1].magnification, 0.10, 0.0001) &&
              near(native[2].magnification, -0.07, 0.0001))
        check("active magnification sends no mouse-button events",
              !events.contains { $0.type == .leftMouseDown || $0.type == .leftMouseUp })
    }

    private static func testFrameBatch() {
        var frames = HandFrameBatch()
        for index in 0..<6 {
            frames.append(.init(hand: nil, time: Double(index) / 30))
        }
        frames.append(.init(hand: nil, time: 0))
        check("a busy UI keeps a bounded, ordered set of recent frames",
              frames.take().map(\.time) == (2..<6).map { Double($0) / 30 })
        frames.append(.init(hand: nil, time: 5.0 / 30))
        check("a duplicate frame cannot be replayed after delivery", frames.take().isEmpty)
        check("stale and future frames are rejected",
              !HandFrameBatch.isFresh(1, at: 1.25) && !HandFrameBatch.isFresh(2, at: 1.99) &&
              HandFrameBatch.isFresh(1, at: 1.1))

        let recognizer = GestureRecognizer()
        _ = recognizer.processed(Fixture.palm())
        for (index, hand) in [Fixture.pinching(), Fixture.pinching(), Fixture.palm(), Fixture.palm()].enumerated() {
            frames.append(.init(hand: hand, time: 1 + Double(index) / 30))
        }
        var pinch = PinchInteraction()
        var action: PinchInteraction.Release?
        for frame in frames.take() {
            guard let hand = frame.hand, let sample = recognizer.processed(hand) else { continue }
            if sample.gesture == .pinch {
                _ = pinch.update(at: frame.time, firmlyClosed: sample.isFirmPinch)
            } else if pinch.isActive {
                action = pinch.release()
            }
        }
        check("a pinch and release delivered together still click", action == .click)
    }

    private static func testScrollPose() {
        let recognizer = GestureRecognizer()
        let pose = Fixture.twoFingers()
        check("a scroll pose needs confirmation before it activates", recognizer.processed(pose) == nil)
        check("two raised fingers confirm a scroll pose", recognizer.processed(pose)?.gesture == .scroll)
        var partlyHidden = pose
        partlyHidden.points.removeValue(forKey: .ringTip)
        partlyHidden.points.removeValue(forKey: .middleTip)
        check("a held peace sign survives an obscured raised finger and an obscured curled finger",
              recognizer.processed(partlyHidden)?.gesture == .scroll)
        check("opening the remaining fingers exits scroll", settle(recognizer, with: Fixture.palm()) == .aim)

        var relaxed = pose
        if let ring = pose.points[.ringPIP] {
            relaxed.points[.ringTip] = CGPoint(x: ring.x + 0.06, y: ring.y)
        }
        relaxed.points.removeValue(forKey: .middlePIP)
        check("a peace sign works with a partly bent ring finger and a hidden middle joint",
              settle(GestureRecognizer(), with: relaxed) == .scroll)

        var openWithMissingTips = Fixture.palm()
        openWithMissingTips.points.removeValue(forKey: .ringTip)
        openWithMissingTips.points.removeValue(forKey: .littleTip)
        check("two visible fingers alone cannot start a scroll",
              settle(GestureRecognizer(), with: openWithMissingTips) == .aim)
    }

    private static func testMissionControlSwipe() {
        let recognizer = GestureRecognizer()
        let pose = Fixture.fourFingers()
        _ = recognizer.processed(Fixture.palm())
        check("four fingers with the thumb folded need pose confirmation",
              recognizer.processed(pose) == nil && recognizer.isConfirmingMissionControl)
        check("four raised fingers with the thumb folded arm Mission Control",
              recognizer.processed(pose)?.gesture == .missionControl)
        check("opening the thumb returns to cursor movement",
              settle(recognizer, with: Fixture.palm()) == .aim)
        var otherHand = pose
        for (joint, point) in pose.points {
            otherHand.points[joint] = CGPoint(x: 0.98 - point.y * 0.8, y: 0.85 - point.x * 0.8)
        }
        check("the four-finger pose works after mirroring and turning the hand",
              settle(GestureRecognizer(), with: otherHand) == .missionControl)
        var thumbHidden = pose
        thumbHidden.points.removeValue(forKey: .thumbTip)
        check("a palm with no visible thumb cannot start a Mission Control swipe",
              settle(GestureRecognizer(), with: thumbHidden) == .aim)
        _ = settle(recognizer, with: pose)
        check("an established four-finger pose survives a brief hidden thumb",
              recognizer.processed(thumbHidden)?.gesture == .missionControl &&
              recognizer.processed(pose)?.gesture == .missionControl)
        var relaxed = pose
        if let bentJoint = relaxed.points[.littlePIP] {
            relaxed.points[.littleTip] = CGPoint(x: bentJoint.x + 0.05, y: bentJoint.y)
        }
        check("a slightly bent outer finger still allows a four-finger swipe",
              settle(GestureRecognizer(), with: relaxed) == .missionControl)

        var swipe = MissionControlSwipe()
        let center = CGPoint(x: 0.5, y: 0.5)
        check("entering the pose, moving sideways, or raising the hand keeps Mission Control closed",
              !swipe.update(center, at: 0, reach: 0.64) &&
              !swipe.update(CGPoint(x: 0.61, y: 0.51), at: 0.03, reach: 0.64) &&
              !swipe.update(CGPoint(x: 0.5, y: 0.43), at: 0.06, reach: 0.64))
        check("a deliberate downward swipe from the raised height requests one open",
              swipe.update(CGPoint(x: 0.51, y: 0.49), at: 0.09, reach: 0.64) &&
              !swipe.update(CGPoint(x: 0.51, y: 0.64), at: 0.12, reach: 0.64))
        check("a held pose does not reopen Mission Control after returning to center",
              !swipe.update(center, at: 0.15, reach: 0.64) &&
              !swipe.update(CGPoint(x: 0.51, y: 0.61), at: 0.45, reach: 0.64))
        swipe = MissionControlSwipe()
        _ = swipe.update(center, at: 1, reach: 0.64)
        check("regaining tracking after a gap starts a fresh swipe reference",
              !swipe.update(CGPoint(x: 0.5, y: 0.69), at: 1.44, reach: 0.64) &&
              swipe.update(CGPoint(x: 0.512, y: 0.75), at: 1.47, reach: 0.64))
    }

    private static func testCursorBadges() {
        check("steady aim draws the ring without a badge", PointerFeedback.steady.badge == nil)
        check("moving and pinching show Following and Click",
              PointerFeedback.moving.badge == "Following" && PointerFeedback.pinching.badge == "Click")
        check("drag and vertical scroll keep their labels",
              PointerFeedback.dragging.badge == "Drag" && PointerFeedback.scrolling.badge == "Scroll" &&
              PointerFeedback.scrollingUp.badge == "Scroll up" && PointerFeedback.scrollingDown.badge == "Scroll down")
        check("zoom feedback distinguishes preparing, moving, reacquiring, and release",
              PointerFeedback.confirmingZoom.badge == "Pinch both hands" &&
              PointerFeedback.zoom.badge == "Move hands to zoom" &&
              PointerFeedback.trackingZoom.badge == "Finding both hands" &&
              PointerFeedback.releasingZoom.badge == "Open both hands")
    }

    private static func testScrollMotion() {
        var scroll = ScrollMotion()
        let reference: CGFloat = 0.5
        let wobble: [CGFloat] = [0, 0.006, -0.008, 0.003, 0]
        let quiet = wobble.enumerated().map { index, offset in
            scroll.update(y: reference + offset, at: Double(index) / 30, reach: 0.5, speed: 1)
        }
        check("entering scroll and small hand wobbles produce no wheel events", quiet.allSatisfy { $0 == 0 })

        var total: Int32 = 0
        var last: Int32 = 0
        for frame in 5...600 {
            last = scroll.update(y: 0.57, at: Double(frame) / 30, reach: 0.5, speed: 1)
            total += last
        }
        check("holding an offset scrolls down for at least twenty seconds", total < -3000 && last < 0)
        check("bringing the hand back to its starting height stops immediately",
              scroll.update(y: reference, at: 601.0 / 30, reach: 0.5, speed: 1) == 0)
        check("lifting above the starting height scrolls up",
              scroll.update(y: 0.37, at: 602.0 / 30, reach: 0.5, speed: 1) > 0)
        scroll.pause()
        check("a dropped camera frame does not build up a burst of wheel events",
              scroll.update(y: 0.37, at: 21, reach: 0.5, speed: 1) == 0)
        scroll = ScrollMotion()
        check("a new peace sign starts at its current hand height",
              scroll.update(y: 0.38, at: 22, reach: 0.5, speed: 1) == 0)
    }

    // MARK: - Calibration & mapping

    private static func testCalibration() {
        let calibration = Calibration(minX: 0.2, maxX: 0.8, minY: 0.2, maxY: 0.8)
        let bottomRight = calibration.normalized(CGPoint(x: 0.2, y: 0.2))
        check("calibration maps its top-left corner to zero",
              near(bottomRight.x, 0) && near(bottomRight.y, 0))

        let center = calibration.normalized(CGPoint(x: 0.5, y: 0.5))
        check("calibration maps its center to 0.5",
              near(center.x, 0.5) && near(center.y, 0.5))

        let outside = calibration.normalized(CGPoint(x: -2, y: 4))
        check("calibration clamps points outside the box",
              outside.x == 0 && outside.y == 1)
        check("calibration box has sane extent",
              calibration.width > 0 && calibration.height > 0)
    }

    private static func testCalibrationPreview() {
        let view = CGRect(x: 0, y: 0, width: 448, height: 270)
        let video = CalibrationPreviewView.fittedRect(CGSize(width: 320, height: 240), in: view)
        check("a 4:3 preview leaves even side bars in a wider view",
              video == CGRect(x: 44, y: 0, width: 360, height: 270))

        let upperLeft = CGPoint(x: 0.2, y: 0.3)
        let reach = Calibration(minX: 0.2, maxX: 0.8, minY: 0.3, maxY: 0.7)
        let outline = CalibrationPreviewView.outline(reach, in: video)
        let palm = CalibrationPreviewView.position(of: upperLeft, in: video)
        check("palm markers and reach outlines use the same mirrored image coordinates",
              palm == outline.origin && palm == CGPoint(x: 116, y: 81))

        let wide = CalibrationPreviewView.fittedRect(CGSize(width: 320, height: 180), in: view)
        check("wide camera frames align with their top and bottom bars",
              near(wide.minX, 0, 0.001) && near(wide.minY, 9, 0.001)
              && near(wide.width, 448, 0.001) && near(wide.height, 252, 0.001))
    }

    private static func testMapping() {
        let mapper = PointerMapper(calibration: Calibration(minX: 0.2, maxX: 0.8, minY: 0.2, maxY: 0.8))
        let display = CGRect(x: 0, y: 0, width: 1000, height: 1000)

        let topLeft = mapper.map(CGPoint(x: 0.2, y: 0.2), onto: display, timestamp: 0, speed: 1.0)
        check("hand at the top-left of the box maps to the top-left of the screen",
              near(topLeft.x, 0) && near(topLeft.y, 0))

        // The pointer is smoothed, so give the filter time to settle instead of
        // demanding an instant jump.
        var time = 0.0
        var bottomRight = CGPoint.zero
        for _ in 0..<90 {
            time += 1.0 / 30.0
            bottomRight = mapper.map(CGPoint(x: 0.8, y: 0.8), onto: display, timestamp: time, speed: 1.0)
        }
        check("finger at the bottom-right of the box settles at the bottom-right of the screen",
              near(bottomRight.x, 1000, 2) && near(bottomRight.y, 1000, 2))

        let offsetMapper = PointerMapper(calibration: Calibration(minX: 0.2, maxX: 0.8, minY: 0.2, maxY: 0.8))
        var offset = CGPoint.zero
        var offsetTime = 0.0
        for _ in 0..<90 {
            offsetTime += 1.0 / 30.0
            offset = offsetMapper.map(CGPoint(x: 0.5, y: 0.5),
                                      onto: CGRect(x: 100, y: 50, width: 200, height: 100),
                                      timestamp: offsetTime, speed: 1.0)
        }
        check("mapping respects a non-origin display",
              near(offset.x, 200, 2) && near(offset.y, 100, 2))

        let reach = [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.8)]
        for speed in [Settings.cursorSpeedRange.lowerBound, Settings.cursorSpeedRange.upperBound] {
            let edges = reach.map { point in
                mapper.resetFilters()
                return mapper.map(point, onto: display, timestamp: 0, speed: speed)
            }
            check("cursor speed \(speed) still reaches all display edges",
                  distance(edges[0], .zero) < 0.01 &&
                  distance(edges[1], CGPoint(x: 1000, y: 1000)) < 0.01)
        }
        func mappedX(_ fraction: Double, speed: Double) -> CGFloat {
            mapper.resetFilters()
            let point = CGPoint(x: 0.2 + 0.6 * fraction, y: 0.5)
            return mapper.map(point, onto: display, timestamp: 0, speed: speed).x
        }
        let slowest = Settings.cursorSpeedRange.lowerBound
        let smallMove = mappedX(0.51, speed: slowest) - mappedX(0.50, speed: slowest)
        let edgeMove = mappedX(1.00, speed: slowest) - mappedX(0.99, speed: slowest)
        check("slow cursor tuning allows small center movements without a sharp acceleration at the edge",
              smallMove > 0 && smallMove < 3 && edgeMove < 20)
        check("previous high speeds are capped when read by Settings",
              Settings.clamp(2, to: Settings.cursorSpeedRange) == 0.90 &&
              Settings.clamp(1, to: PrecisionCursor.dragGainRange) == 0.45 &&
              Settings.clamp(2, to: Settings.scrollSpeedRange) == 0.65)
    }

    private static func testFilter() {
        let filter = OneEuroFilter(minCutoff: 1.0, beta: 0.0)
        var value = CGPoint.zero
        for index in 0..<30 {
            value = filter.filter(CGPoint(x: 1, y: 1), at: Double(index) / 30.0)
        }
        check("filter converges on a constant input", distance(value, CGPoint(x: 1, y: 1)) < 0.01)

        let step = OneEuroFilter(minCutoff: 3.0, beta: 0.0)
        _ = step.filter(.zero, at: 0)
        for index in 1..<20 {
            _ = step.filter(CGPoint(x: 1, y: 0), at: Double(index) / 60.0)
        }
        let settled = step.filter(CGPoint(x: 1, y: 0), at: 20.0 / 60.0)
        check("filter reaches a step target", near(settled.x, 1.0, 0.02))

        let adaptive = OneEuroFilter()
        _ = adaptive.filter(CGPoint(x: 0.25, y: 0.25), at: 0)
        let fastMove = adaptive.filter(CGPoint(x: 0.75, y: 0.45), at: 1.0 / 30.0)
        check("fast palm motion gets less smoothing than slow motion", fastMove.x > 0.46)
        check("uneven diagonal motion stays on the line to the target",
              near((fastMove.x - 0.25) * 0.4, fastMove.y - 0.25, 0.0001))
        let duplicate = adaptive.filter(.zero, at: 1.0 / 30.0)
        check("duplicate sample timestamps leave the filter unchanged", duplicate == fastMove)
        adaptive.reset()
        _ = adaptive.filter(CGPoint(x: 0.25, y: 0.25), at: 0)
        let jitter = adaptive.filter(CGPoint(x: 0.252, y: 0.25), at: 1.0 / 30.0)
        check("the cursor filter still dampens small movements", jitter.x < 0.251)
    }

    private static func testSmoothingControl() {
        let quick = PointerMapper(smoothing: 0)
        let steady = PointerMapper(smoothing: 1)
        let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let hand = CGPoint(x: 0.5, y: 0.56)
        let center = quick.map(hand, onto: display, timestamp: 0)
        _ = steady.map(hand, onto: display, timestamp: 0)

        var quickJitter = CGFloat.zero
        var steadyJitter = CGFloat.zero
        for frame in 1...30 {
            let sample = CGPoint(x: hand.x + (frame.isMultiple(of: 2) ? 0.004 : -0.004), y: hand.y)
            let time = Double(frame) / 30
            quickJitter += distance(center, quick.map(sample, onto: display, timestamp: time))
            steadyJitter += distance(center, steady.map(sample, onto: display, timestamp: time))
        }
        check("raising Smoothing reduces small camera jitters", steadyJitter < quickJitter * 0.25)
        check("the strongest smoothing still responds quickly to large movements",
              steady.map(CGPoint(x: 0.35, y: 0.56), onto: display, timestamp: 31.0 / 30).x < 440)
        check("previous smoothing endpoints migrate to the equivalent direction on the slider",
              PointerMapper.smoothing(fromLegacyCutoff: 0.4) == 1 &&
              PointerMapper.smoothing(fromLegacyCutoff: 6) == 0)
    }

    private static func testPrecisionCursor() {
        var cursor = PrecisionCursor()
        let first = cursor.update(raw: CGPoint(x: 500, y: 400), gain: 1)
        check("first palm position is taken verbatim", near(first.x, 500) && near(first.y, 400))

        let jitter = cursor.update(raw: CGPoint(x: 500.3, y: 400.2), gain: 1)
        check("resting jitter inside the deadband is ignored", jitter == first)

        let moved = cursor.update(raw: CGPoint(x: 560, y: 400), gain: 1)
        check("real palm movement is followed", near(moved.x, 560, 1))

        let display = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let grab = CGPoint(x: 520, y: 400)
        cursor.beginDrag(at: grab, hand: moved, within: display)
        check("starting a drag keeps the exact pressed location", cursor.update(raw: moved, gain: 0.4) == grab)
        let fine = cursor.update(raw: CGPoint(x: 570, y: 400), gain: 0.4)
        check("small hand movements get fine control near the grab",
              fine.x > grab.x && fine.x < grab.x + 6 && fine.y == grab.y)

        let minimumGain = PrecisionCursor.dragGainRange.lowerBound
        let minimumFine = cursor.update(raw: CGPoint(x: 570, y: 400), gain: minimumGain)
        check("the new minimum drag speed gives finer control near the grab",
              minimumFine.x > grab.x && minimumFine.x < fine.x)

        let across = cursor.update(raw: CGPoint(x: 900, y: 400), gain: minimumGain)
        check("long drags travel farther than one fifth of the display at minimum drag speed",
              across.x - grab.x > display.width * 0.35)
        let farCorner = CGPoint(x: 999, y: 999)
        check("a drag reaches both corners even at minimum drag speed",
              cursor.update(raw: farCorner, gain: minimumGain) == farCorner &&
              cursor.update(raw: .zero, gain: minimumGain) == .zero)

        cursor.resumeAiming(from: first, within: display)
        check("the first palm frame after a drop stays exactly at the drop position",
              cursor.update(raw: moved) == first && !cursor.needsHandReference)
        check("holding the hand still after a drop keeps the drop position", cursor.update(raw: moved) == first)
        let farther = CGPoint(x: 740, y: 400)
        check("palm movement restores absolute positioning after a drop", cursor.update(raw: farther) == farther)

        let drop = CGPoint(x: 300, y: 400)
        cursor.resumeAiming(from: drop, within: display)
        _ = cursor.update(raw: CGPoint(x: 994, y: 400))
        let left = cursor.update(raw: CGPoint(x: 988, y: 400))
        let right = cursor.update(raw: CGPoint(x: 999, y: 400))
        check("small hand motions at an edge after a drop stay small and keep their direction",
              abs(left.x - drop.x) < 10 && left.x < drop.x &&
              abs(right.x - drop.x) < 10 && right.x > drop.x)
        let leftEdge = cursor.update(raw: CGPoint(x: 0, y: 400))
        check("moving back across the display restores reach to both edges",
              leftEdge.x == 0 && cursor.update(raw: CGPoint(x: 999, y: 400)).x == 999)

        let cornerDrop = CGPoint(x: 900, y: 100)
        let handAtDrop = CGPoint(x: 300, y: 700)
        var recoveredEveryTime = true
        for _ in 0..<120 {
            cursor.resumeAiming(from: cornerDrop, within: display)
            _ = cursor.update(raw: handAtDrop)
            _ = cursor.update(raw: CGPoint(x: 800, y: 200))
            let atEdges = cursor.update(raw: CGPoint(x: 850, y: 150))
            let reversed = cursor.update(raw: CGPoint(x: 840, y: 160))
            let returned = cursor.update(raw: handAtDrop)
            recoveredEveryTime = recoveredEveryTime && atEdges == CGPoint(x: 999, y: 0)
                && reversed.x < atEdges.x && reversed.y > atEdges.y && returned == handAtDrop
        }
        check("repeated interactions leave both edges as soon as the hand reverses", recoveredEveryTime)

        cursor.resumeAiming(from: cornerDrop, within: display)
        _ = cursor.update(raw: handAtDrop)
        for _ in 0..<120 {
            _ = cursor.update(raw: CGPoint(x: 302, y: 698))
            _ = cursor.update(raw: CGPoint(x: 298, y: 702))
        }
        check("stationary hand jitter does not erode the recovery reference",
              cursor.update(raw: handAtDrop) == cornerDrop)

        let shortSweep = CGPoint(x: 560, y: 440)
        for _ in 0..<5 {
            _ = cursor.update(raw: shortSweep)
            _ = cursor.update(raw: handAtDrop)
        }
        check("repeated partial sweeps restore calibrated aiming after a large offset",
              cursor.update(raw: shortSweep) == shortSweep)
    }

    private static func testPointerMotion() {
        var motion = PointerMotion()
        motion.place(at: .zero)
        motion.aim(at: CGPoint(x: 60, y: 0), time: 1)
        motion.advance(to: 1 + 1.0 / 60)
        let first = motion.position?.x ?? -1
        check("the overlay moves between camera frames", first > 0 && first < 60)
        motion.advance(to: 1 + 2.0 / 60)
        let second = motion.position?.x ?? -1
        check("display updates approach the target without overshooting", second > first && second < 60)
        motion.freeze()
        motion.advance(to: 1.2)
        check("pinching can freeze the exact visible aim point", motion.position?.x == second)
    }

    private static func testPointerStillness() {
        var stillness = PointerStillness()
        let visible = CGPoint(x: 500, y: 400)
        for frame in 0..<10 {
            let jitter = CGFloat(frame % 2) * 3 - 1.5
            _ = stillness.update(CGPoint(x: 500 + jitter, y: 400), visible: visible, at: Double(frame) / 30)
        }
        check("small hand jitter settles into a steady pointer", stillness.isSteady)
        let outlier = CGPoint(x: 517, y: 400)
        check("one distant sample cannot move the steady pointer",
              stillness.update(outlier, visible: visible, at: 0.34) == visible)
        check("returning to the quiet area keeps the pointer locked",
              stillness.update(visible, visible: visible, at: 0.37) == visible && stillness.isSteady)
        _ = stillness.update(CGPoint(x: 513, y: 400), visible: visible, at: 0.40)
        let intended = CGPoint(x: 519, y: 401)
        check("deliberate movement unlocks the pointer",
              stillness.update(intended, visible: visible, at: 0.43) == intended && !stillness.isSteady)
        _ = stillness.update(visible, visible: visible, at: 0.7)
        _ = stillness.update(visible, visible: visible, at: 1)
        check("time without tracked samples does not count as stillness", !stillness.isSteady)

        stillness = PointerStillness()
        for (frame, jitter) in [-5.0, 3, -3, 17, 4, -4, 2, -2, 3, -3].enumerated() {
            _ = stillness.update(CGPoint(x: visible.x + jitter, y: visible.y),
                                 visible: visible, at: Double(frame) / 30)
        }
        check("a steady hold settles through uneven jitter and one outlier", stillness.isSteady)
        let smallMove = CGPoint(x: visible.x + 5.5, y: visible.y)
        let first = stillness.update(smallMove, visible: visible, at: 10.0 / 30)
        _ = stillness.update(smallMove, visible: visible, at: 11.0 / 30)
        let resumed = stillness.update(smallMove, visible: visible, at: 12.0 / 30)
        check("a sustained small adjustment can wake a steady pointer",
              first == visible && resumed == smallMove && !stillness.isSteady)
    }

    private static func testIndexAnchor() {
        var anchor = IndexAnchor()
        let palm = CGPoint(x: 0.5, y: 0.65)
        let tip = CGPoint(x: 0.48, y: 0.45)
        check("the measured fingertip is the index aiming point", anchor.measure(tip: tip, palm: palm, at: 0) == tip)
        let moved = CGPoint(x: 0.55, y: 0.63)
        let estimated = anchor.measure(tip: nil, palm: moved, at: 0.06)
        check("a brief hidden fingertip keeps its offset from the moving palm",
              estimated.map { near($0.x, 0.53, 0.0001) && near($0.y, 0.43, 0.0001) } == true)
        check("a prolonged occlusion stops using the estimated fingertip", anchor.measure(tip: nil, palm: moved, at: 0.2) == nil)
        let newTip = CGPoint(x: 0.56, y: 0.41)
        check("the visible fingertip takes over again", anchor.measure(tip: newTip, palm: moved, at: 0.23) == newTip)
        check("index and palm aiming start with different vertical framing",
              AimPoint.indexFinger.defaultCalibration.minY < AimPoint.palm.defaultCalibration.minY)
    }

    private static func testPoses() {
        let frame = Fixture.pointing()
        var anchor = PalmAnchor()
        let measurement = anchor.measure(frame)
        check("fixtures expose a usable frame", measurement != nil)
        check("palm center sits between the wrist and middle knuckle",
              measurement?.center == CGPoint(x: 0.5, y: 0.685))
        check("hand scale is positive", (measurement?.scale ?? 0) > 0)

        let palmFrame = Fixture.palm()
        let sample = GestureRecognizer().processed(palmFrame)
        check("gesture samples carry both the palm and the index fingertip for aiming",
              sample?.palmCenter == anchor.measure(palmFrame)?.center && sample?.indexTip == palmFrame.indexTip)
        var uncertainTip = palmFrame
        uncertainTip.indexTipConfidence = 0.29
        check("low-confidence fingertip observations are excluded from aiming",
              GestureRecognizer().processed(uncertainTip)?.indexTip == nil)
        check("curling fingers leaves the palm anchor unchanged", measurement?.center == sample?.palmCenter)

        var rotated = palmFrame
        for (joint, point) in palmFrame.points {
            rotated.points[joint] = CGPoint(x: 0.98 - point.y * 0.8, y: 0.18 + point.x * 0.8)
        }
        var referenceAnchor = PalmAnchor()
        if let reference = referenceAnchor.measure(rotated)?.center {
            rotated.points.removeValue(forKey: .middleMCP)
            if let estimated = anchor.measure(rotated)?.center {
                check("learned palm anchor follows rotation and scale during knuckle occlusion",
                      distance(estimated, reference) < 0.0001)
            } else {
                check("learned palm anchor survives missing middle knuckle", false)
            }
        } else {
            check("rotated hand is usable", false)
        }

        var tilted = palmFrame
        tilted.aspectRatio = 16.0 / 9.0
        for (joint, point) in palmFrame.points {
            tilted.points[joint] = CGPoint(x: 0.5 + (point.x - 0.5) * 0.4 + (0.6 - point.y) * 0.3,
                                           y: 0.6 + (point.y - 0.6) * 0.55)
        }
        tilted.points.removeValue(forKey: .middleMCP)
        tilted.points.removeValue(forKey: .indexTip)
        tilted.points.removeValue(forKey: .ringTip)
        tilted.points.removeValue(forKey: .littleTip)
        check("a foreshortened palm with missing fingertips still moves the pointer",
              settle(GestureRecognizer(), with: tilted) == .aim)
    }
}

// MARK: - Synthetic hands

enum Fixture {
    private typealias Joint = VNHumanHandPoseObservation.JointName

    private static func build(indexExt: Bool, middleExt: Bool, ringExt: Bool, littleExt: Bool,
                              thumbGap: CGFloat? = nil) -> HandFrame {
        var frame = HandFrame()
        let wrist = CGPoint(x: 0.5, y: 0.78)
        frame.points[.wrist] = wrist

        let bases: [(Joint, Joint, Joint, CGPoint, Bool)] = [
            (.indexTip, .indexPIP, .indexMCP, CGPoint(x: 0.47, y: 0.60), indexExt),
            (.middleTip, .middlePIP, .middleMCP, CGPoint(x: 0.50, y: 0.59), middleExt),
            (.ringTip, .ringPIP, .ringMCP, CGPoint(x: 0.53, y: 0.60), ringExt),
            (.littleTip, .littlePIP, .littleMCP, CGPoint(x: 0.56, y: 0.62), littleExt)
        ]

        for (tip, pip, mcp, base, extended) in bases {
            frame.points[mcp] = base
            if extended {
                frame.points[pip] = CGPoint(x: base.x - 0.005, y: base.y - 0.08)
                frame.points[tip] = CGPoint(x: base.x - 0.01, y: base.y - 0.16)
            } else {
                frame.points[pip] = CGPoint(x: base.x - 0.005, y: base.y - 0.06)
                frame.points[tip] = CGPoint(x: base.x, y: base.y)
            }
        }
        if let tip = frame.points[.indexTip], let pip = frame.points[.indexPIP] {
            frame.points[.indexDIP] = interpolate(pip, tip, 0.58)
        }

        // Thumb: extended forward, or tucked toward the index tip.
        // `thumbGap` is expressed in multiples of the hand size so the pinch
        // ratio is predictable in tests.
        let handScale = wrist.y - 0.59   // wrist to middle knuckle
        if let gap = thumbGap {
            let tip = frame.points[.indexTip] ?? CGPoint(x: 0.46, y: 0.44)
            let magnitude = gap * handScale
            frame.points[.indexDIP] = CGPoint(x: tip.x + 0.035, y: tip.y - 0.017)
            frame.points[.thumbIP] = CGPoint(x: tip.x - 0.057, y: tip.y + 0.083)
            frame.points[.thumbTip] = CGPoint(x: tip.x - magnitude * 0.6,
                                              y: tip.y + magnitude * 0.8)
        } else {
            frame.points[.thumbMP] = CGPoint(x: 0.44, y: 0.72)
            frame.points[.thumbIP] = CGPoint(x: 0.42, y: 0.65)
            frame.points[.thumbTip] = CGPoint(x: 0.39, y: 0.58)
        }

        return frame
    }

    static func pointing() -> HandFrame {
        build(indexExt: true, middleExt: false, ringExt: false, littleExt: false)
    }

    static func thumbAndIndexOut() -> HandFrame {
        var frame = pointing()
        frame.points[.thumbMP] = CGPoint(x: 0.444, y: 0.705)
        frame.points[.thumbIP] = CGPoint(x: 0.381, y: 0.676)
        frame.points[.thumbTip] = CGPoint(x: 0.316, y: 0.662)
        return frame
    }

    static func parallelTips() -> HandFrame {
        var frame = pointing()
        frame.points[.indexDIP] = CGPoint(x: 0.46, y: 0.48)
        frame.points[.thumbIP] = CGPoint(x: 0.435, y: 0.48)
        frame.points[.thumbTip] = CGPoint(x: 0.435, y: 0.44)
        return frame
    }

    static func pinch(gap: CGFloat = 0) -> HandFrame {
        build(indexExt: true, middleExt: false, ringExt: false, littleExt: false, thumbGap: gap)
    }

    /// Alias used by tests; gap 0 places the thumb tip on the index tip.
    static func pinching(gap: CGFloat = 0) -> HandFrame { pinch(gap: gap) }

    static func palm() -> HandFrame {
        build(indexExt: true, middleExt: true, ringExt: true, littleExt: true)
    }

    static func fourFingers() -> HandFrame {
        var frame = palm()
        frame.points[.thumbTip] = CGPoint(x: 0.51, y: 0.67)
        frame.points[.thumbIP] = CGPoint(x: 0.46, y: 0.70)
        return frame
    }

    static func twoFingers() -> HandFrame {
        build(indexExt: true, middleExt: true, ringExt: false, littleExt: false)
    }
}

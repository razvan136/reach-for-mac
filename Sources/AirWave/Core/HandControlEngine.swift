import AppKit
import Combine
import CoreImage
import CoreVideo
import os

struct CameraPreviewFrame {
    let image: CGImage
    let palm: CGPoint?
    let indexTip: CGPoint?
}

/// Runs Vision on the capture queue and applies the latest result on the main thread.
final class HandControlEngine: ObservableObject {
    static let shared = HandControlEngine()

    @Published private(set) var gesture: HandGesture = .none
    @Published private(set) var handVisible = false
    @Published private(set) var isDragging = false
    @Published private(set) var previewFrame: CameraPreviewFrame?
    @Published private(set) var isCalibrating = false
    @Published private(set) var calibrationProgress: Double = 0
    @Published private(set) var calibrationBox: Calibration?
    @Published private(set) var cameraGranted = false
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var cameraReady = false
    @Published private(set) var cameraError: String?
    @Published private(set) var availableCameras: [CameraChoice] = []
    @Published private(set) var notice: String?

    private struct CaptureState {
        var acceptsFrames = false
        var showsPreview = false
        var generation = 0
        var cameraRevision = 0
        var frames = HandFrameBatch()
        var preview: CameraPreviewFrame?
        var deliveryScheduled = false
        var previewInFlight = false
    }

    private let settings = Settings.shared
    private let camera = CameraSession()
    private let detector = HandPoseDetector()
    private var detectorGeneration: Int?
    private let captureState = OSAllocatedUnfairLock(initialState: CaptureState())
    private let previewQueue = DispatchQueue(label: "com.razgogo.airwave.preview", qos: .utility)
    private lazy var ciContext = CIContext()
    private var previewAnchor = PalmAnchor()
    private var previewAnchorGeneration: Int?
    private var lastPreviewAt: TimeInterval = 0
    private var wantsPreview = false
    private var captureExpected = false
    private var cameraID: String?
    private var cameraRevision = 0
    private var cameraWatchdog = CameraFrameWatchdog()
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private let recognizer = GestureRecognizer()
    private let mouse = SystemInput()
    private let mapper: PointerMapper
    private var indexAnchor = IndexAnchor()
    private var pinchAim = PinchAimLock()
    private var cursor = PrecisionCursor()
    private var motion = PointerMotion()
    private var stillness = PointerStillness()
    private lazy var overlay = PointerOverlay()
    private var displayLink: CADisplayLink?
    private var displayID: CGDirectDisplayID?
    private var pointerActive = false
    private var actionFeedback: (label: PointerFeedback, until: TimeInterval)?
    private var pinch = PinchInteraction()
    private var twoHandZoom = TwoHandZoom()
    private var zoomFeedback = PointerFeedback.zoom
    private var lastAim: PinchTracking.Aim?
    private var pinchTracking: PinchTracking?
    private var scrollMotion = ScrollMotion()
    private var missionControlSwipe = MissionControlSwipe()
    private let missionControl = MissionControl()
    private var continuity = TrackingContinuity()
    private let logger = Logger(subsystem: "com.razgogo.airwave", category: "Input")
    private var nextPermissionCheck: TimeInterval = 0
    private var display = CGDisplayBounds(CGMainDisplayID())
    private var screenFrame: CGRect?

    private var calibrationStart: TimeInterval = 0
    private let calibrationDuration: TimeInterval = 7

    private init() {
        mapper = PointerMapper(calibration: settings.calibration, smoothing: settings.smoothing)
        cameraID = settings.cameraID
        camera.onPixelBuffer = { [weak self] buffer, time, revision in
            self?.consume(buffer, capturedAt: time, cameraRevision: revision)
        }
        camera.onError = { [weak self] error, revision in
            guard let self, let error, self.captureExpected, revision == self.cameraRevision else { return }
            self.cameraReady = false
            self.cameraError = error.localizedDescription
            self.previewFrame = nil
            if self.isCalibrating { self.cancelCalibration() } else { self.resetInteraction() }
        }
        camera.onDevicesChanged = { [weak self] choices in
            guard let self, self.availableCameras != choices else { return }
            self.availableCameras = choices
        }
        camera.discoverDevices()

        settings.$calibration.dropFirst().sink { [weak self] calibration in
            guard let self else { return }
            self.mapper.calibration = calibration
            if self.isCalibrating { self.cancelCalibration() } else { self.resetInteraction() }
        }.store(in: &cancellables)
        settings.$cameraID.dropFirst().sink { [weak self] cameraID in
            guard let self, self.cameraID != cameraID else { return }
            self.cameraID = cameraID
            self.cameraRevision += 1
            self.previewFrame = nil
            self.notice = nil
            self.updateCapture(enabled: self.settings.enabled, restart: true)
        }.store(in: &cancellables)
        settings.$smoothing.dropFirst().sink { [weak self] value in
            self?.mapper.smoothing = value
            self?.stillness = PointerStillness()
        }.store(in: &cancellables)
        settings.$enabled.dropFirst().sink { [weak self] enabled in
            guard let self else { return }
            self.resetInteraction()
            self.updateCapture(enabled: enabled, invalidatePending: true)
        }.store(in: &cancellables)
        settings.$highResolutionTracking.sink { [weak self] high in
            self?.camera.setHighResolution(high)
        }.store(in: &cancellables)
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.02
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        refreshPermissions()
        updateCapture(enabled: settings.enabled)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        displayLink?.invalidate()
        displayLink = nil
        displayID = nil
        updateCapture(enabled: false)
        resetInteraction()
    }

    func refreshPermissions() {
        let granted = Permission.accessibility.isGranted
        if nextPermissionCheck == 0 || accessibilityGranted != granted {
            logger.notice("System input permission: \(granted, privacy: .public)")
        }
        if accessibilityGranted != granted {
            resetInteraction()
            accessibilityGranted = granted
        }
        let canUseCamera = Permission.camera.isGranted
        if cameraGranted != canUseCamera {
            cameraGranted = canUseCamera
            updateCapture(enabled: settings.enabled)
        }
        nextPermissionCheck = CACurrentMediaTime() + 0.5

        let currentID = CGMainDisplayID()
        let bounds = CGDisplayBounds(currentID)
        if display != bounds || (displayID != nil && displayID != currentID) {
            resetInteraction()
        }
        display = bounds
        let screen = NSScreen.screens.first
        screenFrame = screen?.frame
        if timer != nil, displayID != currentID || displayLink == nil && screen != nil {
            displayLink?.invalidate()
            displayID = currentID
            displayLink = screen?.displayLink(
                target: self, selector: #selector(refreshPointer(_:)))
            displayLink?.isPaused = true
            displayLink?.add(to: .main, forMode: .common)
        }
    }

    func retryCamera() {
        updateCapture(enabled: settings.enabled, restart: true)
    }

    func setPreviewVisible(_ visible: Bool) {
        wantsPreview = visible
        if !visible { previewFrame = nil }
        updateCapture(enabled: settings.enabled)
    }

    private func updateCapture(enabled: Bool, invalidatePending: Bool = false, restart: Bool = false) {
        let showPreview = timer != nil && cameraGranted && wantsPreview
        let acceptFrames = timer != nil && cameraGranted && (enabled || showPreview)
        let runningChanged = acceptFrames != captureExpected
        captureState.withLock { state in
            guard restart || invalidatePending || state.acceptsFrames != acceptFrames
                    || state.showsPreview != showPreview else { return }
            state.acceptsFrames = acceptFrames
            state.showsPreview = showPreview
            state.generation += 1
            state.cameraRevision = cameraRevision
            state.frames = HandFrameBatch()
            state.preview = nil
        }
        guard runningChanged || restart else { return }
        captureExpected = acceptFrames
        if cameraReady { cameraReady = false }
        if cameraError != nil { cameraError = nil }
        if acceptFrames {
            cameraWatchdog.start(at: CACurrentMediaTime())
        } else {
            cameraWatchdog.stop()
            previewFrame = nil
        }
        camera.setRunning(acceptFrames, restarting: restart, deviceID: cameraID, revision: cameraRevision)
    }

    // MARK: - Capture

    private func consume(_ buffer: CVPixelBuffer, capturedAt: TimeInterval, cameraRevision: Int) {
        let (acceptsFrames, showsPreview, generation) = captureState.withLock {
            ($0.acceptsFrames && $0.cameraRevision == cameraRevision, $0.showsPreview, $0.generation)
        }
        let time = CACurrentMediaTime()
        guard acceptsFrames, HandFrameBatch.isFresh(capturedAt, at: time) else { return }

        if detectorGeneration != generation {
            detector.resetTracking()
            detectorGeneration = generation
        }
        let hands = detector.detect(in: buffer)
        let result = HandFrameBatch.Frame(hand: hands.first, secondHand: hands.dropFirst().first, time: capturedAt)
        publish(generation: generation, frame: result)

        guard showsPreview, time - lastPreviewAt >= 1.0 / 15.0 else { return }
        let render = captureState.withLock { state in
            guard generation == state.generation, !state.previewInFlight else { return false }
            state.previewInFlight = true
            return true
        }
        guard render else { return }
        lastPreviewAt = time
        previewQueue.async { [weak self] in
            guard let self else { return }
            defer { self.captureState.withLock { $0.previewInFlight = false } }
            if self.previewAnchorGeneration != generation {
                self.previewAnchor.reset()
                self.previewAnchorGeneration = generation
            }
            if let image = self.makePreview(from: buffer) {
                let palm = result.hand.flatMap { self.previewAnchor.measure($0)?.center }
                if result.hand == nil { self.previewAnchor.reset() }
                self.publish(generation: generation,
                             preview: CameraPreviewFrame(image: image, palm: palm, indexTip: result.hand?.aimTip))
            }
        }
    }

    private func publish(generation: Int, frame: HandFrameBatch.Frame? = nil, preview: CameraPreviewFrame? = nil) {
        let schedule = captureState.withLock { state in
            guard generation == state.generation else { return false }
            if let frame { state.frames.append(frame) }
            if let preview { state.preview = preview }
            guard !state.deliveryScheduled else { return false }
            state.deliveryScheduled = true
            return true
        }
        if schedule { DispatchQueue.main.async { [weak self] in self?.deliverCapture() } }
    }

    private func deliverCapture() {
        let (frames, preview) = captureState.withLock { state in
            let pending = (state.frames.take(), state.preview)
            state.preview = nil
            state.deliveryScheduled = false
            return pending
        }
        let now = CACurrentMediaTime()
        let freshFrames = frames.filter { HandFrameBatch.isFresh($0.time, at: now) }
        if !freshFrames.isEmpty, captureExpected {
            cameraWatchdog.receivedFrame(at: now)
            if !cameraReady {
                cameraReady = true
                logger.notice("Camera is delivering video frames.")
            }
            if cameraError != nil { cameraError = nil }
        }
        for frame in freshFrames {
            process(frame)
        }
        if let preview { previewFrame = preview }
    }

    private func makePreview(from buffer: CVPixelBuffer) -> CGImage? {
        let source = CIImage(cvPixelBuffer: buffer)
        let width = 320.0
        let scale = width / source.extent.width
        let transform = CGAffineTransform(scaleX: -scale, y: scale)
            .concatenating(CGAffineTransform(translationX: width, y: 0))
        let image = source.transformed(by: transform)
        return ciContext.createCGImage(image, from: image.extent)
    }

    private func process(_ frame: HandFrameBatch.Frame) {
        expireTracking(at: frame.time)
        if settings.enabled, accessibilityGranted, !isCalibrating, !isDragging, handleZoom(frame) { return }
        guard let hand = frame.hand else {
            recognizer.missedFrame()
            pauseGestureTracking()
            return
        }
        continuity.sawHand(at: frame.time)
        guard let sample = recognizer.processed(hand, dragging: isDragging) else {
            if settings.enabled, accessibilityGranted, !isCalibrating, let candidate = recognizer.pendingPinch {
                _ = latchPinch(candidate, at: frame.time)
            }
            pauseGestureTracking()
            return
        }
        continuity.confirmed(at: frame.time)
        if !handVisible { handVisible = true }
        if gesture != sample.gesture { gesture = sample.gesture }

        if isCalibrating {
            if frame.time >= calibrationStart, sample.gesture == .aim || sample.gesture == .missionControl,
               let point = settings.aimPoint == .palm ? sample.palmCenter : sample.indexTip {
                includeInCalibration(point)
            }
            return
        }
        guard settings.enabled else { return }
        apply(sample, at: frame.time)
    }

    private func handleZoom(_ frame: HandFrameBatch.Frame) -> Bool {
        let update = twoHandZoom.update(frame.hand, frame.secondHand, at: frame.time)
        switch update {
        case .idle:
            return false
        case .released:
            if let position = motion.position { resumeAiming(at: position) }
            return false
        default:
            break
        }

        if gesture != .zoom {
            pinch.cancel()
            pinchTracking = nil
            lastAim = nil
            pinchAim = PinchAimLock()
            recognizer.reset(requiringPinchRelease: true)
            scrollMotion = ScrollMotion()
            missionControlSwipe = MissionControlSwipe()
            motion.freeze()
            actionFeedback = nil
            gesture = .zoom
        }
        if frame.hand != nil {
            continuity.confirmed(at: frame.time)
            if !handVisible { handVisible = true }
        }

        switch update {
        case .confirming:
            zoomFeedback = .confirmingZoom
        case .began(let midpoint):
            zoomFeedback = .zoom
            if placePointerIfNeeded(at: midpoint, time: frame.time), let position = motion.position {
                mouse.beginZoom(at: pointerLocation(position))
            }
        case .ready:
            zoomFeedback = .zoom
        case .changed(let amount):
            zoomFeedback = .zoom
            mouse.zoom(by: amount)
            flash(amount > 0 ? .zoomingIn : .zoomingOut, at: frame.time)
        case .paused:
            zoomFeedback = .trackingZoom
            actionFeedback = nil
        case .ended:
            mouse.endZoom()
            zoomFeedback = .releasingZoom
            actionFeedback = nil
        case .releasing:
            zoomFeedback = .releasingZoom
        case .idle, .released:
            break
        }
        renderPointer()
        return true
    }

    private func tick() {
        let now = CACurrentMediaTime()
        expireTracking(at: now)
        if now >= nextPermissionCheck { refreshPermissions() }
        switch cameraWatchdog.poll(at: now) {
        case .restart:
            if cameraReady { cameraReady = false }
            if isCalibrating {
                cancelCalibration()
                notice = "The camera paused during calibration. Try again when the preview returns."
            } else {
                resetInteraction()
            }
            captureState.withLock { state in
                state.generation += 1
                state.frames = HandFrameBatch()
                state.preview = nil
            }
            camera.setRunning(true, restarting: true, deviceID: cameraID, revision: cameraRevision)
        case .needsRetry:
            if cameraError == nil {
                cameraError = "The camera stopped sending frames. Use Retry Camera in the menu."
            }
        case nil:
            break
        }
        if let lastHandAt = continuity.lastConfirmed, now - lastHandAt > 0.14 {
            motion.freeze()
            displayLink?.isPaused = true
        }
        if let feedback = actionFeedback, now >= feedback.until { actionFeedback = nil }
        if pointerActive { renderPointer() }

        if isCalibrating {
            let progress = (now - calibrationStart) / calibrationDuration
            if progress >= 1 {
                finishCalibration()
            } else {
                calibrationProgress = progress
            }
        }
    }

    private func expireTracking(at time: TimeInterval) {
        if continuity.expired(at: time, dragging: isDragging) { resetInteraction() }
    }

    private func pauseGestureTracking() {
        pinch.pauseHold()
        scrollMotion.pause()
        if !pinch.isActive, !recognizer.isConfirmingPinch, pinchTracking?.contact != nil {
            pinchTracking = nil
            if let position = motion.position { resumeAiming(at: position) }
        }
        if isDragging || recognizer.isConfirmingPinch || recognizer.isConfirmingMissionControl {
            motion.freeze()
        }
    }

    // MARK: - Pointer actions

    private func apply(_ sample: GestureSample, at time: TimeInterval) {
        defer { renderPointer() }
        if sample.gesture != .aim { pinchAim = PinchAimLock() }
        if pinch.isActive, sample.gesture != .pinch {
            finishPinch(palm: sample.palmCenter, at: time)
            return
        }
        if sample.gesture != .aim && sample.gesture != .pinch {
            lastAim = nil
            pinchTracking = nil
        }

        if sample.gesture != .aim && !isDragging { stillness = PointerStillness() }

        if scrollMotion.isActive, sample.gesture != .scroll || !settings.scrollEnabled {
            scrollMotion = ScrollMotion()
            if let position = motion.position { resumeAiming(at: position) }
        }
        if missionControlSwipe.isActive, sample.gesture != .missionControl {
            missionControlSwipe = MissionControlSwipe()
            if let position = motion.position { resumeAiming(at: position) }
        }

        let aimsWithIndex = settings.aimPoint == .indexFinger
        if aimsWithIndex, sample.gesture == .aim, pinchAim.shouldHold(sample.pinchAimEvidence, at: time) {
            followPinchApproach(sample, at: time)
            return
        }
        let aim = sample.gesture == .pinch ? nil : (aimsWithIndex
            ? indexAnchor.measure(tip: sample.indexTip, palm: sample.palmCenter, at: time)
            : sample.palmCenter)
        switch sample.gesture {
        case .aim:
            guard let aim else { motion.freeze(); return }
            if pinchTracking != nil {
                pinchTracking = nil
                if let position = motion.position { resumeAiming(at: position) }
            }
            if cursor.needsHandReference {
                guard settings.aimPoint == .palm || sample.indexTip != nil else { return }
                mapper.resetFilters()
            }
            lastAim = PinchTracking.Aim(point: aim, palm: sample.palmCenter, time: time)
            let raw = mapped(aim, at: time)
            aimPointer(at: cursor.update(raw: raw), capturedAt: time)
        case .pinch:
            updatePinch(sample, at: time)
        case .scroll:
            motion.freeze()
            guard accessibilityGranted, settings.scrollEnabled else { return }
            guard placePointerIfNeeded(at: aim, time: time) else { return }
            if !scrollMotion.isActive { actionFeedback = nil }
            let pixels = scrollMotion.update(y: sample.palmCenter.y, at: time,
                                             reach: settings.calibration.height, speed: settings.scrollSpeed)
            if pixels != 0, let position = motion.position {
                mouse.scroll(pixels: pixels, at: pointerLocation(position))
                flash(pixels > 0 ? .scrollingUp : .scrollingDown, at: time)
            }
        case .missionControl:
            motion.freeze()
            guard accessibilityGranted, placePointerIfNeeded(at: aim, time: time) else { return }
            if !missionControlSwipe.isActive { actionFeedback = nil }
            if missionControlSwipe.update(sample.palmCenter, at: time, reach: settings.calibration.height) {
                missionControl.open()
            }
        case .none:
            motion.freeze()
        case .zoom:
            break
        }
    }

    private func preparePinch(_ sample: GestureSample, at time: TimeInterval) -> PinchTracking? {
        if let pinchTracking { return pinchTracking }
        let reference: PinchTracking.Aim
        if let lastAim, time - lastAim.time <= 0.18 {
            reference = lastAim
        } else {
            guard let aim = settings.aimPoint == .palm ? sample.palmCenter : sample.indexTip else { return nil }
            reference = PinchTracking.Aim(point: aim, palm: sample.palmCenter, time: time)
        }
        let hand = projected(reference.point)
        let approach = PinchTracking.Reference(pointer: motion.position ?? hand, hand: hand)
        let tracking = PinchTracking(aim: reference, approach: approach)
        pinchTracking = tracking
        return tracking
    }

    private func followPinchApproach(_ sample: GestureSample, at time: TimeInterval) {
        guard let tracking = preparePinch(sample, at: time), tracking.contact == nil else {
            motion.freeze()
            return
        }
        let hand = projected(tracking.aim(following: sample.palmCenter))
        let target = tracking.approach.position(following: hand)
        if target == motion.position {
            motion.freeze()
        } else {
            aimPointer(at: target, capturedAt: time)
        }
    }

    private func latchPinch(_ sample: GestureSample, at time: TimeInterval) -> PinchTracking? {
        guard var tracking = preparePinch(sample, at: time) else { return nil }
        if tracking.contact == nil {
            // Latch the point visible when touch is first observed. A second
            // contact frame is still required before any click or drag is eligible.
            let aim = tracking.aim(following: sample.palmCenter)
            let hand = projected(aim)
            let point = pointerLocation(motion.position ?? hand)
            tracking.contact = PinchTracking.Reference(pointer: point, hand: hand)
            pinchTracking = tracking
            mapper.resetFilters()
            _ = mapped(aim, at: time)
            motion.place(at: point)
            pointerActive = true
            actionFeedback = nil
        }
        return tracking
    }

    private func updatePinch(_ sample: GestureSample, at time: TimeInterval) {
        guard accessibilityGranted, let tracking = latchPinch(sample, at: time),
              let contact = tracking.contact else { motion.freeze(); return }
        let aim = tracking.aim(following: sample.palmCenter)
        let hand = mapped(aim, at: time)
        let update = pinch.update(at: time, firmlyClosed: sample.isFirmPinch,
                                  handPoint: isDragging ? nil : projected(aim))
        switch update {
        case .waiting:
            break
        case .beginDrag:
            cursor.beginDrag(at: contact.pointer, hand: contact.hand, within: display)
            mouse.beginDrag(at: contact.pointer)
            isDragging = true
            let target = bounded(cursor.update(raw: hand, gain: settings.pinchPrecision))
            let travel = distance(contact.pointer, target)
            // Send the first part immediately even when contact and opening
            // frames arrive in one batch. The display link eases the remainder.
            if travel > 0 {
                motion.place(at: interpolate(contact.pointer, target, min(1, 12 / travel)))
            }
            aimPointer(at: target, capturedAt: time)
        case .drag:
            aimPointer(at: cursor.update(raw: hand, gain: settings.pinchPrecision), capturedAt: time)
        }
    }

    private func finishPinch(palm: CGPoint, at time: TimeInterval) {
        motion.freeze()
        let tracking = pinchTracking
        pinchTracking = nil
        defer { if isDragging { isDragging = false } }

        switch pinch.release() {
        case .click:
            guard let tracking, let contact = tracking.contact else { return }
            mouse.click(at: contact.pointer)
            flash(.clicked, at: time)
            resumeAiming(at: contact.pointer)
            let hand = projected(tracking.aim(following: palm))
            let next = bounded(contact.continuation(afterClickAt: hand))
            if next != contact.pointer {
                cursor.resumeAiming(from: next, within: display)
                aimPointer(at: next, capturedAt: time)
            }
        case .endDrag:
            if let position = motion.position {
                let drop = pointerLocation(position)
                mouse.move(to: drop)
                mouse.endDrag()
                flash(.dropped, at: time)
                resumeAiming(at: drop)
            } else {
                mouse.endDrag()
            }
        case nil:
            break
        }
    }

    private func placePointerIfNeeded(at aim: CGPoint?, time: TimeInterval) -> Bool {
        if pointerActive { return true }
        guard let aim else { return false }
        motion.place(at: mapped(aim, at: time))
        pointerActive = true
        return true
    }

    private func resumeAiming(at position: CGPoint) {
        motion.place(at: position)
        cursor.resumeAiming(from: position, within: display)
        stillness = PointerStillness()
    }

    private func mapped(_ palm: CGPoint, at time: TimeInterval) -> CGPoint {
        bounded(mapper.map(palm, onto: display, timestamp: time, speed: settings.speed))
    }

    private func projected(_ point: CGPoint) -> CGPoint {
        bounded(mapper.project(point, onto: display, speed: settings.speed))
    }

    private func bounded(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, display.minX), display.maxX - 1),
                y: min(max(point.y, display.minY), display.maxY - 1))
    }

    private func pointerLocation(_ point: CGPoint) -> CGPoint {
        bounded(CGPoint(x: point.x.rounded(), y: point.y.rounded()))
    }

    private func aimPointer(at point: CGPoint, capturedAt time: TimeInterval) {
        let clamped = stillness.update(bounded(point), visible: motion.position, at: time)
        pointerActive = true
        if stillness.isSteady {
            motion.freeze()
            displayLink?.isPaused = true
            return
        }
        if let displayLink {
            motion.aim(at: clamped, time: CACurrentMediaTime())
            if motion.isMoving { displayLink.isPaused = false }
        } else {
            motion.place(at: clamped)
        }
    }

    @objc private func refreshPointer(_ link: CADisplayLink) {
        motion.advance(to: CACurrentMediaTime())
        renderPointer()
        if !motion.isMoving { link.isPaused = true }
    }

    private func flash(_ label: PointerFeedback, at time: TimeInterval) {
        actionFeedback = (label, time + 0.32)
    }

    private func renderPointer() {
        guard pointerActive, let position = motion.position else { return }
        let point = pointerLocation(position)
        if accessibilityGranted { mouse.move(to: point) }
        guard let screenFrame else { return }
        let feedback: PointerFeedback
        if !accessibilityGranted {
            feedback = .permission
        } else if let lastHandAt = continuity.lastConfirmed, CACurrentMediaTime() - lastHandAt > 0.14 {
            feedback = .tracking
        } else if let actionFeedback {
            feedback = actionFeedback.label
        } else if isDragging {
            feedback = .dragging
        } else {
            switch gesture {
            case .aim: feedback = stillness.isSteady ? .steady : .moving
            case .pinch: feedback = .pinching
            case .scroll: feedback = settings.scrollEnabled ? .scrolling : .idle
            case .missionControl: feedback = .missionControl
            case .zoom: feedback = zoomFeedback
            case .none: feedback = .idle
            }
        }
        overlay.show(at: point, in: display, screenFrame: screenFrame, feedback: feedback)
    }

    private func resetInteraction() {
        let interruptedPinch = pinch.isActive || pinchTracking?.contact != nil || twoHandZoom.isCaptured
        mouse.reset()
        pinch.cancel()
        lastAim = nil
        pinchTracking = nil
        twoHandZoom = TwoHandZoom()
        stillness = PointerStillness()
        indexAnchor = IndexAnchor()
        pinchAim = PinchAimLock()
        cursor = PrecisionCursor()
        motion = PointerMotion()
        displayLink?.isPaused = true
        if pointerActive { overlay.hide() }
        pointerActive = false
        actionFeedback = nil
        mapper.resetFilters()
        recognizer.reset(requiringPinchRelease: interruptedPinch)
        scrollMotion = ScrollMotion()
        missionControlSwipe = MissionControlSwipe()
        continuity = TrackingContinuity()
        if isDragging { isDragging = false }
        if gesture != .none { gesture = .none }
        if handVisible { handVisible = false }
    }

    // MARK: - Calibration

    func beginCalibration() {
        resetInteraction()
        calibrationBox = nil
        calibrationStart = CACurrentMediaTime()
        calibrationProgress = 0
        isCalibrating = true
        notice = nil
    }

    func cancelCalibration() {
        guard isCalibrating else { return }
        isCalibrating = false
        calibrationProgress = 0
        calibrationBox = nil
        resetInteraction()
    }

    private func includeInCalibration(_ palm: CGPoint) {
        var box = calibrationBox ?? Calibration(minX: palm.x, maxX: palm.x, minY: palm.y, maxY: palm.y)
        box.include(palm)
        if calibrationBox != box { calibrationBox = box }
    }

    private func finishCalibration() {
        let box = calibrationBox
        cancelCalibration()
        guard let box, box.maxX - box.minX > 0.05, box.maxY - box.minY > 0.05 else {
            notice = "Move your \(settings.aimPoint.title.lowercased()) farther in both directions."
            return
        }
        var padded = box
        let padX = box.width * 0.06
        let padY = box.height * 0.06
        padded.minX = min(max(0, box.minX - padX), 0.9)
        padded.maxX = min(max(padded.minX + 0.1, box.maxX + padX), 1)
        padded.minY = min(max(0, box.minY - padY), 0.9)
        padded.maxY = min(max(padded.minY + 0.1, box.maxY + padY), 1)
        settings.calibration = padded
        notice = "Reach calibrated."
    }
}

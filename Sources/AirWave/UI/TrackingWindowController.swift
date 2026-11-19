import AppKit
import Combine

/// Preview + calibration window. Pure AppKit so it builds with Command Line Tools.
final class TrackingWindowController: NSWindowController, NSWindowDelegate {
    private let engine = HandControlEngine.shared
    private let settings = Settings.shared
    private let onClose: () -> Void

    private let previewView = CalibrationPreviewView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let cameraButton = NSButton(title: "Allow Camera", target: nil, action: nil)
    private let accessButton = NSButton(title: "Allow Accessibility", target: nil, action: nil)
    private let controlsButton = NSButton(title: "Start Controls", target: nil, action: nil)
    private let reachLabel = NSTextField(labelWithString: "")
    private let noticeLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let calibrateButton = NSButton(title: "Calibrate reach (7s)", target: nil, action: nil)
    private let resetButton = NSButton(title: "Reset reach", target: nil, action: nil)
    private var cancellables = Set<AnyCancellable>()

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 515),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = "Reach Setup & Calibration"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
        buildContent()
        bind()
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    private func buildContent() {
        guard let window else { return }

        previewView.wantsLayer = true
        previewView.layer?.backgroundColor = NSColor.black.cgColor
        previewView.layer?.cornerRadius = 10
        previewView.layer?.masksToBounds = true
        previewView.setAccessibilityElement(true)
        previewView.setAccessibilityRole(.image)
        previewView.setAccessibilityLabel("Mirrored camera preview showing the control area and aiming point")
        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewView.heightAnchor.constraint(equalToConstant: 255).isActive = true

        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        reachLabel.font = .systemFont(ofSize: 11)
        reachLabel.textColor = .secondaryLabelColor
        noticeLabel.font = .systemFont(ofSize: 11)
        noticeLabel.textColor = .secondaryLabelColor
        noticeLabel.lineBreakMode = .byWordWrapping
        noticeLabel.maximumNumberOfLines = 3

        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.isHidden = true
        progress.controlSize = .small

        calibrateButton.target = self
        calibrateButton.action = #selector(startCalibration)
        calibrateButton.controlSize = .small
        resetButton.target = self
        resetButton.action = #selector(resetReach)
        resetButton.controlSize = .small

        let intro = NSTextField(wrappingLabelWithString:
            "Allow camera tracking and system input, then start controls. The live preview helps you calibrate your reach.")
        intro.font = .systemFont(ofSize: 12)
        intro.textColor = .secondaryLabelColor

        cameraButton.target = self
        cameraButton.action = #selector(allowCamera)
        accessButton.target = self
        accessButton.action = #selector(allowInput)
        controlsButton.target = self
        controlsButton.action = #selector(toggleControls)
        let setupRow = NSStackView(views: [cameraButton, accessButton, controlsButton])
        setupRow.spacing = 8

        let calRow = NSStackView(views: [calibrateButton, resetButton])
        calRow.orientation = .horizontal
        calRow.spacing = 8

        let stack = NSStackView(views: [intro, setupRow, previewView, statusLabel, progress, reachLabel,
                                        calRow, noticeLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16),
            previewView.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            intro.widthAnchor.constraint(equalTo: stack.widthAnchor),
            noticeLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        window.contentView = content

        updateNotice()
    }

    private func bind() {
        engine.$previewFrame
            .combineLatest(settings.$aimPoint)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] frame, aim in self?.previewView.show(frame, aimPoint: aim) }
            .store(in: &cancellables)

        let pose = engine.$gesture
            .combineLatest(engine.$handVisible, engine.$isDragging, engine.$isCalibrating)
        let cameraStatus = engine.$cameraGranted.combineLatest(engine.$cameraReady, engine.$cameraError)
        pose.combineLatest(cameraStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pose, camera in
                guard let self else { return }
                let (gesture, visible, dragging, calibrating) = pose
                let (allowed, ready, error) = camera
                if !allowed {
                    self.statusLabel.stringValue = "Allow Camera to start the preview"
                } else if error != nil {
                    self.statusLabel.stringValue = "Camera needs attention"
                } else if !ready {
                    self.statusLabel.stringValue = "Starting camera…"
                } else if calibrating {
                    self.statusLabel.stringValue = "Calibrating — trace the area you can comfortably reach"
                } else if dragging {
                    self.statusLabel.stringValue = "Dragging — release to drop"
                } else if visible {
                    self.statusLabel.stringValue = "\(gesture.label) — \(gesture.hint)"
                } else {
                    self.statusLabel.stringValue = "No hand detected"
                }
            }
            .store(in: &cancellables)

        engine.$isCalibrating
            .receive(on: DispatchQueue.main)
            .sink { [weak self] calibrating in
                guard let self else { return }
                self.progress.isHidden = !calibrating
                self.resetButton.isEnabled = !calibrating
                if calibrating { self.progress.doubleValue = 0 }
            }
            .store(in: &cancellables)

        engine.$cameraGranted
            .combineLatest(engine.$accessibilityGranted, settings.$enabled)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] camera, access, enabled in
                guard let self else { return }
                self.cameraButton.title = camera ? "Camera Allowed" : "Allow Camera"
                self.cameraButton.isEnabled = !camera
                self.accessButton.title = access ? "Accessibility Allowed" : "Allow Accessibility"
                self.accessButton.isEnabled = !access
                self.controlsButton.title = enabled ? "Pause Controls" : "Start Controls"
                self.controlsButton.isEnabled = enabled || (camera && access)
            }
            .store(in: &cancellables)

        engine.$cameraReady
            .combineLatest(engine.$isCalibrating)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ready, calibrating in self?.calibrateButton.isEnabled = ready && !calibrating }
            .store(in: &cancellables)

        engine.$calibrationProgress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.progress.doubleValue = value
            }
            .store(in: &cancellables)

        engine.$notice
            .combineLatest(engine.$cameraError)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notice, error in self?.noticeLabel.stringValue = error ?? notice ?? "" }
            .store(in: &cancellables)

        settings.$calibration
            .combineLatest(engine.$calibrationBox, engine.$isCalibrating, settings.$aimPoint)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] reach, draft, calibrating, aim in
                guard let self else { return }
                self.previewView.showReach(reach, draft: draft, isCalibrating: calibrating)
                self.reachLabel.stringValue = calibrating
                    ? "Move your \(aim.title.lowercased()) around your reach. Green shows the new area."
                    : "The outline shows your control area. The dot follows your \(aim.title.lowercased())."
            }
            .store(in: &cancellables)

    }

    private func updateNotice() {
        noticeLabel.stringValue = engine.cameraError ?? engine.notice ?? ""
    }

    @objc private func startCalibration() {
        guard engine.cameraReady else { return }
        engine.beginCalibration()
    }

    @objc private func allowCamera() { Permission.camera.request() }

    @objc private func allowInput() { Permission.accessibility.request() }

    @objc private func toggleControls() { settings.enabled.toggle() }

    @objc private func resetReach() {
        settings.calibration = settings.aimPoint.defaultCalibration
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        engine.setPreviewVisible(false)
        engine.cancelCalibration()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        engine.setPreviewVisible(true)
    }
}

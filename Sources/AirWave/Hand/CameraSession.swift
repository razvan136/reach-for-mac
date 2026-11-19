import AVFoundation
import CoreVideo
import QuartzCore

struct CameraChoice: Equatable {
    let id: String
    let name: String
}

/// Owns both capture configuration and frame delivery on a serial queue.
final class CameraSession: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum CameraError: LocalizedError {
        case noDevice
        case selectedDeviceUnavailable
        case notAuthorized
        case configurationFailed

        var errorDescription: String? {
            switch self {
            case .noDevice: return "No camera found."
            case .selectedDeviceUnavailable: return "Reconnect your selected camera or choose another in Settings."
            case .notAuthorized: return "Allow Reach in System Settings › Privacy & Security › Camera."
            case .configurationFailed: return "Couldn’t start the camera."
            }
        }
    }

    // Set before starting capture. Frames are delivered on the capture queue,
    // and permission or setup status is delivered on the main queue.
    var onPixelBuffer: ((CVPixelBuffer, TimeInterval, Int) -> Void)?
    var onError: ((Error?, Int) -> Void)?
    var onDevicesChanged: (([CameraChoice]) -> Void)?

    private let queue = DispatchQueue(label: "com.razgogo.airwave.camera", qos: .userInitiated)
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let discovery = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
        mediaType: .video, position: .unspecified)
    private var deviceObservation: NSKeyValueObservation?
    private var requestedDeviceID: String?
    private var revision = 0
    private var preset: AVCaptureSession.Preset = .hd1280x720
    private var configured = false
    private var wantsRunning = false
    private var observers: [NSObjectProtocol] = []
    private var nextRecovery: TimeInterval = 0
    private var attemptedRuntimeRecovery = false

    override init() {
        super.init()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) {
                [weak self] _ in self?.recoverAfterInterruption(restart: true)
            },
            center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) {
                [weak self] _ in self?.recoverAfterInterruption(restart: false)
            }
        ]
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func discoverDevices() {
        deviceObservation = discovery.observe(\.devices, options: [.initial, .new]) { [weak self] _, _ in
            self?.queue.async { [weak self] in self?.refreshDevices() }
        }
    }

    private func refreshDevices() {
        let devices = discovery.devices.filter(\.isConnected)
        let choices = devices.map { CameraChoice(id: $0.uniqueID, name: $0.localizedName) }
        DispatchQueue.main.async { [weak self] in self?.onDevicesChanged?(choices) }
        guard wantsRunning else { return }
        if let input = session.inputs.first as? AVCaptureDeviceInput, !input.device.isConnected {
            if session.isRunning { session.stopRunning() }
            removeConfiguration()
        }
        updateRunningState()
    }

    private func recoverAfterInterruption(restart: Bool) {
        queue.async { [weak self] in
            guard let self, self.wantsRunning else { return }
            if restart, self.attemptedRuntimeRecovery { return }
            let now = CACurrentMediaTime()
            guard now >= self.nextRecovery else { return }
            self.nextRecovery = now + 1
            if restart { self.attemptedRuntimeRecovery = true }
            if restart, self.session.isRunning { self.session.stopRunning() }
            self.updateRunningState()
        }
    }

    func setRunning(_ running: Bool, restarting: Bool = false, deviceID: String?, revision: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            self.wantsRunning = running
            let changeDevice = self.requestedDeviceID != deviceID
            if restarting || !running || changeDevice { self.attemptedRuntimeRecovery = false }
            if (restarting || changeDevice), self.session.isRunning { self.session.stopRunning() }
            if changeDevice {
                self.removeConfiguration()
                self.requestedDeviceID = deviceID
            }
            self.revision = revision
            self.updateRunningState()
        }
    }

    func setHighResolution(_ high: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            let preset: AVCaptureSession.Preset = high ? .hd1280x720 : .vga640x480
            guard self.preset != preset else { return }
            self.preset = preset
            guard self.configured else { return }
            self.session.beginConfiguration()
            self.applyRequestedPreset()
            self.setOutputFormat()
            self.session.commitConfiguration()
        }
    }

    private func updateRunningState() {
        guard wantsRunning else {
            if session.isRunning { session.stopRunning() }
            return
        }
        guard !session.isRunning else { return }

        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            report(CameraError.notAuthorized)
            return
        }
        do {
            if configured, let input = session.inputs.first as? AVCaptureDeviceInput, !input.device.isConnected {
                removeConfiguration()
            }
            if !configured { try configure() }
            session.startRunning()
            report(session.isRunning ? nil : CameraError.configurationFailed)
        } catch {
            report(error)
        }
    }

    private func configure() throws {
        let device: AVCaptureDevice
        if let requestedDeviceID {
            guard let selected = discovery.devices.first(where: { $0.uniqueID == requestedDeviceID && $0.isConnected })
            else { throw CameraError.selectedDeviceUnavailable }
            device = selected
        } else {
            guard let automatic = AVCaptureDevice.default(for: .video) ?? discovery.devices.first
            else { throw CameraError.noDevice }
            device = automatic
        }
        let input = try AVCaptureDeviceInput(device: device)

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(input) else { throw CameraError.configurationFailed }
        session.addInput(input)
        applyRequestedPreset()
        guard session.canAddOutput(output) else {
            session.removeInput(input)
            throw CameraError.configurationFailed
        }

        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
        setOutputFormat()
        configured = true
    }

    private func removeConfiguration() {
        guard configured else { return }
        session.beginConfiguration()
        session.removeOutput(output)
        for input in session.inputs { session.removeInput(input) }
        if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
        session.commitConfiguration()
        configured = false
    }

    private func applyRequestedPreset() {
        if session.canSetSessionPreset(preset) {
            session.sessionPreset = preset
        } else if preset == .vga640x480, session.canSetSessionPreset(.medium) {
            session.sessionPreset = .medium
        } else if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }
    }

    private func setOutputFormat() {
        let available = output.availableVideoPixelFormatTypes
        let preferred = [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                         kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                         kCVPixelFormatType_32BGRA]
        if let format = preferred.first(where: { available.contains($0) }) {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: format]
        } else {
            output.videoSettings = [:]
        }
    }

    private func report(_ error: Error?) {
        let revision = revision
        DispatchQueue.main.async { [weak self] in self?.onError?(error, revision) }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard connection === self.output.connection(with: .video),
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        attemptedRuntimeRecovery = false
        let receivedAt = CACurrentMediaTime()
        var capturedAt = receivedAt
        if let clock = session.synchronizationClock {
            let timestamp = CMSyncConvertTime(sampleBuffer.presentationTimeStamp, from: clock,
                                              to: CMClockGetHostTimeClock()).seconds
            if timestamp.isFinite, timestamp <= receivedAt + 0.01 {
                capturedAt = min(timestamp, receivedAt)
            }
        }
        onPixelBuffer?(buffer, capturedAt, revision)
    }
}

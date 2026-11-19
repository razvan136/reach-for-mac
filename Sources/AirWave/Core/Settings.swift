import Combine
import CoreGraphics
import Foundation

enum AimPoint: String, CaseIterable {
    case indexFinger, palm

    var title: String {
        switch self {
        case .indexFinger: return "Index finger"
        case .palm: return "Palm"
        }
    }

    var defaultCalibration: Calibration {
        switch self {
        case .indexFinger: return Calibration(minX: 0.16, maxX: 0.84, minY: 0.13, maxY: 0.70)
        case .palm: return .default
        }
    }
}

final class Settings: ObservableObject {
    static let shared = Settings()
    static let cursorSpeedRange = 0.20...0.90
    static let scrollSpeedRange = 0.05...0.65
    static let smoothingRange = 0.25...1.0

    private enum Key {
        static let enabled = "airwave.enabled"
        static let speed = "airwave.speed"
        static let smoothing = "airwave.smoothingStrength"
        static let legacyCutoff = "airwave.smoothing"
        static let aimPoint = "airwave.aimPoint"
        static let cameraID = "airwave.cameraID"
        static let scroll = "airwave.scrollEnabled"
        static let scrollSpeed = "airwave.scrollSpeed"
        static let pinchPrecision = "airwave.pinchPrecision"
        static let highResolution = "airwave.highResolution"
        static let hasShownSetup = "airwave.hasShownSetup"
    }

    private let defaults = UserDefaults.standard
    private var isLoading = false

    @Published var enabled: Bool { didSet { persist(enabled, Key.enabled) } }
    @Published var speed: Double { didSet { persist(speed, Key.speed) } }
    @Published var smoothing: Double { didSet { persist(smoothing, Key.smoothing) } }
    @Published var scrollEnabled: Bool { didSet { persist(scrollEnabled, Key.scroll) } }
    @Published var scrollSpeed: Double { didSet { persist(scrollSpeed, Key.scrollSpeed) } }
    /// Cursor sensitivity near the point where a drag starts.
    @Published var pinchPrecision: Double { didSet { persist(pinchPrecision, Key.pinchPrecision) } }
    @Published var highResolutionTracking: Bool { didSet { persist(highResolutionTracking, Key.highResolution) } }
    @Published var aimPoint: AimPoint {
        didSet {
            guard aimPoint != oldValue else { return }
            persist(aimPoint.rawValue, Key.aimPoint)
            calibration = Self.loadCalibration(defaults, aimPoint: aimPoint, cameraID: cameraID)
        }
    }
    @Published var cameraID: String? {
        didSet {
            guard cameraID != oldValue else { return }
            persist(cameraID, Key.cameraID)
            calibration = Self.loadCalibration(defaults, aimPoint: aimPoint, cameraID: cameraID)
        }
    }
    @Published var calibration: Calibration {
        didSet {
            guard !isLoading else { return }
            if let data = try? JSONEncoder().encode(calibration) {
                defaults.set(data, forKey: Self.calibrationKey(aimPoint: aimPoint, cameraID: cameraID))
            }
        }
    }

    private init() {
        isLoading = true
        enabled = defaults.object(forKey: Key.enabled) as? Bool ?? false
        speed = Self.clamp(defaults.object(forKey: Key.speed) as? Double ?? 0.55, to: Self.cursorSpeedRange)
        scrollSpeed = Self.clamp(defaults.object(forKey: Key.scrollSpeed) as? Double ?? 0.30,
                                 to: Self.scrollSpeedRange)
        let smoothingStrength: Double
        if let strength = defaults.object(forKey: Key.smoothing) as? Double {
            smoothingStrength = strength
        } else if let cutoff = defaults.object(forKey: Key.legacyCutoff) as? Double {
            smoothingStrength = PointerMapper.smoothing(fromLegacyCutoff: cutoff)
        } else {
            smoothingStrength = PointerMapper.defaultSmoothing
        }
        smoothing = Self.clamp(smoothingStrength, to: Self.smoothingRange)
        scrollEnabled = defaults.object(forKey: Key.scroll) as? Bool ?? true
        pinchPrecision = Self.clamp(defaults.object(forKey: Key.pinchPrecision) as? Double ?? 0.22,
                                     to: PrecisionCursor.dragGainRange)
        highResolutionTracking = defaults.object(forKey: Key.highResolution) as? Bool ?? true
        let point = defaults.string(forKey: Key.aimPoint).flatMap(AimPoint.init(rawValue:)) ?? .indexFinger
        let camera = defaults.string(forKey: Key.cameraID)
        aimPoint = point
        cameraID = camera
        calibration = Self.loadCalibration(defaults, aimPoint: point, cameraID: camera)
        isLoading = false
    }

    static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private static func calibrationKey(aimPoint: AimPoint, cameraID: String?) -> String {
        let key = aimPoint == .palm ? "airwave.palmCalibration" : "airwave.indexCalibration"
        guard let cameraID else { return key }
        return key + "." + cameraID
    }

    private static func loadCalibration(_ defaults: UserDefaults, aimPoint: AimPoint,
                                        cameraID: String?) -> Calibration {
        if let data = defaults.data(forKey: calibrationKey(aimPoint: aimPoint, cameraID: cameraID)),
           let saved = try? JSONDecoder().decode(Calibration.self, from: data) {
            return saved
        }
        return aimPoint.defaultCalibration
    }

    private func persist(_ value: Any?, _ key: String) {
        guard !isLoading else { return }
        defaults.set(value, forKey: key)
    }

    func takeFirstRunSetup() -> Bool {
        guard defaults.object(forKey: Key.enabled) == nil, !defaults.bool(forKey: Key.hasShownSetup) else {
            return false
        }
        defaults.set(true, forKey: Key.hasShownSetup)
        return true
    }
}

import AppKit
import ApplicationServices
import AVFoundation

enum Permission {
    case accessibility
    case camera

    private var settingsURL: URL? {
        let anchor: String
        switch self {
        case .accessibility: anchor = "Privacy_Accessibility"
        case .camera: anchor = "Privacy_Camera"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }

    var isGranted: Bool {
        switch self {
        case .accessibility: return CGPreflightPostEventAccess()
        case .camera: return AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        }
    }

    func request() {
        switch self {
        case .accessibility:
            _ = CGRequestPostEventAccess()
            if let url = settingsURL { NSWorkspace.shared.open(url) }
        case .camera:
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .notDetermined: AVCaptureDevice.requestAccess(for: .video) { _ in }
            case .denied, .restricted:
                if let url = settingsURL { NSWorkspace.shared.open(url) }
            default: break
            }
        }
    }
}

import AppKit
import ApplicationServices

/// The system launcher toggles Mission Control, so check visibility before opening it.
final class MissionControl {
    private let launcher = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
    private var openingUntil: TimeInterval = 0

    func open() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= openingUntil, AXIsProcessTrusted(), !Self.isVisible else { return }
        if NSWorkspace.shared.open(launcher) { openingUntil = now + 0.6 }
    }

    static var isVisible: Bool {
        for (bundle, marker) in [("com.apple.WindowManager", "mc.display"), ("com.apple.dock", "mc")] {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else {
                continue
            }
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.15)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(root, kAXChildrenAttribute as CFString, &value) == .success,
                  let children = value as? [AXUIElement] else { continue }
            for child in children {
                var identifier: CFTypeRef?
                if AXUIElementCopyAttributeValue(child, kAXIdentifierAttribute as CFString, &identifier) == .success,
                   identifier as? String == marker {
                    return true
                }
            }
        }
        return false
    }
}

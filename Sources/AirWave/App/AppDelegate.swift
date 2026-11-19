import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var trackingWindow: TrackingWindowController?
    private var preferencesWindow: PreferencesWindowController?
    private var cancellables = Set<AnyCancellable>()

    private let engine = HandControlEngine.shared
    private let settings = Settings.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        statusItem = item

        settings.$enabled
            .combineLatest(engine.$cameraError)
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled, cameraError in
                self?.updateStatusIcon(enabled: enabled, cameraError: cameraError)
            }
            .store(in: &cancellables)
        updateStatusIcon(enabled: settings.enabled, cameraError: nil)
        engine.start()

        if settings.takeFirstRunSetup() { openTracking() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        engine.refreshPermissions()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openTracking() }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()
    }

    private func updateStatusIcon(enabled: Bool, cameraError: String?) {
        guard let button = statusItem?.button else { return }
        let symbol = !enabled ? "pause.circle" : cameraError == nil ? "hand.raised" : "exclamationmark.triangle"
        let label = !enabled ? "Reach, controls paused" : cameraError == nil ? "Reach" : "Reach, camera unavailable"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.image?.isTemplate = true
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let heading = NSMenuItem(title: "Reach", action: nil, keyEquivalent: "")
        heading.attributedTitle = NSAttributedString(string: "Reach", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold)
        ])
        heading.isEnabled = false
        menu.addItem(heading)
        menu.addItem(legend(statusText()))
        menu.addItem(.separator())
        menu.addItem(action(settings.enabled ? "Pause Controls" : "Resume Controls",
                            #selector(toggleEnabled), symbol: settings.enabled ? "pause.fill" : "play.fill"))

        if engine.cameraError != nil {
            menu.addItem(action("Retry Camera", #selector(retryCamera), symbol: "arrow.clockwise"))
        }
        menu.addItem(action("Setup & Calibration…", #selector(openTracking), symbol: "camera"))
        menu.addItem(action("Settings…", #selector(openPreferences), symbol: "gearshape", key: ","))

        let guide = NSMenuItem(title: "Gesture Guide", action: nil, keyEquivalent: "")
        guide.isEnabled = true
        guide.image = NSImage(systemSymbolName: "hand.point.up.left", accessibilityDescription: nil)
        let gestures = NSMenu(title: "Gesture Guide")
        gestures.autoenablesItems = false
        gestures.addItem(legend("Open hand or point your index finger · Move"))
        gestures.addItem(legend("Quick pinch · Click"))
        gestures.addItem(legend("Firm pinch · Hold to drag, open to drop"))
        gestures.addItem(legend("Peace sign · Move up or down to scroll, return to the starting height to stop"))
        gestures.addItem(legend("Four fingers, thumb folded · Swipe sideways to open Mission Control"))
        guide.submenu = gestures
        menu.addItem(guide)

        menu.addItem(.separator())
        menu.addItem(action("About Reach", #selector(showAbout)))
        menu.addItem(action("Quit Reach", #selector(quit), key: "q"))
    }

    private func statusText() -> String {
        guard settings.enabled else { return "Controls paused" }
        if !engine.cameraGranted || !engine.accessibilityGranted { return "Setup needs permission" }
        if engine.cameraError != nil { return "Camera needs attention" }
        if !engine.cameraReady { return "Starting camera…" }
        if !engine.handVisible { return "Camera ready · Show your hand" }
        if engine.isDragging { return "Dragging · Open your fingers to drop" }
        return "\(engine.gesture.label) · \(engine.gesture.hint)"
    }

    private func action(_ title: String, _ selector: Selector, symbol: String? = nil, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        item.isEnabled = true
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    private func legend(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func toggleEnabled() {
        if !settings.enabled, !engine.cameraGranted || !engine.accessibilityGranted {
            openTracking()
        } else {
            settings.enabled.toggle()
        }
    }

    @objc private func retryCamera() {
        openTracking()
        engine.retryCamera()
    }

    @objc private func openTracking() {
        if trackingWindow == nil {
            trackingWindow = TrackingWindowController(onClose: { [weak self] in
                guard let self else { return }
                self.engine.setPreviewVisible(false)
                self.engine.cancelCalibration()
                self.trackingWindow = nil
            })
        }
        trackingWindow?.showWindow(nil)
        trackingWindow?.window?.makeKeyAndOrderFront(nil)
        engine.setPreviewVisible(true)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openPreferences() {
        if preferencesWindow == nil { preferencesWindow = PreferencesWindowController() }
        preferencesWindow?.showWindow(nil)
        preferencesWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showAbout() {
        let credits = NSAttributedString(string: "Hands-free pointer control. Camera frames stay on your Mac.")
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

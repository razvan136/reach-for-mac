import AppKit
import Combine

/// Native controls keep tuning available to the keyboard and VoiceOver.
final class PreferencesWindowController: NSWindowController {
    private let settings = Settings.shared
    private let cameraPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private var values: [NSSlider: NSTextField] = [:]
    private var cancellables = Set<AnyCancellable>()

    init() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 430, height: 330),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Reach Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent(in: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildContent(in window: NSWindow) {
        cameraPicker.target = self
        cameraPicker.action = #selector(cameraChanged(_:))
        let camera = pickerRow("Camera", picker: cameraPicker)
        let aimPicker = NSPopUpButton(frame: .zero, pullsDown: false)
        for aim in AimPoint.allCases {
            aimPicker.addItem(withTitle: aim.title)
            aimPicker.lastItem?.representedObject = aim.rawValue
        }
        aimPicker.selectItem(at: AimPoint.allCases.firstIndex(of: settings.aimPoint) ?? 0)
        aimPicker.target = self
        aimPicker.action = #selector(aimChanged(_:))
        let aim = pickerRow("Aim with", picker: aimPicker)

        let cursor = slider("Cursor speed", value: settings.speed, range: Settings.cursorSpeedRange,
                            action: #selector(speedChanged))
        let drag = slider("Fine drag speed", value: settings.pinchPrecision, range: PrecisionCursor.dragGainRange,
                          action: #selector(dragChanged), help: "Lower values slow small movements near the grab point.")
        let smoothing = slider("Smoothing", value: settings.smoothing, range: Settings.smoothingRange,
                               action: #selector(smoothingChanged), help: "Higher values steady small movements.")
        let scrollSpeed = slider("Scroll speed", value: settings.scrollSpeed, range: Settings.scrollSpeedRange,
                                 action: #selector(scrollSpeedChanged))
        let resolution = NSButton(checkboxWithTitle: "High-resolution camera tracking",
                                  target: self, action: #selector(resolutionChanged(_:)))
        resolution.state = settings.highResolutionTracking ? .on : .off
        let scroll = NSButton(checkboxWithTitle: "Scroll with the peace sign",
                              target: self, action: #selector(scrollChanged(_:)))
        scroll.state = settings.scrollEnabled ? .on : .off

        let rows = [camera, aim, cursor, smoothing, drag, scrollSpeed]
        let stack = NSStackView(views: rows + [resolution, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20)
        ] + rows.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) })
        window.contentView = content

        HandControlEngine.shared.$availableCameras.combineLatest(settings.$cameraID)
            .sink { [weak self] choices, selected in self?.showCameras(choices, selected: selected) }
            .store(in: &cancellables)
    }

    private func rowTitle(_ name: String) -> NSTextField {
        let title = NSTextField(labelWithString: name)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.widthAnchor.constraint(equalToConstant: 110).isActive = true
        return title
    }

    private func pickerRow(_ name: String, picker: NSPopUpButton) -> NSStackView {
        picker.setAccessibilityLabel(name)
        picker.cell?.lineBreakMode = .byTruncatingTail
        picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [rowTitle(name), picker])
        row.spacing = 10
        return row
    }

    private func showCameras(_ choices: [CameraChoice], selected: String?) {
        cameraPicker.removeAllItems()
        cameraPicker.addItem(withTitle: "Automatic")
        for choice in choices {
            var title = choice.name
            var number = 2
            while cameraPicker.item(withTitle: title) != nil {
                title = "\(choice.name) (\(number))"
                number += 1
            }
            cameraPicker.addItem(withTitle: title)
            cameraPicker.lastItem?.representedObject = choice.id
        }
        guard let selected else {
            cameraPicker.selectItem(at: 0)
            return
        }
        if let index = cameraPicker.itemArray.firstIndex(where: { $0.representedObject as? String == selected }) {
            cameraPicker.selectItem(at: index)
        } else {
            cameraPicker.addItem(withTitle: "Selected camera unavailable")
            cameraPicker.select(cameraPicker.lastItem)
        }
    }

    private func slider(_ name: String, value: Double, range: ClosedRange<Double>, action: Selector,
                        help: String? = nil) -> NSView {
        let slider = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound,
                              target: self, action: action)
        slider.setAccessibilityLabel(name)
        slider.setAccessibilityHelp(help)
        slider.toolTip = help
        slider.isContinuous = true
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let isSmoothing = action == #selector(smoothingChanged)
        let numeric = isSmoothing ? NSTextField(labelWithString: "") : NSTextField(string: "")
        if !isSmoothing {
            slider.altIncrementValue = 0.005
            numeric.target = self
            numeric.action = #selector(speedValueEntered(_:))
            numeric.cell?.sendsActionOnEndEditing = true
            numeric.setAccessibilityLabel("\(name) value")
            numeric.toolTip = "Enter an exact value"
        }
        numeric.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        numeric.alignment = .right
        numeric.widthAnchor.constraint(equalToConstant: 56).isActive = true
        values[slider] = numeric
        refreshValue(slider)
        let row = NSStackView(views: [rowTitle(name), slider, numeric])
        row.spacing = 10
        return row
    }

    private func refreshValue(_ sender: NSSlider) {
        let formatted = sender.action == #selector(smoothingChanged)
            ? sender.doubleValue.formatted(.percent.precision(.fractionLength(0)))
            : sender.doubleValue.formatted(.number.precision(.fractionLength(3)))
        values[sender]?.stringValue = formatted
    }

    @objc private func speedValueEntered(_ sender: NSTextField) {
        guard let slider = values.first(where: { $0.value === sender })?.key else { return }
        guard let value = try? Double(sender.stringValue, format: .number, lenient: false), value.isFinite else {
            refreshValue(slider)
            return
        }
        slider.doubleValue = Settings.clamp(value, to: slider.minValue...slider.maxValue)
        slider.sendAction(slider.action, to: slider.target)
    }

    @objc private func speedChanged(_ sender: NSSlider) {
        settings.speed = sender.doubleValue
        refreshValue(sender)
    }

    @objc private func dragChanged(_ sender: NSSlider) {
        settings.pinchPrecision = sender.doubleValue
        refreshValue(sender)
    }

    @objc private func smoothingChanged(_ sender: NSSlider) {
        settings.smoothing = sender.doubleValue
        refreshValue(sender)
    }

    @objc private func scrollSpeedChanged(_ sender: NSSlider) {
        settings.scrollSpeed = sender.doubleValue
        refreshValue(sender)
    }

    @objc private func aimChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let point = AimPoint(rawValue: raw) else { return }
        settings.aimPoint = point
    }

    @objc private func cameraChanged(_ sender: NSPopUpButton) {
        if sender.indexOfSelectedItem == 0 {
            settings.cameraID = nil
        } else if let id = sender.selectedItem?.representedObject as? String {
            settings.cameraID = id
        }
    }

    @objc private func resolutionChanged(_ sender: NSButton) { settings.highResolutionTracking = sender.state == .on }
    @objc private func scrollChanged(_ sender: NSButton) { settings.scrollEnabled = sender.state == .on }
}

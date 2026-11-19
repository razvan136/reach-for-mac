import AppKit

enum PointerFeedback: String {
    case moving = "Following"
    case steady = "Steady"
    case pinching = "Pinch"
    case clicked = "Click"
    case dragging = "Drag"
    case dropped = "Drop"
    case scrolling = "Scroll"
    case scrollingUp = "Scroll up"
    case scrollingDown = "Scroll down"
    case missionControl = "Mission Control"
    case confirmingZoom = "Pinch both hands"
    case zoom = "Move hands to zoom"
    case trackingZoom = "Finding both hands"
    case releasingZoom = "Open both hands"
    case zoomingIn = "Zoom in"
    case zoomingOut = "Zoom out"
    case idle = "Idle"
    case tracking = "Finding hand"
    case permission = "Allow Accessibility"

    var badge: String? {
        switch self {
        case .steady: return nil
        case .pinching: return "Click"
        default: return rawValue
        }
    }

    var color: NSColor {
        switch self {
        case .moving, .steady: return NSColor(srgbRed: 0.35, green: 0.85, blue: 1, alpha: 1)
        case .pinching, .permission: return .systemYellow
        case .clicked, .dropped: return .systemGreen
        case .dragging: return .systemOrange
        case .scrolling, .scrollingUp, .scrollingDown, .missionControl,
             .confirmingZoom, .zoom, .trackingZoom, .releasingZoom, .zoomingIn, .zoomingOut:
            return .systemPurple
        case .idle, .tracking: return .lightGray
        }
    }
}

/// Gesture feedback in a small window that passes input to the app beneath it.
final class PointerOverlay {
    private let panel: NSPanel
    private let view: PointerView
    private let footprint = CGSize(width: 178, height: 60)
    private static let ringInset: CGFloat = 15
    private static let ringRadius: CGFloat = 11
    // macOS positions the arrow at its tip, above and left of the visible body.
    private static let centerFromArrowTip = CGPoint(x: 5.5, y: -7.5)

    init() {
        let bounds = CGRect(origin: .zero, size: footprint)
        panel = NSPanel(contentRect: bounds, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        view = PointerView(frame: bounds)
        panel.contentView = view
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isExcludedFromWindowsMenu = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    func show(at point: CGPoint, in display: CGRect, screenFrame: CGRect, feedback: PointerFeedback) {
        let x = point.x - display.minX + screenFrame.minX + Self.centerFromArrowTip.x
        let y = screenFrame.maxY - (point.y - display.minY) + Self.centerFromArrowTip.y
        let left = x + footprint.width - Self.ringInset > screenFrame.maxX
        let localX = left ? footprint.width - Self.ringInset : Self.ringInset
        let origin = CGPoint(x: x - localX, y: y - footprint.height / 2)
        let labelCenter = min(max(y, screenFrame.minY + 12), screenFrame.maxY - 12)
        view.update(labelOnLeft: left, labelOffset: labelCenter - y, feedback: feedback)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        if panel.isVisible { panel.orderOut(nil) }
    }

    private final class PointerView: NSView {
        private var labelOnLeft = false
        private var labelOffset: CGFloat = 0
        private var feedback: PointerFeedback = .idle

        func update(labelOnLeft: Bool, labelOffset: CGFloat, feedback: PointerFeedback) {
            guard self.labelOnLeft != labelOnLeft || self.labelOffset != labelOffset ||
                    self.feedback != feedback else { return }
            self.labelOnLeft = labelOnLeft
            self.labelOffset = labelOffset
            self.feedback = feedback
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            let x = labelOnLeft ? bounds.maxX - ringInset : ringInset
            let radius = ringRadius
            let ring = NSBezierPath(ovalIn: CGRect(x: x - radius, y: bounds.midY - radius,
                                                   width: 2 * radius, height: 2 * radius))
            NSColor.black.withAlphaComponent(0.78).setStroke()
            ring.lineWidth = 3.6
            ring.stroke()
            feedback.color.setStroke()
            ring.lineWidth = 1.8
            ring.stroke()

            guard let badgeText = feedback.badge else { return }
            let label = NSAttributedString(string: badgeText, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.white
            ])
            let textSize = label.size()
            let width = ceil(textSize.width) + 16
            let badge = CGRect(x: labelOnLeft ? x - 17 - width : x + 17,
                               y: bounds.midY + labelOffset - 11, width: width, height: 22)
            NSColor(srgbRed: 0.07, green: 0.10, blue: 0.14, alpha: 0.94).setFill()
            let background = NSBezierPath(roundedRect: badge, xRadius: 9, yRadius: 9)
            background.fill()
            feedback.color.withAlphaComponent(0.55).setStroke()
            background.lineWidth = 1
            background.stroke()
            label.draw(at: CGPoint(x: badge.minX + 8, y: badge.midY - textSize.height / 2))
        }
    }
}

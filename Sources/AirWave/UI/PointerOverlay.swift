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
        case .scrolling, .scrollingUp, .scrollingDown, .missionControl: return .systemPurple
        case .idle, .tracking: return .lightGray
        }
    }
}

/// Gesture feedback in a small window that passes input to the app beneath it.
final class PointerOverlay {
    private let panel: NSPanel
    private let view: PointerView
    private let footprint = CGSize(width: 166, height: 30)

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
        let left = point.x > display.maxX - footprint.width + 15
        let x = point.x - display.minX + screenFrame.minX
        let y = screenFrame.maxY - (point.y - display.minY)
        let localX: CGFloat = left ? footprint.width - 15 : 15
        let origin = CGPoint(x: x - localX, y: y - 15)
        view.update(labelOnLeft: left, feedback: feedback)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        if panel.isVisible { panel.orderOut(nil) }
    }

    private final class PointerView: NSView {
        private var labelOnLeft = false
        private var feedback: PointerFeedback = .idle

        func update(labelOnLeft: Bool, feedback: PointerFeedback) {
            guard self.labelOnLeft != labelOnLeft || self.feedback != feedback else { return }
            self.labelOnLeft = labelOnLeft
            self.feedback = feedback
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            let x = labelOnLeft ? bounds.maxX - 15 : 15
            let ring = NSBezierPath(ovalIn: CGRect(x: x - 8, y: 7, width: 16, height: 16))
            NSColor.black.withAlphaComponent(0.85).setStroke()
            ring.lineWidth = 5
            ring.stroke()
            feedback.color.setStroke()
            ring.lineWidth = 2.5
            ring.stroke()

            guard let badgeText = feedback.badge else { return }
            let label = NSAttributedString(string: badgeText, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.white
            ])
            let textSize = label.size()
            let width = ceil(textSize.width) + 16
            let badge = CGRect(x: labelOnLeft ? x - 15 - width : x + 15,
                               y: 4, width: width, height: 22)
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

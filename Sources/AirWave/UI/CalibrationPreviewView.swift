import AppKit

/// A mirrored camera preview with reach and aiming coordinates drawn in the
/// fitted image, including when the window adds letterboxing.
final class CalibrationPreviewView: NSView {
    override var isFlipped: Bool { true }

    private var image: NSImage?
    private var aim: CGPoint?
    private var reach = Calibration.default
    private var draft: Calibration?
    private var isCalibrating = false

    func show(_ frame: CameraPreviewFrame?, aimPoint: AimPoint) {
        image = frame.map { NSImage(cgImage: $0.image, size: CGSize(width: $0.image.width, height: $0.image.height)) }
        aim = aimPoint == .palm ? frame?.palm : frame?.indexTip
        needsDisplay = true
    }

    func showReach(_ reach: Calibration, draft: Calibration?, isCalibrating: Bool) {
        self.reach = reach
        self.draft = draft
        self.isCalibrating = isCalibrating
        needsDisplay = true
    }

    override func draw(_ dirtyRect: CGRect) {
        NSColor.black.setFill()
        bounds.fill()
        guard let image else {
            let label = NSAttributedString(string: "Waiting for camera", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.8)
            ])
            let size = label.size()
            label.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
            return
        }

        let video = Self.fittedRect(image.size, in: bounds)
        image.draw(in: video, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let saved = Self.outline(reach, in: video)
        if isCalibrating {
            stroke(saved, color: .white.withAlphaComponent(0.85), dashed: true)
            if let draft { stroke(Self.outline(draft, in: video), color: .systemGreen) }
        } else {
            let mask = NSBezierPath(rect: video)
            mask.appendRect(saved)
            mask.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.36).setFill()
            mask.fill()
            stroke(saved, color: .systemCyan)
        }

        if let aim {
            let point = Self.position(of: aim, in: video)
            let dot = NSBezierPath(ovalIn: CGRect(x: point.x - 4.5, y: point.y - 4.5, width: 9, height: 9))
            NSColor.black.withAlphaComponent(0.85).setStroke()
            dot.lineWidth = 4
            dot.stroke()
            let color: NSColor = isCalibrating || saved.contains(point) ? .white : .systemOrange
            color.setFill()
            dot.fill()
        }
    }

    private func stroke(_ rect: CGRect, color: NSColor, dashed: Bool = false) {
        guard !rect.isEmpty else { return }
        let border = NSBezierPath(rect: rect)
        if dashed { border.setLineDash([5, 4], count: 2, phase: 0) }
        NSColor.black.withAlphaComponent(0.7).setStroke()
        border.lineWidth = 4
        border.stroke()
        color.setStroke()
        border.lineWidth = 2
        border.stroke()
    }

    static func fittedRect(_ size: CGSize, in bounds: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }

    static func position(of normalized: CGPoint, in video: CGRect) -> CGPoint {
        CGPoint(x: video.minX + normalized.x * video.width, y: video.minY + normalized.y * video.height)
    }

    static func outline(_ calibration: Calibration, in video: CGRect) -> CGRect {
        let corner = position(of: CGPoint(x: calibration.minX, y: calibration.minY), in: video)
        return CGRect(origin: corner, size: CGSize(width: (calibration.maxX - calibration.minX) * video.width,
                                                  height: (calibration.maxY - calibration.minY) * video.height))
    }
}

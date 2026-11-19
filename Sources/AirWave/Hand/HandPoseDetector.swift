import CoreGraphics
import CoreVideo
import Vision

/// Runs Vision hand-pose detection and returns a normalized `HandFrame`.
final class HandPoseDetector {
    private let request = VNDetectHumanHandPoseRequest()
    private var previousWrist: CGPoint?

    init() {
        request.maximumHandCount = 2
    }

    func resetTracking() {
        previousWrist = nil
    }

    func detect(in pixelBuffer: CVPixelBuffer) -> [HandFrame] {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        let aspect = CGFloat(CVPixelBufferGetWidth(pixelBuffer)) / CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        var hands = (request.results ?? []).compactMap { Self.frame(from: $0, aspectRatio: aspect) }
        if hands.count == 2, let previousWrist, let first = hands[0].wrist, let second = hands[1].wrist,
           distance(previousWrist, second) < distance(previousWrist, first) {
            hands.swapAt(0, 1)
        }
        previousWrist = hands.first?.wrist ?? previousWrist
        return hands
    }

    static func frame(from observation: VNHumanHandPoseObservation,
                      aspectRatio: CGFloat) -> HandFrame? {
        guard let recognized = try? observation.recognizedPoints(.all), !recognized.isEmpty else { return nil }

        var frame = HandFrame(aspectRatio: aspectRatio)
        frame.indexTipConfidence = recognized[.indexTip]?.confidence ?? 0
        frame.thumbIndexConfidence = min(recognized[.thumbTip]?.confidence ?? 0,
                                        frame.indexTipConfidence)
        frame.points.reserveCapacity(recognized.count)
        for (joint, point) in recognized where point.confidence > 0.25 {
            // Vision is bottom-left origin and unmirrored; flip both so the mapping
            // feels like a selfie preview.
            frame.points[joint] = CGPoint(x: 1 - point.location.x, y: 1 - point.location.y)
        }
        return frame.wrist == nil ? nil : frame
    }
}

import CoreGraphics
import CoreVideo
import Vision

/// Runs Vision hand-pose detection and returns a normalized `HandFrame`.
final class HandPoseDetector {
    private let request = VNDetectHumanHandPoseRequest()

    init() {
        request.maximumHandCount = 1
    }

    func detect(in pixelBuffer: CVPixelBuffer) -> HandFrame? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first else { return nil }
        let aspect = CGFloat(CVPixelBufferGetWidth(pixelBuffer)) / CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        return Self.frame(from: observation, aspectRatio: aspect)
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

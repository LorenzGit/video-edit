import Foundation
import CoreGraphics

struct ClipFraming: Codable, Equatable {
    var zoom: Double = 1
    var offsetX: Double = 0
    var offsetY: Double = 0
    var rotation: Double = 0

    var clamped: ClipFraming {
        ClipFraming(zoom: zoom.isFinite ? min(12, max(0.1, zoom)) : 1,
                    offsetX: offsetX.isFinite ? min(2, max(-2, offsetX)) : 0,
                    offsetY: offsetY.isFinite ? min(2, max(-2, offsetY)) : 0,
                    rotation: rotation.isFinite ? rotation.remainder(dividingBy: 360) : 0)
    }
}

/// Crop is measured in the original project canvas, independently of clip order.
struct VideoCrop: Codable, Equatable {
    var canvasWidth: Double
    var canvasHeight: Double
    var x: Double = 0
    var y: Double = 0
    var width: Double = 1
    var height: Double = 1

    var canvasSize: CGSize { CGSize(width: canvasWidth, height: canvasHeight) }
    var rect: CGRect { CGRect(x: x * canvasWidth, y: y * canvasHeight, width: width * canvasWidth, height: height * canvasHeight) }
    var outputSize: CGSize {
        CGSize(width: max(2, (Int(rect.width.rounded()) / 2) * 2),
               height: max(2, (Int(rect.height.rounded()) / 2) * 2))
    }
    var fullCanvas: VideoCrop { VideoCrop(canvasWidth: canvasWidth, canvasHeight: canvasHeight) }
    var clamped: VideoCrop {
        var copy = self
        copy.canvasWidth = canvasWidth.isFinite ? max(2, canvasWidth) : 2
        copy.canvasHeight = canvasHeight.isFinite ? max(2, canvasHeight) : 2
        copy.width = width.isFinite ? min(1, max(0.1, width)) : 1
        copy.height = height.isFinite ? min(1, max(0.1, height)) : 1
        copy.x = x.isFinite ? max(0, min(1 - copy.width, x)) : 0
        copy.y = y.isFinite ? max(0, min(1 - copy.height, y)) : 0
        return copy
    }
    func aspect(_ ratio: Double) -> VideoCrop {
        let normalizedRatio = ratio * canvasHeight / canvasWidth
        let w = min(1, normalizedRatio)
        let h = min(1, 1 / normalizedRatio)
        return VideoCrop(canvasWidth: canvasWidth, canvasHeight: canvasHeight,
                         x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h).clamped
    }
}

enum VideoGeometry {
    /// The same encoded-pixel matrix drives native preview and MP4 rendering.
    static func transform(encodedSize: CGSize, preferred: CGAffineTransform,
                          crop: VideoCrop, framing: ClipFraming, outputSize: CGSize) -> CGAffineTransform {
        let oriented = CGRect(origin: .zero, size: encodedSize).applying(preferred).standardized
        let base = crop.canvasSize
        let fit = min(base.width / max(1, oriented.width), base.height / max(1, oriented.height))
        let frame = framing.clamped
        return preferred
            .concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
            .concatenating(CGAffineTransform(scaleX: fit, y: fit))
            .concatenating(CGAffineTransform(translationX: (base.width - oriented.width * fit) / 2,
                                            y: (base.height - oriented.height * fit) / 2))
            .concatenating(CGAffineTransform(translationX: -base.width / 2, y: -base.height / 2))
            .concatenating(CGAffineTransform(scaleX: frame.zoom, y: frame.zoom))
            .concatenating(CGAffineTransform(rotationAngle: frame.rotation * .pi / 180))
            .concatenating(CGAffineTransform(translationX: base.width * (0.5 + frame.offsetX),
                                            y: base.height * (0.5 + frame.offsetY)))
            .concatenating(CGAffineTransform(translationX: -crop.rect.minX, y: -crop.rect.minY))
            .concatenating(CGAffineTransform(scaleX: outputSize.width / max(1, crop.rect.width),
                                            y: outputSize.height / max(1, crop.rect.height)))
    }
}

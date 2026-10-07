import CoreImage
import CoreImage.CIFilterBuiltins
import SnazzyCore

/// What goes into one composited frame.
public struct CompositeSpec: Equatable, Sendable {
    public var canvas: CGSize
    public var layout: InsetLayout
    public var profile: DeviceProfile
    public var borderColor: CIColor
    public var background: CIColor

    public init(canvas: CGSize = CGSize(width: 1920, height: 1080), layout: InsetLayout, profile: DeviceProfile,
                borderColor: CIColor = CIColor(red: 0.13, green: 0.13, blue: 0.13), background: CIColor = .black) {
        self.canvas = canvas
        self.layout = layout
        self.profile = profile
        self.borderColor = borderColor
        self.background = background
    }
}

/// Builds the recorded picture: screen scaled to fit the canvas, camera inset
/// (rotated, cropped, rounded, bordered) in its corner. Used by the live
/// composite preview and the recorder, so the preview is what gets recorded.
public enum Compositor {
    public static func compose(screen: CIImage?, camera: CIImage?, spec: CompositeSpec) -> CIImage {
        let canvasRect = CGRect(origin: .zero, size: spec.canvas)
        var output = CIImage(color: spec.background).cropped(to: canvasRect)

        if let screen {
            output = fit(screen, in: canvasRect).composited(over: output)
        }
        if let camera {
            output = inset(camera, spec: spec).composited(over: output)
        }
        return output.cropped(to: canvasRect)
    }

    /// Scales an image to fit a rect (letterboxed), centred.
    static func fit(_ image: CIImage, in rect: CGRect) -> CIImage {
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return image }
        let s = min(rect.width / e.width, rect.height / e.height)
        let w = e.width * s, h = e.height * s
        return image
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: s, y: s))
            .transformed(by: CGAffineTransform(translationX: rect.minX + (rect.width - w) / 2, y: rect.minY + (rect.height - h) / 2))
    }

    /// The inset (with border and rounded corners) placed on the canvas.
    static func inset(_ camera: CIImage, spec: CompositeSpec) -> CIImage {
        let content = FrameTransform.apply(camera, profile: spec.profile)
        let size = content.extent.size
        guard size.width > 0, size.height > 0 else { return CIImage.empty() }
        let frameTL = InsetGeometry.insetFrame(canvas: spec.canvas, contentAspect: size.width / size.height, layout: spec.layout)
        // Core Image is y-up.
        let frame = CGRect(x: frameTL.minX, y: spec.canvas.height - frameTL.maxY, width: frameTL.width, height: frameTL.height)
        let scaled = content
            .transformed(by: CGAffineTransform(scaleX: frame.width / size.width, y: frame.height / size.height))
            .transformed(by: CGAffineTransform(translationX: frame.minX, y: frame.minY))

        let radius = frame.height * spec.layout.normalized.cornerRadius
        let mask = roundedRect(frame, radius: radius, color: .white)
        let clipped = scaled.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: mask,
        ])
        let border = spec.layout.normalized.borderWidth * spec.canvas.height / 1080
        guard border > 0 else { return clipped }
        let outer = frame.insetBy(dx: -border, dy: -border)
        return clipped.composited(over: roundedRect(outer, radius: radius + border, color: spec.borderColor))
    }

    static func roundedRect(_ rect: CGRect, radius: CGFloat, color: CIColor) -> CIImage {
        let f = CIFilter.roundedRectangleGenerator()
        f.extent = rect
        f.radius = Float(max(0, min(radius, min(rect.width, rect.height) / 2)))
        f.color = color
        return f.outputImage?.cropped(to: rect) ?? CIImage.empty()
    }
}

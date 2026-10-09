import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMedia
import SnazzyCore

/// What goes into one composited frame.
public struct CompositeSpec: Equatable, Sendable {
    public var canvas: CGSize
    public var layout: InsetLayout
    public var profile: DeviceProfile
    public var borderColor: CIColor
    public var background: CIColor
    /// Part of the screen to show (top-left normalised 0…1); nil = whole screen.
    public var screenZoom: CGRect?
    public var arrangement: Arrangement = .inset
    /// The inset's size right now, when it differs from `layout.size` (title slides).
    public var insetSize: Double?
    /// The title-slide setting the recording was made with (kept in its timeline).
    public var titleSlideInsetSize: Double?

    /// How the screen and the camera share the picture.
    public enum Arrangement: Equatable, Sendable {
        /// The screen fills the picture; the camera is an inset in a corner.
        case inset
        /// For vertical video: the screen across the top, the camera filling the rest below.
        case stacked
    }

    public init(canvas: CGSize = CGSize(width: 1920, height: 1080), layout: InsetLayout, profile: DeviceProfile,
                borderColor: CIColor = CIColor(red: 0.13, green: 0.13, blue: 0.13), background: CIColor = .black) {
        self.canvas = canvas
        self.layout = layout
        self.profile = profile
        self.borderColor = borderColor
        self.background = background
    }
}

public extension CompositeSpec {
    /// Lip sync: the time to stamp a composited frame made at `time`. A camera picture
    /// that runs `profile.videoDelayMs` behind the sound is stamped that much earlier
    /// (later when negative). Without a camera there's nothing to line up.
    func syncedVideoTime(_ time: CMTime, hasCamera: Bool) -> CMTime {
        guard hasCamera, profile.videoDelayMs != 0 else { return time }
        return time - CMTime(seconds: profile.videoDelayMs / 1000, preferredTimescale: 1_000_000)
    }
}

/// Builds the recorded picture: screen scaled to fit the canvas, camera inset
/// (rotated, cropped, rounded, bordered) in its corner. Used by the live
/// composite preview and the recorder, so the preview is what gets recorded.
public enum Compositor {
    public static func compose(screen: CIImage?, camera: CIImage?, spec: CompositeSpec) -> CIImage {
        if spec.arrangement == .stacked { return stacked(screen: screen, camera: camera, spec: spec) }
        let canvasRect = CGRect(origin: .zero, size: spec.canvas)
        var output = CIImage(color: spec.background).cropped(to: canvasRect)

        if let screen {
            output = fit(zoomed(screen, spec.screenZoom), in: canvasRect).composited(over: output)
        }
        if let camera {
            output = inset(camera, spec: spec).composited(over: output)
        }
        return output.cropped(to: canvasRect)
    }

    /// Vertical video: the screen across the top at full width (at most 60% of the
    /// height), the camera (cropped, rotated) filling what's left below. Either one
    /// alone fills the picture.
    static func stacked(screen: CIImage?, camera: CIImage?, spec: CompositeSpec) -> CIImage {
        let canvasRect = CGRect(origin: .zero, size: spec.canvas)
        var output = CIImage(color: spec.background).cropped(to: canvasRect)
        let person = camera.map { FrameTransform.apply($0, profile: spec.profile) }.flatMap { $0.extent.isEmpty ? nil : $0 }
        guard let screen = screen.map({ zoomed($0, spec.screenZoom) }), !screen.extent.isEmpty else {
            if let person { output = BackgroundRenderer.aspectFill(person, into: canvasRect).composited(over: output) }
            return output
        }
        guard let person else { return fit(screen, in: canvasRect).composited(over: output).cropped(to: canvasRect) }
        let height = min(canvasRect.width * screen.extent.height / screen.extent.width, canvasRect.height * 0.6)
        // Core Image is y-up: the top of the picture is at maxY.
        let top = CGRect(x: 0, y: canvasRect.height - height, width: canvasRect.width, height: height)
        let below = CGRect(x: 0, y: 0, width: canvasRect.width, height: canvasRect.height - height)
        output = fit(screen, in: top).composited(over: output)
        output = BackgroundRenderer.aspectFill(person, into: below).composited(over: output)
        return output.cropped(to: canvasRect)
    }

    /// The zoomed part of the screen (Core Image is y-up).
    static func zoomed(_ screen: CIImage, _ zoom: CGRect?) -> CIImage {
        guard let z = zoom, z.width > 0.01, z.height > 0.01, z != CGRect(x: 0, y: 0, width: 1, height: 1) else { return screen }
        let e = screen.extent
        let rect = CGRect(x: e.minX + z.minX * e.width, y: e.minY + (1 - z.maxY) * e.height, width: z.width * e.width, height: z.height * e.height)
        return screen.cropped(to: rect)
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
        var layout = spec.layout
        if let s = spec.insetSize { layout.size = s }
        let frameTL = InsetGeometry.insetFrame(canvas: spec.canvas, contentAspect: size.width / size.height, layout: layout)
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

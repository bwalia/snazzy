import CoreImage
import SnazzyCore

/// Turns a raw device frame into the inset picture: rotate, then crop.
/// Shared by previews and (from phase 4) the compositor, so the preview shows
/// exactly what is recorded.
public enum FrameTransform {
    /// Rotates counter-clockwise by the profile's rotation and moves the result
    /// back to the origin.
    public static func rotated(_ image: CIImage, _ rotation: InsetRotation) -> CIImage {
        guard rotation != .none else { return image.translatedToOrigin() }
        let radians = rotation.degrees * .pi / 180
        return image.transformed(by: CGAffineTransform(rotationAngle: radians)).translatedToOrigin()
    }

    /// The inset content, with its extent at the origin.
    public static func apply(_ image: CIImage, profile: DeviceProfile) -> CIImage {
        let upright = rotated(image, profile.rotation)
        let size = upright.extent.size
        let crop = InsetGeometry.cropRect(upright: size, crop: profile.crop)
        // Core Image is y-up; the crop rect is top-left based.
        let ciRect = CGRect(x: crop.minX, y: size.height - crop.maxY, width: crop.width, height: crop.height)
        return upright.cropped(to: ciRect).translatedToOrigin()
    }
}

extension CIImage {
    func translatedToOrigin() -> CIImage {
        let e = extent
        guard e.origin != .zero, e.origin.x.isFinite, e.origin.y.isFinite else { return self }
        return transformed(by: CGAffineTransform(translationX: -e.origin.x, y: -e.origin.y))
    }
}

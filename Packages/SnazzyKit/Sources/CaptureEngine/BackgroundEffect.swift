@preconcurrency import AVFoundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import SnazzyCore
@preconcurrency import Vision

/// Replaces or blurs what's behind the person in a camera feed.
///
/// Person segmentation (Vision) runs on its own queue as frames arrive, at most
/// one at a time (frames are skipped while busy), so it never holds up capture.
/// `apply(_:)` combines the latest mask with the background; previews, the
/// composite and the recorder all use it, so they match. Raw camera tracks stay
/// untouched.
public final class BackgroundEffect: @unchecked Sendable {
    public enum Quality: String, CaseIterable, Sendable {
        case fast, balanced

        var vision: VNGeneratePersonSegmentationRequest.QualityLevel {
            self == .fast ? .fast : .balanced
        }
    }

    private let lock = NSLock()
    private var background: CameraBackground = .none
    private var backgroundImage: CIImage?
    private var mask: CIImage?
    private var maskTime = CMTime.invalid
    private var busy = false
    private var quality: Quality = .balanced
    private var lastRun = Date.distantPast
    private let sequence = VNSequenceRequestHandler()
    private let queue = DispatchQueue(label: "com.snazzy.pro.segmentation", qos: .userInitiated)

    /// Segmentation stays at or below this rate even for 60 fps cameras.
    public static let maxRate: Double = 30

    public init() {}

    /// Sets the background. `image` is the decoded picture for `.image` and
    /// `.builtIn` backgrounds (nil for none, blur and colour).
    public func configure(_ background: CameraBackground, image: CIImage?, quality: Quality = .balanced) {
        lock.withLock {
            if !background.isActive { mask = nil }
            self.background = background
            self.backgroundImage = image
            self.quality = quality
        }
    }

    public var isActive: Bool { lock.withLock { background.isActive } }

    /// Feed every camera frame here (from the camera queue).
    public func process(_ sampleBuffer: CMSampleBuffer) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let (active, q): (Bool, Quality) = lock.withLock {
            guard background.isActive, !busy, Date().timeIntervalSince(lastRun) >= 1 / Self.maxRate else { return (false, quality) }
            busy = true
            lastRun = Date()
            return (true, quality)
        }
        guard active else { return }
        let box = PixelBox(pixels)
        queue.async { [weak self] in self?.segment(box.buffer, time: time, quality: q) }
    }

    private func segment(_ pixels: CVPixelBuffer, time: CMTime, quality: Quality) {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = quality.vision
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        var newMask: CIImage?
        do {
            try sequence.perform([request], on: pixels)
            if let result = request.results?.first {
                let m = CIImage(cvPixelBuffer: result.pixelBuffer)
                let sx = CGFloat(CVPixelBufferGetWidth(pixels)) / m.extent.width
                let sy = CGFloat(CVPixelBufferGetHeight(pixels)) / m.extent.height
                newMask = m.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            }
        } catch {
            Log.capture.error("Segmentation failed: \(error.localizedDescription, privacy: .public)")
        }
        lock.withLock {
            if let newMask, background.isActive {
                mask = newMask
                maskTime = time
            }
            busy = false
        }
    }

    /// The camera picture with the background applied (or unchanged if none,
    /// or until the first mask is ready).
    public func apply(_ image: CIImage) -> CIImage {
        let (bg, bgImage, mask) = lock.withLock { (background, backgroundImage, self.mask) }
        guard bg.isActive, let mask else { return image }
        return BackgroundRenderer.render(camera: image, mask: mask, background: bg, image: bgImage)
    }
}

/// Carries a pixel buffer to the segmentation queue.
private struct PixelBox: @unchecked Sendable {
    let buffer: CVPixelBuffer
    init(_ buffer: CVPixelBuffer) { self.buffer = buffer }
}

/// Pure compositing of person + background (unit-tested with synthetic masks).
public enum BackgroundRenderer {
    public static func render(camera: CIImage, mask: CIImage, background: CameraBackground, image: CIImage?) -> CIImage {
        let extent = camera.extent
        guard extent.width > 0, extent.height > 0 else { return camera }
        let behind: CIImage
        switch background {
        case .none:
            return camera
        case .blur(let strength):
            let s = min(max(strength, 0), 1)
            let radius = (0.006 + 0.03 * s) * Double(max(extent.width, extent.height))
            behind = camera.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: extent)
        case .color(let hex):
            behind = CIImage(color: CIColor(hex: hex) ?? .black).cropped(to: extent)
        case .builtIn, .image:
            guard let image else { return camera }
            behind = aspectFill(image, into: extent)
        }
        // Feather the mask edge slightly so hair and shoulders blend.
        let feather = max(1, Double(extent.height) / 540)
        let softMask = mask.clampedToExtent().applyingGaussianBlur(sigma: feather).cropped(to: extent)
        return camera.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: behind,
            kCIInputMaskImageKey: softMask,
        ]).cropped(to: extent)
    }

    /// Scales and centres an image to cover a rect.
    public static func aspectFill(_ image: CIImage, into rect: CGRect) -> CIImage {
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return image }
        let s = max(rect.width / e.width, rect.height / e.height)
        let w = e.width * s, h = e.height * s
        return image
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: s, y: s))
            .transformed(by: CGAffineTransform(translationX: rect.minX + (rect.width - w) / 2, y: rect.minY + (rect.height - h) / 2))
            .cropped(to: rect)
    }

    /// A built-in background, drawn at 1920×1080.
    public static func builtIn(_ kind: BuiltInBackground, size: CGSize = CGSize(width: 1920, height: 1080)) -> CIImage? {
        let w = Int(size.width), h = Int(size.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        func color(_ hex: String, _ a: CGFloat = 1) -> CGColor { CIColor(hex: hex).map { CGColor(red: $0.red, green: $0.green, blue: $0.blue, alpha: a) } ?? .black }
        func linear(_ stops: [(String, CGFloat)], from: CGPoint, to: CGPoint) {
            let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map { color($0.0) } as CFArray,
                               locations: stops.map(\.1))!
            ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        func radial(_ inner: String, _ outer: String, center: CGPoint, radius: CGFloat, innerAlpha: CGFloat = 1, outerAlpha: CGFloat = 1) {
            let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                               colors: [color(inner, innerAlpha), color(outer, outerAlpha)] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius,
                                   options: [.drawsAfterEndLocation])
        }
        let W = CGFloat(w), H = CGFloat(h)
        switch kind {
        case .spotlight:
            linear([("#6C5CFF", 0), ("#D946EF", 0.52), ("#FF6A55", 1)], from: CGPoint(x: 0, y: H), to: CGPoint(x: W, y: 0))
        case .ink:
            ctx.setFillColor(color("#0B1020")); ctx.fill(rect)
            radial("#7B61FF", "#0B1020", center: CGPoint(x: W * 0.25, y: H * 0.8), radius: W * 0.7, innerAlpha: 0.55, outerAlpha: 0)
        case .studioGrey:
            radial("#9A9FAD", "#2B2E36", center: CGPoint(x: W * 0.5, y: H * 0.55), radius: W * 0.75)
        case .warmStudio:
            radial("#E9D6BC", "#5A4636", center: CGPoint(x: W * 0.45, y: H * 0.6), radius: W * 0.8)
        case .ocean:
            linear([("#0F766E", 0), ("#0B3A5C", 0.6), ("#0B1020", 1)], from: CGPoint(x: 0, y: H), to: CGPoint(x: W * 0.6, y: 0))
        case .sunset:
            linear([("#FFB347", 0), ("#FF6A55", 0.45), ("#6C3FA0", 1)], from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: H))
        case .bokeh:
            ctx.setFillColor(color("#141A33")); ctx.fill(rect)
            // Deterministic soft circles in brand colours.
            var seed: UInt64 = 0x5EED
            func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }
            let palette = ["#6C5CFF", "#D946EF", "#FF6A55", "#FFB020", "#34D399"]
            for i in 0..<38 {
                let r = H * (0.03 + 0.09 * rnd())
                let c = CGPoint(x: W * rnd(), y: H * rnd())
                radial(palette[i % palette.count], palette[i % palette.count], center: c, radius: r, innerAlpha: 0.10 + 0.25 * rnd(), outerAlpha: 0)
            }
        }
        guard let cg = ctx.makeImage() else { return nil }
        let image = CIImage(cgImage: cg)
        return kind == .bokeh ? image.clampedToExtent().applyingGaussianBlur(sigma: H / 90).cropped(to: image.extent) : image
    }
}

public extension CIColor {
    /// "#RRGGBB" or "RRGGBB".
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255,
                  colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }
}

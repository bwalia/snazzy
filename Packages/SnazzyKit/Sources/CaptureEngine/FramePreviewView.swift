import AppKit
import CoreImage
import MetalKit
import SnazzyCore

/// Shows a feed's latest frame after the inset transform (exactly the inset
/// region). Drag to move the crop, scroll or pinch to zoom.
public final class FramePreviewView: MTKView, MTKViewDelegate {
    public var receiver: FrameReceiver? { didSet { dirty = true } }
    public var profile = DeviceProfile(crop: InsetCrop()) { didSet { dirty = true } }
    /// Called while the user drags or zooms.
    public var onProfileChange: ((DeviceProfile) -> Void)?
    public var isInteractive = true

    private let ciContext: CIContext?
    private let queue: MTLCommandQueue?
    private var lastSequence = -1
    private var dirty = true
    private var dragStart: NSPoint?

    public init() {
        let device = MTLCreateSystemDefaultDevice()
        ciContext = device.map { CIContext(mtlDevice: $0, options: [.cacheIntermediates: false]) }
        queue = device?.makeCommandQueue()
        super.init(frame: .zero, device: device)
        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm
        preferredFramesPerSecond = 30
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        autoResizeDrawable = true
        delegate = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { dirty = true }

    public func draw(in view: MTKView) {
        guard let frame = receiver?.latest else { return }
        guard dirty || frame.sequence != lastSequence else { return }
        guard let ciContext, let queue, let drawable = currentDrawable,
              let buffer = queue.makeCommandBuffer() else { return }
        lastSequence = frame.sequence
        dirty = false

        let content = FrameTransform.apply(frame.image, profile: profile)
        let target = drawableSize
        let scale = min(target.width / max(content.extent.width, 1), target.height / max(content.extent.height, 1))
        let w = content.extent.width * scale, h = content.extent.height * scale
        let placed = content
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: (target.width - w) / 2, y: (target.height - h) / 2))
        let bounds = CGRect(origin: .zero, size: target)
        let image = placed.composited(over: CIImage(color: .black).cropped(to: bounds))

        let destination = CIRenderDestination(
            width: Int(target.width), height: Int(target.height), pixelFormat: colorPixelFormat,
            commandBuffer: buffer, mtlTextureProvider: { drawable.texture })
        _ = try? ciContext.startTask(toRender: image, to: destination)
        buffer.present(drawable)
        buffer.commit()
    }

    // MARK: Interaction

    /// Upright picture size and crop box for the current frame.
    private func geometry() -> (upright: CGSize, crop: CGRect)? {
        guard let size = receiver?.latest?.size else { return nil }
        let upright = InsetGeometry.uprightSize(size, rotation: profile.rotation)
        return (upright, InsetGeometry.cropRect(upright: upright, crop: profile.crop))
    }

    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
    }

    public override func mouseDragged(with event: NSEvent) {
        guard isInteractive, let start = dragStart, let (upright, crop) = geometry(), bounds.width > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let dx = point.x - start.x, dyUp = point.y - start.y
        dragStart = point
        // Moving the picture right shows what is to its left: the crop moves left.
        var p = profile
        p.crop.centerX -= dx * (crop.width / bounds.width) / upright.width
        p.crop.centerY += dyUp * (crop.height / bounds.height) / upright.height
        p.crop = p.crop.normalized
        profile = p
        onProfileChange?(p)
    }

    public override func mouseUp(with event: NSEvent) { dragStart = nil }

    public override func scrollWheel(with event: NSEvent) {
        guard isInteractive else { return }
        zoom(by: exp(-event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.004 : 0.04)))
    }

    public override func magnify(with event: NSEvent) {
        guard isInteractive else { return }
        zoom(by: 1 / (1 + event.magnification))
    }

    private func zoom(by factor: Double) {
        var p = profile
        p.crop.zoom *= factor
        p.crop = p.crop.normalized
        profile = p
        onProfileChange?(p)
    }
}

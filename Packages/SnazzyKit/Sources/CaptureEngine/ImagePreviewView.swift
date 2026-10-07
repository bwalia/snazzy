import AppKit
import CoreImage
import MetalKit

/// A Metal view that draws whatever image its provider returns, scaled to fit.
/// It redraws only when the provider's sequence number changes.
public final class ImagePreviewView: MTKView, MTKViewDelegate {
    /// Returns the current image and a number that changes whenever it does.
    public var provider: (@MainActor () -> (image: CIImage, sequence: Int)?)? { didSet { dirty = true } }

    private let ciContext: CIContext?
    private let queue: MTLCommandQueue?
    private var lastSequence = -1
    private var dirty = true

    public init() {
        let device = MTLCreateSystemDefaultDevice()
        ciContext = device.map { CIContext(mtlDevice: $0, options: [.cacheIntermediates: false]) }
        queue = device?.makeCommandQueue()
        super.init(frame: .zero, device: device)
        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm
        preferredFramesPerSecond = 30
        autoResizeDrawable = true
        delegate = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func invalidate() { dirty = true }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { dirty = true }

    public func draw(in view: MTKView) {
        guard let (image, sequence) = provider?() else { return }
        guard dirty || sequence != lastSequence else { return }
        guard let ciContext, let queue, let drawable = currentDrawable, let buffer = queue.makeCommandBuffer() else { return }
        lastSequence = sequence
        dirty = false
        let target = CGRect(origin: .zero, size: drawableSize)
        let placed = Compositor.fit(image, in: target).composited(over: CIImage(color: .black).cropped(to: target))
        let destination = CIRenderDestination(
            width: Int(target.width), height: Int(target.height), pixelFormat: colorPixelFormat,
            commandBuffer: buffer, mtlTextureProvider: { drawable.texture })
        _ = try? ciContext.startTask(toRender: placed, to: destination)
        buffer.present(drawable)
        buffer.commit()
    }
}

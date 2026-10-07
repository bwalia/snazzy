@preconcurrency import AVFoundation
import CoreImage
import Foundation

/// Receives a device's video frames on a capture queue and holds the latest
/// one. iOS devices only send frames when their screen changes, so the last
/// frame is kept indefinitely; gaps are not end of stream.
public final class FrameReceiver: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    public struct Frame: @unchecked Sendable {
        public let image: CIImage
        public let size: CGSize
        /// Presentation time on the capture (host) clock.
        public let time: CMTime
        public let sequence: Int
    }

    public struct Stats: Sendable {
        public var frames = 0
        public var dropped = 0
        /// `ProcessInfo.systemUptime` of the last frame, or nil if none yet.
        public var lastFrameUptime: TimeInterval?
        public var size: CGSize?
    }

    private let lock = NSLock()
    private var _latest: Frame?
    private var stats = Stats()
    private var consumers: [UUID: @Sendable (CMSampleBuffer) -> Void] = [:]

    public let queue = DispatchQueue(label: "com.snazzy.pro.frames", qos: .userInteractive)
    /// Background blur/replacement for this feed (inactive by default).
    public let effect = BackgroundEffect()

    public var latest: Frame? { lock.withLock { _latest } }

    /// The latest frame with the background effect applied: what previews, the
    /// composite and the recorder show. Raw tracks use the unprocessed buffers.
    public var latestImage: CIImage? { latest.map { effect.apply($0.image) } }
    public var snapshot: Stats { lock.withLock { stats } }

    /// Extra consumers of raw sample buffers (the recorder, from phase 4).
    /// Called on the capture queue; keep the work short.
    public func addConsumer(_ consumer: @escaping @Sendable (CMSampleBuffer) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { consumers[id] = consumer }
        return id
    }

    public func removeConsumer(_ id: UUID) {
        _ = lock.withLock { consumers.removeValue(forKey: id) }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let now = ProcessInfo.processInfo.systemUptime
        let current = lock.withLock { () -> [@Sendable (CMSampleBuffer) -> Void] in
            stats.frames += 1
            stats.lastFrameUptime = now
            stats.size = size
            _latest = Frame(image: image, size: size, time: time, sequence: stats.frames)
            return Array(consumers.values)
        }
        if effect.isActive { effect.process(sampleBuffer) }
        for consumer in current { consumer(sampleBuffer) }
    }

    public func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        lock.withLock { stats.dropped += 1 }
    }
}

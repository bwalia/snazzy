import AppKit
@preconcurrency import AVFoundation
import CoreImage
import Observation
@preconcurrency import ScreenCaptureKit
import SnazzyCore

/// Receives ScreenCaptureKit frames and holds the latest one. SCStream sends
/// frames only when the screen changes, so the last frame is kept.
public final class ScreenReceiver: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public struct Frame: @unchecked Sendable {
        public let image: CIImage
        public let pixelBuffer: CVPixelBuffer
        public let size: CGSize
        /// Presentation time on the host clock (same clock as AVCapture).
        public let time: CMTime
        public let sequence: Int
    }

    private let lock = NSLock()
    private var _latest: Frame?
    private var frames = 0
    private var consumers: [UUID: @Sendable (CMSampleBuffer) -> Void] = [:]
    var onStop: (@Sendable (Error?) -> Void)?

    public let queue = DispatchQueue(label: "com.snazzy.pro.screen", qos: .userInteractive)

    public var latest: Frame? { lock.withLock { _latest } }
    public var frameCount: Int { lock.withLock { frames } }

    /// Raw sample buffers (complete frames only), for the recorder.
    public func addConsumer(_ consumer: @escaping @Sendable (CMSampleBuffer) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { consumers[id] = consumer }
        return id
    }

    public func removeConsumer(_ id: UUID) {
        _ = lock.withLock { consumers.removeValue(forKey: id) }
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, Self.isComplete(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let current = lock.withLock { () -> [@Sendable (CMSampleBuffer) -> Void] in
            frames += 1
            _latest = Frame(image: image, pixelBuffer: pixelBuffer, size: size, time: time, sequence: frames)
            return Array(consumers.values)
        }
        for consumer in current { consumer(sampleBuffer) }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error)
    }

    /// Only `.complete` frames carry new pixels (idle/blank frames don't).
    static func isComplete(_ buffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }
}

/// A live capture of a display or window with ScreenCaptureKit. The app's own
/// windows (chat, previews, teleprompter) are excluded from display capture,
/// except windows meant to be recorded (e.g. the builder's result window).
@MainActor @Observable
public final class ScreenFeed {
    public enum Source: Hashable, Sendable {
        case display(UInt32)
        case window(UInt32)
        /// A window's content without its title bar (`topInset` points), e.g. the
        /// app's own slide window. The stream restarts if `size` (points) changes.
        case windowContent(UInt32, topInset: Double, size: CGSize)
    }

    public enum State: Equatable, Sendable {
        case idle
        case starting
        case live
        case needsPermission
        case failed(String)

        public var description: String {
            switch self {
            case .idle: "Off"
            case .starting: "Starting…"
            case .live: "Live"
            case .needsPermission: "Screen recording permission needed"
            case .failed(let m): m
            }
        }
    }

    public private(set) var state: State = .idle
    public private(set) var source: Source?
    public private(set) var frameSize: CGSize?
    public let receiver = ScreenReceiver()

    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private let diagnostics: Diagnostics
    @ObservationIgnored private var excludeOwnApp = true
    @ObservationIgnored private var includedWindowIDs: [UInt32] = []

    /// Longest side of captured frames (keeps 5K/6K displays manageable).
    public static let maxDimension: CGFloat = 3840
    public static let framesPerSecond: Int32 = 30

    public init(diagnostics: Diagnostics = .shared) {
        self.diagnostics = diagnostics
        receiver.onStop = { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                let message = error?.localizedDescription ?? "stopped"
                self.state = .failed("Screen capture stopped: \(message)")
                self.stream = nil
                self.diagnostics.log("Screen capture stopped: \(message)", category: "screen", level: .warning)
            }
        }
    }

    /// Starts (or retargets) the capture.
    public func start(_ source: Source, includingOwnWindows: [UInt32] = []) async {
        if self.source == source, stream != nil, includedWindowIDs == includingOwnWindows { return }
        await stop()
        self.source = source
        includedWindowIDs = includingOwnWindows
        guard CGPreflightScreenCaptureAccess() else {
            state = .needsPermission
            return
        }
        state = .starting
        do {
            let (filter, size, sourceRect) = try await makeFilter(source)
            let config = SCStreamConfiguration()
            if let sourceRect { config.sourceRect = sourceRect }
            let scale = min(1, Self.maxDimension / max(size.width, size.height))
            config.width = Int((size.width * scale).rounded(.down)) & ~1
            config.height = Int((size.height * scale).rounded(.down)) & ~1
            config.minimumFrameInterval = CMTime(value: 1, timescale: Self.framesPerSecond)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.colorSpaceName = CGColorSpace.sRGB
            config.showsCursor = true
            config.queueDepth = 6
            config.capturesAudio = false
            let stream = SCStream(filter: filter, configuration: config, delegate: receiver)
            try stream.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: receiver.queue)
            try await stream.startCapture()
            self.stream = stream
            frameSize = CGSize(width: config.width, height: config.height)
            state = .live
            diagnostics.log("Screen capture started (\(config.width)×\(config.height))", category: "screen")
        } catch {
            state = .failed(error.localizedDescription)
            diagnostics.log("Screen capture failed: \(error.localizedDescription)", category: "screen", level: .error)
        }
    }

    public func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
        state = .idle
        diagnostics.log("Screen capture stopped", category: "screen")
    }

    /// Updates which of the app's windows are allowed into a display capture.
    public func setIncludedOwnWindows(_ ids: [UInt32]) async {
        guard ids != includedWindowIDs, let source, let stream else { return }
        includedWindowIDs = ids
        if let (filter, _, _) = try? await makeFilter(source) {
            try? await stream.updateContentFilter(filter)
        }
    }

    private func makeFilter(_ source: Source) async throws -> (SCContentFilter, CGSize, CGRect?) {
        var content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        if case .windowContent(let id, _, _) = source {
            // A window that has just opened takes a moment to show up with its real frame.
            for _ in 0..<20 {
                if let w = content.windows.first(where: { $0.windowID == id }), w.frame.width > 1 { break }
                try await Task.sleep(for: .milliseconds(100))
                content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            }
        }
        switch source {
        case .display(let id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw CaptureError("That display isn't connected.")
            }
            let ownBundle = Bundle.main.bundleIdentifier
            let ownApps = content.applications.filter { $0.bundleIdentifier == ownBundle }
            let included = content.windows.filter { includedWindowIDs.contains($0.windowID) }
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: included)
            return (filter, pixelSize(filter, fallback: CGSize(width: display.width, height: display.height)), nil)
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw CaptureError("That window is no longer open.")
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            return (filter, pixelSize(filter, fallback: window.frame.size), nil)
        case .windowContent(let id, let topInset, _):
            guard let window = content.windows.first(where: { $0.windowID == id }), window.frame.width > 1 else {
                throw CaptureError("The Present window isn't open.")
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let full = filter.contentRect.width > 0 ? filter.contentRect.size : window.frame.size
            let rect = CGRect(x: 0, y: topInset, width: full.width, height: max(1, full.height - topInset))
            let scale = CGFloat(max(filter.pointPixelScale, 1))
            return (filter, CGSize(width: rect.width * scale, height: rect.height * scale), rect)
        }
    }

    private func pixelSize(_ filter: SCContentFilter, fallback: CGSize) -> CGSize {
        let rect = filter.contentRect
        let scale = CGFloat(filter.pointPixelScale)
        guard rect.width > 0, scale > 0 else { return fallback }
        return CGSize(width: rect.width * scale, height: rect.height * scale)
    }
}

public struct CaptureError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

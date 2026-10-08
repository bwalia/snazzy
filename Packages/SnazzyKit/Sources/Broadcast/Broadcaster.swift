@preconcurrency import AVFoundation
import CaptureEngine
import CoreImage
import Foundation
import HaishinKit
import RTMPHaishinKit
import SnazzyCore
import VideoToolbox

/// Where a broadcast goes. The stream key is the secret part; it lives in
/// the Keychain (account `keychainAccount`), never in settings or logs.
public enum BroadcastPlatform: String, CaseIterable, Codable, Identifiable, Sendable {
    case youtube, linkedin, twitch, vimeo, facebook, custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .youtube: "YouTube"
        case .linkedin: "LinkedIn"
        case .twitch: "Twitch"
        case .vimeo: "Vimeo"
        case .facebook: "Facebook"
        case .custom: "Custom RTMP server"
        }
    }

    /// The platform's RTMPS ingest (empty for custom).
    public var defaultServer: String {
        switch self {
        case .youtube: "rtmps://a.rtmps.youtube.com/live2"
        // LinkedIn gives a stream URL per event; paste it as the server.
        case .linkedin: ""
        case .twitch: "rtmps://live.twitch.tv:443/app"
        case .vimeo: "rtmps://rtmp-global.cloud.vimeo.com:443/live"
        case .facebook: "rtmps://live-api-s.facebook.com:443/rtmp/"
        case .custom: ""
        }
    }

    /// Where to find the stream key.
    public var keyHelp: String {
        switch self {
        case .youtube: "YouTube Studio › Create › Go live › Stream › Stream key"
        case .linkedin: "LinkedIn › Create an event › Live › Streaming tool: paste the Stream URL as the server and the Stream key here"
        case .twitch: "Twitch › Creator Dashboard › Settings › Stream › Primary Stream key"
        case .vimeo: "Vimeo › Live events › your event › Configure › RTMP › Stream key"
        case .facebook: "Facebook › Live Producer › Streaming software › Stream key"
        case .custom: "The stream name or key your server expects"
        }
    }

    public var keychainAccount: String { "broadcast.\(rawValue)" }
}

public struct BroadcastQuality: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    public let width: Int
    public let height: Int
    public let fps: Int
    public let videoBitrate: Int

    public static let hd1080 = BroadcastQuality(name: "1080p", width: 1920, height: 1080, fps: 30, videoBitrate: 4_500_000)
    public static let hd720 = BroadcastQuality(name: "720p", width: 1280, height: 720, fps: 30, videoBitrate: 2_500_000)
    public static let all = [hd1080, hd720]
}

/// Sends the live picture (the recording's composite: screen or slides with
/// the camera inset) and the mic to an RTMP(S) server, using HaishinKit for
/// the encoders and the RTMP protocol. Independent of recording and the
/// local live room; all three can run at once.
public final class Broadcaster: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case connecting
        case live
        case failed(String)
    }

    /// Called on the main actor.
    public var onState: (@MainActor @Sendable (State) -> Void)?

    /// About once a second while live: measured upload and the current video bitrate.
    public struct NetworkReport: Sendable, Equatable {
        public var uploadBitsPerSecond: Int
        public var videoBitrate: Int
        /// The connection couldn't keep up; the bitrate was lowered.
        public var insufficient: Bool
    }

    public var onNetwork: (@MainActor @Sendable (NetworkReport) -> Void)?

    private let lock = NSLock()
    private var screen: ScreenReceiver?
    private var camera: FrameReceiver?
    private var spec: CompositeSpec?
    private var connection: RTMPConnection?
    private var stream: RTMPStream?
    private var media: AsyncStream<Media>.Continuation?
    private var sender: Task<Void, Never>?
    private var watcher: Task<Void, Never>?
    private let queue = DispatchQueue(label: "com.snazzy.pro.broadcast", qos: .userInitiated)
    private let micQueue = DispatchQueue(label: "com.snazzy.pro.broadcast-mic")
    private var timer: DispatchSourceTimer?
    private var micSession: AVCaptureSession?
    private var micDelegate: BroadcastMicDelegate?
    private var pool: CVPixelBufferPool?
    private var formatDescription: CMVideoFormatDescription?
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var quality = BroadcastQuality.hd1080
    private var lastPTS = CMTime.invalid
    private(set) public var framesSent = 0
    private(set) public var audioSent = 0

    public init() {}

    public func setSource(screen: ScreenReceiver?, camera: FrameReceiver?, spec: CompositeSpec) {
        lock.withLock {
            self.screen = screen
            self.camera = camera
            self.spec = spec
        }
    }

    /// Connects, publishes and starts sending. Throws if the server refuses.
    public func start(server: String, key: String, quality: BroadcastQuality, micID: String?) async throws {
        guard connection == nil else { return }
        self.quality = quality
        await report(.connecting)
        let connection = RTMPConnection()
        let stream = RTMPStream(connection: connection)
        do {
            try await stream.setVideoSettings(VideoCodecSettings(
                videoSize: CGSize(width: quality.width, height: quality.height),
                bitRate: quality.videoBitrate,
                profileLevel: kVTProfileLevel_H264_High_AutoLevel as String,
                scalingMode: .letterbox,
                maxKeyFrameIntervalDuration: 2,
                allowFrameReordering: false,
                expectedFrameRate: Double(quality.fps)))
            try await stream.setAudioSettings(AudioCodecSettings(bitRate: 128_000))
            // Lower the bitrate automatically when the upload can't keep up, and tell the app.
            let report = onNetwork
            await stream.setBitRateStrategy(ReportingBitRateStrategy(maximum: quality.videoBitrate) { event, bitrate in
                guard let report else { return }
                let r: NetworkReport? = switch event {
                case .status(let s): NetworkReport(uploadBitsPerSecond: s.currentBytesOutPerSecond * 8, videoBitrate: bitrate, insufficient: false)
                case .publishInsufficientBWOccured(let s): NetworkReport(uploadBitsPerSecond: s.currentBytesOutPerSecond * 8, videoBitrate: bitrate, insufficient: true)
                case .reset: nil
                }
                if let r { await report(r) }
            })
            _ = try await connection.connect(server)
            _ = try await stream.publish(key)
        } catch {
            try? await connection.close()
            let message = Self.describe(error)
            await report(.failed(message))
            throw BroadcastError(message)
        }
        self.connection = connection
        self.stream = stream

        // One ordered queue of frames and audio into the stream actor.
        let (frames, continuation) = AsyncStream<Media>.makeStream(bufferingPolicy: .bufferingNewest(90))
        media = continuation
        sender = Task {
            for await item in frames {
                switch item {
                case .video(let box): await stream.append(box.buffer)
                case .audio(let box): await stream.append(box.buffer, when: box.when)
                }
            }
        }
        watcher = Task { [weak self] in
            for await status in await connection.status {
                if status.level == "error" || status.code == RTMPConnection.Code.connectClosed.rawValue {
                    await self?.report(.failed("The server ended the stream (\(status.code))."))
                    await self?.stop(reportIdle: false)
                    return
                }
            }
        }
        startPicture()
        startMic(micID)
        await report(.live)
    }

    public func stop() async { await stop(reportIdle: true) }

    private func stop(reportIdle: Bool) async {
        timer?.cancel()
        timer = nil
        micSession?.stopRunning()
        micSession = nil
        micDelegate = nil
        media?.finish()
        media = nil
        await sender?.value
        sender = nil
        watcher?.cancel()
        watcher = nil
        if let stream { _ = try? await stream.close() }
        if let connection { try? await connection.close() }
        stream = nil
        connection = nil
        if reportIdle { await report(.idle) }
    }

    private func report(_ state: State) async {
        guard let onState else { return }
        await onState(state)
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? RTMPConnection.Error {
            switch e {
            case .connectionTimedOut, .requestTimedOut: return "The server didn't answer. Check the server address and your internet connection."
            case .requestFailed(let r): return "The server refused: \(r.status?.code ?? "unknown")\(r.status?.description.isEmpty == false ? " (\(r.status!.description))" : ""). Check the stream key."
            case .unsupportedCommand: return "That server address isn't an rtmp:// or rtmps:// URL."
            case .socketErrorOccurred(let underlying): return "Network error: \(underlying?.localizedDescription ?? "connection failed")."
            default: return "Couldn't connect (\(e))."
            }
        }
        if let e = error as? RTMPStream.Error { return "The server refused to publish (\(e)). Check the stream key." }
        return error.localizedDescription
    }

    // MARK: Picture

    private func startPicture() {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: quality.width,
            kCVPixelBufferHeightKey as String: quality.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(quality.fps), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.sendFrame() }
        timer.resume()
        self.timer = timer
    }

    private func sendFrame() {
        let (screen, camera, spec) = lock.withLock { (self.screen, self.camera, self.spec) }
        guard var spec, let pool, let media else { return }
        let size = CGSize(width: quality.width, height: quality.height)
        spec.canvas = size  // the compositor scales the border with the canvas
        let image = Compositor.compose(screen: screen?.latest?.image, camera: camera?.latestImage, spec: spec)
        var pixels: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixels)
        guard let pixels else { return }
        context.render(image, to: pixels, bounds: CGRect(origin: .zero, size: size), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        if formatDescription == nil {
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels, formatDescriptionOut: &formatDescription)
        }
        guard let formatDescription else { return }
        let pts = spec.syncedVideoTime(CMClockGetTime(CMClockGetHostTimeClock()), hasCamera: camera != nil)
        guard !lastPTS.isValid || pts > lastPTS else { return }
        lastPTS = pts
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(quality.fps)), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixels, formatDescription: formatDescription,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        if let sample {
            media.yield(.video(VideoBox(buffer: sample)))
            framesSent += 1
        }
    }

    // MARK: Sound

    private func startMic(_ micID: String?) {
        guard micID != "none" else { return }
        let device = micID.flatMap { AVCaptureDevice(uniqueID: $0) } ?? AVCaptureDevice.default(for: .audio)
        guard let device, let input = try? AVCaptureDeviceInput(device: device) else { return }
        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let delegate = BroadcastMicDelegate { [weak self] sample in self?.sendAudio(sample) }
        output.setSampleBufferDelegate(delegate, queue: micQueue)
        guard session.canAddInput(input), session.canAddOutput(output) else { return }
        session.addInput(input)
        session.addOutput(output)
        session.startRunning()
        micSession = session
        micDelegate = delegate
    }

    private func sendAudio(_ sample: CMSampleBuffer) {
        guard let media, let pcm = Self.pcmBuffer(sample) else { return }
        let when = AVAudioTime(hostTime: CMClockConvertHostTimeToSystemUnits(CMSampleBufferGetPresentationTimeStamp(sample)))
        media.yield(.audio(AudioBox(buffer: pcm, when: when)))
        audioSent += 1
    }

    /// A PCM sample buffer as an AVAudioPCMBuffer (what HaishinKit's AAC encoder takes).
    static func pcmBuffer(_ sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = CMSampleBufferGetFormatDescription(sample) else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: desc)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}

public struct BroadcastError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

private enum Media: Sendable {
    case video(VideoBox)
    case audio(AudioBox)
}

private struct VideoBox: @unchecked Sendable { let buffer: CMSampleBuffer }
private struct AudioBox: @unchecked Sendable { let buffer: AVAudioPCMBuffer; let when: AVAudioTime }

private final class BroadcastMicDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let handler: @Sendable (CMSampleBuffer) -> Void
    init(_ handler: @escaping @Sendable (CMSampleBuffer) -> Void) { self.handler = handler }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        handler(sampleBuffer)
    }
}

/// HaishinKit's adaptive bitrate (drops quality when the upload can't keep
/// up, recovers slowly), plus a report to the app after each measurement.
actor ReportingBitRateStrategy: StreamBitRateStrategy {
    nonisolated let mamimumVideoBitRate: Int
    nonisolated let mamimumAudioBitRate = 0
    private let inner: StreamVideoAdaptiveBitRateStrategy
    private let report: @Sendable (NetworkMonitorEvent, Int) async -> Void

    init(maximum: Int, report: @escaping @Sendable (NetworkMonitorEvent, Int) async -> Void) {
        mamimumVideoBitRate = maximum
        inner = StreamVideoAdaptiveBitRateStrategy(mamimumVideoBitrate: maximum)
        self.report = report
    }

    func adjustBitrate(_ event: NetworkMonitorEvent, stream: some StreamConvertible) async {
        await inner.adjustBitrate(event, stream: stream)
        await report(event, await stream.videoSettings.bitRate)
    }
}

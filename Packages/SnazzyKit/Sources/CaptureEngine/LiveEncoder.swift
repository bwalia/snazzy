@preconcurrency import AVFoundation
import CoreImage
import Foundation
import SnazzyCore
import UniformTypeIdentifiers

/// Encodes the live picture (screen or slides + camera inset, composited the
/// same way as recordings) and the mic into fragmented MP4 segments of about
/// one second, for the live room. Runs alongside recording; it never touches
/// the recording files.
public final class LiveEncoder: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    public struct Quality: Sendable, Equatable {
        public var width: Int
        public var height: Int
        public var fps: Int32
        public var videoBitrate: Int

        public static let standard = Quality(width: 1280, height: 720, fps: 30, videoBitrate: 2_500_000)
        /// Sharp text on big screens; needs a good network.
        public static let high = Quality(width: 1920, height: 1080, fps: 30, videoBitrate: 4_500_000)
        /// For busy or slow Wi-Fi.
        public static let low = Quality(width: 854, height: 480, fps: 24, videoBitrate: 900_000)

        public init(width: Int, height: Int, fps: Int32, videoBitrate: Int) {
            self.width = width
            self.height = height
            self.fps = fps
            self.videoBitrate = videoBitrate
        }
    }

    public var onInitSegment: (@Sendable (Data) -> Void)?
    public var onSegment: (@Sendable (Data, Double) -> Void)?
    public var onError: (@Sendable (String) -> Void)?

    private let queue = DispatchQueue(label: "com.snazzy.pro.live-encoder", qos: .userInitiated)
    private let micQueue = DispatchQueue(label: "com.snazzy.pro.live-mic")
    private let lock = NSLock()
    private var screen: ScreenReceiver?
    private var camera: FrameReceiver?
    private var spec: CompositeSpec?

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var timer: DispatchSourceTimer?
    private var micSession: AVCaptureSession?
    private var micDelegate: MicDelegate?
    private let clock = CMClockGetHostTimeClock()
    private var start = CMTime.invalid
    private var lastVideo = CMTime.invalid
    /// End of the last audio appended (real or silence).
    private var lastAudioEnd = CMTime.invalid
    private var silenceFormat: CMAudioFormatDescription?
    /// For reopening the mic when it goes quiet (another recording or the
    /// chat mic can take it over).
    private var micID: String?
    private var lastMicSample = Date()
    private var lastMicRestart = Date.distantPast
    private var quality = Quality.standard
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var failed = false

    public private(set) var isRunning = false
    private var framesIn = 0, audioIn = 0, segmentsOut = 0

    /// Video frames encoded so far (the app restarts the encoder if this stops).
    public var framesEncoded: Int { queue.sync { framesIn } }

    /// For diagnostics: frames and audio buffers encoded, segments produced, writer status.
    public var stats: String {
        queue.sync { "frames=\(framesIn) audio=\(audioIn) segments=\(segmentsOut) status=\(writer?.status.rawValue ?? -1) error=\(writer?.error.map { e in let n = e as NSError; return "\(n.domain) \(n.code) \(n.userInfo)" } ?? "none")" }
    }

    /// What to show. Call again when the source, camera or layout changes.
    public func setSource(screen: ScreenReceiver?, camera: FrameReceiver?, spec: CompositeSpec) {
        lock.withLock {
            self.screen = screen
            self.camera = camera
            self.spec = spec
        }
    }

    public func start(micID: String?, quality: Quality = .standard) throws {
        guard !isRunning else { return }
        self.quality = quality
        let writer = AVAssetWriter(contentType: UTType(AVFileType.mp4.rawValue)!)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        writer.initialSegmentStartTime = .zero
        writer.delegate = self

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: quality.width,
            AVVideoHeightKey: quality.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: quality.videoBitrate,
                AVVideoMaxKeyFrameIntervalKey: Int(quality.fps),
                AVVideoMaxKeyFrameIntervalDurationKey: 1.0,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: Int(quality.fps),
            ] as [String: Any],
        ])
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { throw CaptureError("Live video can't be encoded.") }
        writer.add(video)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: quality.width,
            kCVPixelBufferHeightKey as String: quality.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ])

        var audio: AVAssetWriterInput?
        if micID != "none" {
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96_000,
                AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
            ])
            a.expectsMediaDataInRealTime = true
            if writer.canAdd(a) { writer.add(a); audio = a }
        }

        guard writer.startWriting() else { throw CaptureError(writer.error?.localizedDescription ?? "Live encoding couldn't start.") }
        writer.startSession(atSourceTime: .zero)
        queue.sync {
            self.writer = writer
            self.videoInput = video
            self.audioInput = audio
            self.adaptor = adaptor
            self.start = CMClockGetTime(clock)
            self.lastVideo = .invalid
            self.lastAudioEnd = .invalid
            self.failed = false
        }
        if audio != nil {
            self.micID = micID
            queue.sync { lastMicSample = Date() }
            startMic(micID)
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(quality.fps), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.encodeFrame() }
        timer.resume()
        self.timer = timer
        isRunning = true
    }

    public func stop() async {
        guard isRunning else { return }
        isRunning = false
        timer?.cancel()
        timer = nil
        micSession?.stopRunning()
        micSession = nil
        micDelegate = nil
        let writer: AVAssetWriter? = queue.sync {
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
            let w = self.writer
            self.writer = nil
            self.videoInput = nil
            self.audioInput = nil
            self.adaptor = nil
            return w
        }
        if let writer, writer.status == .writing { await writer.finishWriting() }
    }

    // MARK: Video

    private func encodeFrame() {
        guard let writer, writer.status == .writing, let input = videoInput, let adaptor, input.isReadyForMoreMediaData else {
            checkFailure()
            return
        }
        let (screen, camera, spec) = lock.withLock { (self.screen, self.camera, self.spec) }
        guard var spec else { return }
        let size = CGSize(width: quality.width, height: quality.height)
        // Composite at the stream size: the same layout as recordings (the compositor
        // scales the border with the canvas).
        spec.canvas = size
        let image = Compositor.compose(screen: screen?.latest?.image, camera: camera?.latestImage, spec: spec)
        guard let pool = adaptor.pixelBufferPool else { return }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return }
        context.render(image, to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let t = CMTimeSubtract(spec.syncedVideoTime(CMClockGetTime(clock), hasCamera: camera != nil), start)
        guard t.seconds >= 0, !lastVideo.isValid || CMTimeCompare(t, lastVideo) > 0 else { return }
        lastVideo = t
        if adaptor.append(buffer, withPresentationTime: t) { framesIn += 1 } else { checkFailure() }
        // The writer only finishes a segment when both tracks reach it: if the
        // mic goes quiet (unplugged, taken by another app), fill with silence
        // so the picture never stalls.
        if audioInput != nil {
            fillSilence(upTo: CMTimeSubtract(t, CMTime(value: 1, timescale: 4)))
            if Date().timeIntervalSince(lastMicSample) > 3, Date().timeIntervalSince(lastMicRestart) > 5 {
                lastMicRestart = Date()
                let id = micID
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.restartMic(id) }
            }
        }
    }

    private func checkFailure() {
        guard let writer, writer.status == .failed, !failed else { return }
        failed = true
        onError?(writer.error?.localizedDescription ?? "Live encoding stopped.")
    }

    // MARK: Audio

    /// Reopens the mic after it went quiet.
    private func restartMic(_ micID: String?) {
        guard isRunning else { return }
        micSession?.stopRunning()
        micSession = nil
        micDelegate = nil
        startMic(micID)
    }

    private func startMic(_ micID: String?) {
        let device = micID.flatMap { AVCaptureDevice(uniqueID: $0) } ?? AVCaptureDevice.default(for: .audio)
        guard let device, let input = try? AVCaptureDeviceInput(device: device) else { return }
        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        // Plain 48 kHz mono PCM, whatever the mic's native format.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let delegate = MicDelegate { [weak self] buffer in self?.appendAudio(buffer) }
        output.setSampleBufferDelegate(delegate, queue: micQueue)
        guard session.canAddInput(input), session.canAddOutput(output) else { return }
        session.addInput(input)
        session.addOutput(output)
        session.startRunning()
        micSession = session
        micDelegate = delegate
    }

    private func appendAudio(_ sample: CMSampleBuffer) {
        let box = SampleBox(sample)
        queue.async { [self] in
            let buffer = box.buffer
            lastMicSample = Date()
            guard let writer, writer.status == .writing, let input = audioInput, input.isReadyForMoreMediaData else { return }
            let pts = CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(buffer), start)
            // Start audio with the video, so the first segment begins with a picture.
            guard pts.seconds >= 0, lastVideo.isValid else { return }
            // Skip audio that overlaps silence already written.
            if lastAudioEnd.isValid, CMTimeCompare(pts, lastAudioEnd) < 0 { return }
            let retimed = buffer.retimed(to: pts)
            if let retimed { lastAudioEnd = CMTimeAdd(pts, CMSampleBufferGetDuration(retimed)) }
            if let retimed, input.append(retimed) { audioIn += 1 }
        }
    }

    /// Appends silence from the end of the last audio up to `time` (on `queue`).
    private func fillSilence(upTo time: CMTime) {
        guard let input = audioInput, input.isReadyForMoreMediaData, time.seconds > 0 else { return }
        let from = lastAudioEnd.isValid ? lastAudioEnd : (time.seconds > 1 ? .zero : time)
        let gap = CMTimeSubtract(time, from).seconds
        // Only real gaps (the mic normally delivers every ~20 ms).
        guard gap > 0.35 else { return }
        let frames = min(Int(gap * 48_000), 48_000)
        guard let sample = silence(at: from, frames: frames), input.append(sample) else { return }
        lastAudioEnd = CMTimeAdd(from, CMTime(value: CMTimeValue(frames), timescale: 48_000))
    }

    private func silence(at time: CMTime, frames: Int) -> CMSampleBuffer? {
        if silenceFormat == nil {
            var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                                   mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                                   mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
                                                   mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                           magicCookie: nil, extensions: nil, formatDescriptionOut: &silenceFormat)
        }
        guard let format = silenceFormat else { return nil }
        var block: CMBlockBuffer?
        let bytes = frames * 2
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block, CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) == noErr
        else { return nil }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format,
                                                             sampleCount: frames, presentationTimeStamp: time,
                                                             packetDescriptions: nil, sampleBufferOut: &sample)
        return sample
    }

    // MARK: Segments

    public func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data,
                            segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        switch segmentType {
        case .initialization:
            onInitSegment?(segmentData)
        case .separable:
            queue.async { self.segmentsOut += 1 }
            let duration = segmentReport?.trackReports.first(where: { $0.mediaType == .video })?.duration.seconds ?? 1
            onSegment?(segmentData, duration.isFinite && duration > 0 ? duration : 1)
        @unknown default:
            break
        }
    }
}

private final class MicDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let handler: @Sendable (CMSampleBuffer) -> Void
    init(_ handler: @escaping @Sendable (CMSampleBuffer) -> Void) { self.handler = handler }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        handler(sampleBuffer)
    }
}

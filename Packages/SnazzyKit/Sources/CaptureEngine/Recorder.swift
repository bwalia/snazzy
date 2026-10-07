@preconcurrency import AVFoundation
import CoreImage
import Foundation
import Metal
import Observation
import SnazzyCore

/// Files written by one recording.
public struct RecordingResult: Sendable, Hashable {
    public var composite: URL
    public var rawFolder: URL
    public var duration: TimeInterval
    public var freezes: [CameraFeed.Freeze]
    public var droppedFrames: Int
}

/// Records the screen, one camera inset and the mic in one process on the
/// host clock: a composited 1080p movie plus raw tracks (screen, camera, mic)
/// and a timeline, so the inset can be laid out again later. A stalled or
/// unplugged camera never stops the screen or mic: the inset holds its last
/// frame and the freeze is marked in the timeline.
@MainActor @Observable
public final class Recorder {
    public enum State: Equatable, Sendable {
        case idle
        case countdown(Int)
        case recording
        case paused
        case finishing
        case failed(String)
    }

    public private(set) var state: State = .idle
    /// Recorded time, excluding pauses.
    public private(set) var elapsed: TimeInterval = 0
    public private(set) var lastResult: RecordingResult?
    public private(set) var micLevel: Double = 0
    public private(set) var warning: String?

    public static var defaultFolder: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appending(path: "Snazzy Pro/Recordings", directoryHint: .isDirectory)
    }

    @ObservationIgnored private var session: RecordingSession?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var cameraFeed: CameraFeed?
    @ObservationIgnored private var startDate = Date()
    @ObservationIgnored private let diagnostics: Diagnostics

    public init(diagnostics: Diagnostics = .shared) {
        self.diagnostics = diagnostics
    }

    public var isActive: Bool {
        switch state {
        case .countdown, .recording, .paused, .finishing: true
        default: false
        }
    }

    /// Starts after an optional countdown. The screen feed must be live.
    public func start(screen: ScreenFeed, camera: CameraFeed?, micID: String?, spec: CompositeSpec,
                      countdown: Int = 3, folder: URL = Recorder.defaultFolder) async throws {
        guard !isActive else { throw CaptureError("Already recording.") }
        guard screen.state == .live else {
            throw CaptureError(screen.state == .needsPermission
                ? "Screen recording permission is needed. Allow it in the Sources panel."
                : "The screen capture isn't running (\(screen.state.description)). Choose a display or window first.")
        }
        warning = nil
        if countdown > 0 {
            for n in stride(from: countdown, to: 0, by: -1) {
                state = .countdown(n)
                try? await Task.sleep(for: .seconds(1))
                if state != .countdown(n) { return }  // cancelled
            }
        }
        let stamp = Self.stamp.string(from: Date())
        let composite = folder.appending(path: "presentation-\(stamp).mov")
        let raw = folder.appending(path: "presentation-\(stamp) raw", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
            let session = try RecordingSession(composite: composite, rawFolder: raw, spec: spec)
            session.onMicLevel = { [weak self] level in Task { @MainActor in self?.micLevel = level } }
            session.onWarning = { [weak self] message in
                Task { @MainActor in
                    self?.warning = message
                    self?.diagnostics.log(message, category: "recording", level: .warning)
                }
            }
            try session.start(screen: screen.receiver, camera: camera?.receiver, micID: micID)
            self.session = session
            cameraFeed = camera
            startDate = Date()
            elapsed = 0
            state = .recording
            diagnostics.log("Recording started: \(composite.lastPathComponent)", category: "recording")
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self, let session = self.session else { return }
                    self.elapsed = session.recordedSeconds
                    if let error = session.failure {
                        self.diagnostics.log("Recording failed: \(error)", category: "recording", level: .error)
                        _ = await self.stop()
                        self.state = .failed(error)
                        return
                    }
                }
            }
        } catch {
            state = .failed(error.localizedDescription)
            diagnostics.log("Recording could not start: \(error.localizedDescription)", category: "recording", level: .error)
            throw error
        }
    }

    public func cancelCountdown() {
        if case .countdown = state { state = .idle }
    }

    public func pause() {
        guard state == .recording, let session else { return }
        session.pause()
        state = .paused
        diagnostics.log("Recording paused", category: "recording")
    }

    public func resume() {
        guard state == .paused, let session else { return }
        session.resume()
        state = .recording
        diagnostics.log("Recording resumed", category: "recording")
    }

    /// Keeps the composite in step with layout/crop changes made while recording.
    public func update(spec: CompositeSpec) {
        session?.setSpec(spec)
    }

    @discardableResult
    public func stop() async -> RecordingResult? {
        if case .countdown = state { state = .idle; return nil }
        guard let session, state == .recording || state == .paused else { return nil }
        state = .finishing
        ticker?.cancel()
        let freezes = (cameraFeed?.freezes ?? []).filter { $0.start >= startDate }
            + (cameraFeed.flatMap { feed -> CameraFeed.Freeze? in
                switch feed.state {
                case .stalled, .disconnected, .noFrames: CameraFeed.Freeze(start: Date(), duration: 0)
                default: nil
                }
            }.map { [$0] } ?? [])
        let result = await session.finish(freezes: freezes, recordingStart: startDate)
        self.session = nil
        cameraFeed = nil
        micLevel = 0
        switch result {
        case .success(let r):
            lastResult = r
            state = .idle
            diagnostics.log(String(format: "Recording saved: %@ (%.1fs, %d dropped frames)", r.composite.lastPathComponent, r.duration, r.droppedFrames),
                            category: "recording")
            return r
        case .failure(let error):
            state = .failed(error.localizedDescription)
            diagnostics.log("Recording failed to save: \(error.localizedDescription)", category: "recording", level: .error)
            return nil
        }
    }

    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}

/// The writers and the 30 fps composite clock. Everything runs on one
/// serial queue; capture callbacks hop onto it.
final class RecordingSession: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.snazzy.pro.recorder", qos: .userInitiated)
    private let compositeURL: URL
    private let rawFolder: URL
    private let fps: Int32 = 30

    // Composite
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput
    private let ciContext: CIContext
    private var spec: CompositeSpec
    private var timer: DispatchSourceTimer?

    // Raw tracks (created on first sample)
    private var screenRaw: RawTrack?
    private var cameraRaw: RawTrack?
    private var micRaw: RawTrack?

    // Sources
    private weak var screen: ScreenReceiver?
    private weak var camera: FrameReceiver?
    private var screenConsumer: UUID?
    private var cameraConsumer: UUID?
    private var micSession: AVCaptureSession?
    private let micQueue = DispatchQueue(label: "com.snazzy.pro.recorder.mic")

    // Timing (host clock)
    private let clock = CMClockGetHostTimeClock()
    private var startTime = CMTime.invalid
    private var pausedTotal = CMTime.zero
    private var pausedAt: CMTime?
    private var lastVideoTime = CMTime.invalid
    /// Recording time of the first composite frame; the movie starts here so
    /// it has no empty lead-in. Audio before it is dropped.
    private var sessionStart: CMTime?
    private(set) var droppedFrames = 0
    private var lastLevel = Date.distantPast
    private var lastMicSample = Date()
    private var micWarned = false

    var onMicLevel: (@Sendable (Double) -> Void)?
    var onWarning: (@Sendable (String) -> Void)?

    private let stateLock = NSLock()
    private var _failure: String?
    private var _recorded: Double = 0
    var failure: String? { stateLock.withLock { _failure } }
    var recordedSeconds: Double { stateLock.withLock { _recorded } }

    init(composite: URL, rawFolder: URL, spec: CompositeSpec) throws {
        compositeURL = composite
        self.rawFolder = rawFolder
        self.spec = spec
        writer = try AVAssetWriter(outputURL: composite, fileType: .mov)
        let w = Int(spec.canvas.width), h = Int(spec.canvas.height)
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 12_000_000,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 48_000,
            AVEncoderBitRateKey: 160_000,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
        ])
        audioInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else { throw CaptureError("Can't set up the movie writer.") }
        writer.add(videoInput)
        writer.add(audioInput)
        ciContext = MTLCreateSystemDefaultDevice().map { CIContext(mtlDevice: $0) } ?? CIContext()
        super.init()
    }

    func setSpec(_ spec: CompositeSpec) {
        queue.async { self.spec = spec }
    }

    func start(screen: ScreenReceiver, camera: FrameReceiver?, micID: String?) throws {
        guard writer.startWriting() else {
            throw CaptureError("Can't write the movie: \(writer.error?.localizedDescription ?? "unknown error")")
        }
        let now = CMClockGetTime(clock)
        queue.sync { startTime = now }
        self.screen = screen
        self.camera = camera

        // Raw tracks: every complete screen frame and every camera frame.
        screenConsumer = screen.addConsumer { [weak self] buffer in self?.raw(buffer, kind: .screen) }
        if let camera { cameraConsumer = camera.addConsumer { [weak self] buffer in self?.raw(buffer, kind: .camera) } }

        try startMic(micID)

        // Composite at a constant 30 fps from the latest frames.
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(Int(1_000_000_000 / fps)), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.renderFrame() }
        timer.resume()
        self.timer = timer
    }

    private func startMic(_ micID: String?) throws {
        guard let mic = micID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .audio) else {
            onWarning?("No microphone: recording without sound.")
            return
        }
        let session = AVCaptureSession()
        session.beginConfiguration()
        let input = try AVCaptureDeviceInput(device: mic)
        guard session.canAddInput(input) else { throw CaptureError("Can't use \(mic.localizedName).") }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: micQueue)
        guard session.canAddOutput(output) else { throw CaptureError("Can't read audio from \(mic.localizedName).") }
        session.addOutput(output)
        session.commitConfiguration()
        session.startRunning()
        micSession = session
        NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
            let message = (note.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "unknown"
            self?.onWarning?("Microphone error: \(message). The screen keeps recording.")
        }
    }

    // MARK: Timing

    /// Recording time for a host-clock timestamp (pauses removed), or nil if
    /// the sample falls in a pause or before the start.
    private func recordingTime(_ host: CMTime) -> CMTime? {
        guard startTime.isValid, pausedAt == nil else { return nil }
        let t = host - startTime - pausedTotal
        return t >= .zero ? t : nil
    }

    func pause() {
        let now = CMClockGetTime(clock)
        queue.async { if self.pausedAt == nil { self.pausedAt = now } }
    }

    func resume() {
        let now = CMClockGetTime(clock)
        queue.async {
            if let p = self.pausedAt {
                self.pausedTotal = self.pausedTotal + (now - p)
                self.pausedAt = nil
            }
        }
    }

    // MARK: Composite video

    private func renderFrame() {
        guard writer.status == .writing else {
            if writer.status == .failed { fail(writer.error?.localizedDescription ?? "writer failed") }
            return
        }
        guard let t = recordingTime(CMClockGetTime(clock)) else { return }
        // Keep timestamps strictly increasing.
        if lastVideoTime.isValid, t <= lastVideoTime { return }
        guard videoInput.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else {
            droppedFrames += 1
            return
        }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { droppedFrames += 1; return }
        let image = Compositor.compose(screen: screen?.latest?.image, camera: camera?.latestImage, spec: spec)
        ciContext.render(image, to: buffer, bounds: CGRect(origin: .zero, size: spec.canvas), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        if sessionStart == nil {
            writer.startSession(atSourceTime: t)
            sessionStart = t
        }
        if adaptor.append(buffer, withPresentationTime: t) {
            lastVideoTime = t
            stateLock.withLock { _recorded = t.seconds }
        } else {
            droppedFrames += 1
        }
        // Mic silent for too long → probably disconnected.
        if micSession != nil, Date().timeIntervalSince(lastMicSample) > 2, !micWarned {
            micWarned = true
            onWarning?("No audio from the microphone for 2 s. Is it still connected? The screen keeps recording.")
        }
    }

    // MARK: Audio

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let box = SampleBox(sampleBuffer)
        queue.async { self.audio(box.buffer) }
    }

    private func audio(_ buffer: CMSampleBuffer) {
        lastMicSample = Date()
        micWarned = false
        if Date().timeIntervalSince(lastLevel) > 0.05 {
            lastLevel = Date()
            onMicLevel?(AudioLevel.rms(buffer))
        }
        guard writer.status == .writing, let t = recordingTime(CMSampleBufferGetPresentationTimeStamp(buffer)),
              let retimed = buffer.retimed(to: t) else { return }
        if let start = sessionStart, t >= start, audioInput.isReadyForMoreMediaData { audioInput.append(retimed) }
        raw(retimed, kind: .mic, alreadyRetimed: true)
    }

    // MARK: Raw tracks

    enum RawKind { case screen, camera, mic }

    private func raw(_ buffer: CMSampleBuffer, kind: RawKind, alreadyRetimed: Bool = false) {
        if alreadyRetimed {
            writeRaw(buffer, kind: kind, alreadyRetimed: true)
        } else {
            let box = SampleBox(buffer)
            queue.async { self.writeRaw(box.buffer, kind: kind, alreadyRetimed: false) }
        }
    }

    /// Runs on `queue`.
    private func writeRaw(_ buffer: CMSampleBuffer, kind: RawKind, alreadyRetimed: Bool) {
        do {
            let sample: CMSampleBuffer
            if alreadyRetimed {
                sample = buffer
            } else {
                guard let t = recordingTime(CMSampleBufferGetPresentationTimeStamp(buffer)), let r = buffer.retimed(to: t) else { return }
                sample = r
            }
            switch kind {
            case .screen:
                if screenRaw == nil { screenRaw = try RawTrack(url: rawFolder.appending(path: "screen.mov"), video: sample, codec: .hevc, bitRate: 24_000_000) }
                screenRaw?.append(sample)
            case .camera:
                if cameraRaw == nil { cameraRaw = try RawTrack(url: rawFolder.appending(path: "camera.mov"), video: sample, codec: .hevc, bitRate: 10_000_000) }
                cameraRaw?.append(sample)
            case .mic:
                if micRaw == nil { micRaw = try RawTrack(url: rawFolder.appending(path: "mic.mov"), audio: sample) }
                micRaw?.append(sample)
            }
        } catch {
            onWarning?("Raw \(kind) track unavailable: \(error.localizedDescription)")
        }
    }

    // MARK: Finish

    private func fail(_ message: String) {
        stateLock.withLock { if _failure == nil { _failure = message } }
    }

    func finish(freezes: [CameraFeed.Freeze], recordingStart: Date) async -> Result<RecordingResult, Error> {
        if let id = screenConsumer { screen?.removeConsumer(id) }
        if let id = cameraConsumer { camera?.removeConsumer(id) }
        micSession?.stopRunning()
        micSession = nil
        let (end, dropped, raws): (CMTime, Int, [RawTrack]) = queue.sync {
            timer?.cancel()
            timer = nil
            if let p = pausedAt { pausedTotal = pausedTotal + (CMClockGetTime(clock) - p); pausedAt = nil }
            if sessionStart == nil { writer.startSession(atSourceTime: .zero); sessionStart = .zero }
            videoInput.markAsFinished()
            audioInput.markAsFinished()
            let end = lastVideoTime.isValid ? lastVideoTime : .zero
            writer.endSession(atSourceTime: end + CMTime(value: 1, timescale: fps))
            return (end, droppedFrames, [screenRaw, cameraRaw, micRaw].compactMap { $0 })
        }
        await writer.finishWriting()
        for track in raws {
            if let e = track.error { onWarning?("A raw track failed: \(e)") }
            await track.finish()
        }
        if writer.status != .completed {
            return .failure(CaptureError(writer.error?.localizedDescription ?? "The movie couldn't be finished."))
        }
        let duration = end.seconds - (queue.sync { sessionStart?.seconds } ?? 0) + 1 / Double(fps)
        let result = RecordingResult(composite: compositeURL, rawFolder: rawFolder, duration: duration, freezes: freezes, droppedFrames: dropped)
        writeTimeline(result, recordingStart: recordingStart)
        return .success(result)
    }

    private func writeTimeline(_ result: RecordingResult, recordingStart: Date) {
        let freezes: [JSONValue] = result.freezes.map {
            ["at_seconds": .number(max(0, $0.start.timeIntervalSince(recordingStart))), "duration_seconds": .number($0.duration)]
        }
        let timeline: JSONValue = [
            "version": 1,
            "created": .string(ISO8601DateFormatter().string(from: recordingStart)),
            "duration_seconds": .number(result.duration),
            "composite": .string(result.composite.lastPathComponent),
            "canvas": [.number(spec.canvas.width), .number(spec.canvas.height)],
            "fps": .number(Double(fps)),
            "dropped_frames": .number(Double(result.droppedFrames)),
            "files": ["screen": "screen.mov", "camera": "camera.mov", "mic": "mic.mov"],
            "inset": [
                "corner": .string(spec.layout.corner.rawValue), "size": .number(spec.layout.size),
                "border_width": .number(spec.layout.borderWidth), "corner_radius": .number(spec.layout.cornerRadius),
                "rotation": .string(spec.profile.rotation.rawValue), "zoom": .number(spec.profile.crop.zoom),
                "center_x": .number(spec.profile.crop.centerX), "center_y": .number(spec.profile.crop.centerY),
                "aspect": spec.profile.crop.aspect.map(JSONValue.number) ?? "fit",
                "video_delay_ms": .number(spec.profile.videoDelayMs),
            ],
            "camera_freezes": .array(freezes),
            "composite_starts_at_seconds": .number(queue.sync { sessionStart?.seconds } ?? 0),
            "note": "Times are seconds from the start of the recording with pauses removed. Raw tracks share this timeline; the composite movie begins at composite_starts_at_seconds.",
        ]
        try? timeline.encoded().write(to: rawFolder.appending(path: "timeline.json"))
    }
}

/// One raw track file. Video is re-encoded (HEVC) at its own size and frame
/// times; audio is kept as-is (PCM).
final class RawTrack: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var lastTime = CMTime.invalid

    init(url: URL, video sample: CMSampleBuffer, codec: AVVideoCodecType, bitRate: Int) throws {
        guard let pixels = CMSampleBufferGetImageBuffer(sample) else { throw CaptureError("No image in sample") }
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let w = CVPixelBufferGetWidth(pixels) & ~1, h = CVPixelBufferGetHeight(pixels) & ~1
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitRate],
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
    }

    init(url: URL, audio sample: CMSampleBuffer) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        // Lossless 24-bit interleaved PCM at the mic's own rate and channel count
        // (mics often deliver float, non-interleaved audio, which .mov can't pass through).
        let asbd = CMSampleBufferGetFormatDescription(sample).flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let channels = Int(asbd?.mChannelsPerFrame ?? 1)
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: asbd?.mSampleRate ?? 48_000,
            AVNumberOfChannelsKey: min(channels, 2),
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = nil
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
    }

    func append(_ sample: CMSampleBuffer) {
        guard writer.status == .writing, input.isReadyForMoreMediaData else { return }
        let t = CMSampleBufferGetPresentationTimeStamp(sample)
        if lastTime.isValid, t <= lastTime { return }
        if let adaptor, let pixels = CMSampleBufferGetImageBuffer(sample) {
            if adaptor.append(pixels, withPresentationTime: t) { lastTime = t }
        } else if input.append(sample) {
            lastTime = t
        }
    }

    var error: String? { writer.status == .failed ? writer.error?.localizedDescription ?? "failed" : nil }

    func finish() async {
        guard writer.status == .writing else { return }
        input.markAsFinished()
        await writer.finishWriting()
    }
}

/// Carries a sample buffer to the writer queue (buffers are immutable once delivered).
struct SampleBox: @unchecked Sendable {
    let buffer: CMSampleBuffer
    init(_ buffer: CMSampleBuffer) { self.buffer = buffer }
}

extension CMSampleBuffer {
    /// A copy with every sample shifted so the first starts at `time`.
    func retimed(to time: CMTime) -> CMSampleBuffer? {
        let shift = time - CMSampleBufferGetPresentationTimeStamp(self)
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(self, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: max(count, 1))
        if count > 0 {
            CMSampleBufferGetSampleTimingInfoArray(self, entryCount: count, arrayToFill: &timing, entriesNeededOut: nil)
        } else {
            timing[0] = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(self),
                                           presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(self), decodeTimeStamp: .invalid)
        }
        for i in timing.indices {
            timing[i].presentationTimeStamp = timing[i].presentationTimeStamp + shift
            if timing[i].decodeTimeStamp.isValid { timing[i].decodeTimeStamp = timing[i].decodeTimeStamp + shift }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: self, sampleTimingEntryCount: timing.count,
                                              sampleTimingArray: &timing, sampleBufferOut: &out)
        return out
    }
}

enum AudioLevel {
    /// RMS of 16-bit or float PCM mapped to 0…1 (−50 dB … 0 dB).
    static func rms(_ buffer: CMSampleBuffer) -> Double {
        guard let block = CMSampleBufferGetDataBuffer(buffer),
              let format = CMSampleBufferGetFormatDescription(buffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return 0 }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let pointer else { return 0 }
        var sum = 0.0, count = 0
        if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { p in
                for i in 0..<(length / 4) { sum += Double(p[i] * p[i]) }
                count = length / 4
            }
        } else if asbd.mBitsPerChannel == 16 {
            pointer.withMemoryRebound(to: Int16.self, capacity: length / 2) { p in
                for i in 0..<(length / 2) { let v = Double(p[i]) / 32768; sum += v * v }
                count = length / 2
            }
        }
        guard count > 0 else { return 0 }
        let db = 20 * log10(max(sqrt(sum / Double(count)), 1e-6))
        return min(max((db + 50) / 50, 0), 1)
    }
}

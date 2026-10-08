@preconcurrency import AVFoundation
import CoreImage
import Foundation
import Metal
import SnazzyCore
@preconcurrency import Vision

/// "New layout": a finished recording laid out again from its raw tracks (screen,
/// camera, mic and timeline.json), with another inset position, size, crop,
/// background or lip-sync delay, or as a 4K picture. Saved as a new file next to
/// the original, which is never changed.
public enum Relayout {
    public enum Resolution: String, CaseIterable, Codable, Sendable {
        case hd1080 = "1080p"
        case uhd4K = "4K"

        public var canvas: CGSize { self == .uhd4K ? CGSize(width: 3840, height: 2160) : CGSize(width: 1920, height: 1080) }
    }

    public struct Options: Equatable, Sendable {
        public var layout: InsetLayout
        public var profile: DeviceProfile
        public var showCamera: Bool
        public var resolution: Resolution

        public init(layout: InsetLayout, profile: DeviceProfile, showCamera: Bool = true, resolution: Resolution = .hd1080) {
            self.layout = layout
            self.profile = profile
            self.showCamera = showCamera
            self.resolution = resolution
        }
    }

    /// A recording's raw tracks and what its timeline.json says.
    public struct Recording: Sendable {
        public let rawFolder: URL
        /// The settings it was recorded with: where a new layout starts from.
        public var original: Options
        /// Where the composite movie starts in raw-track time, and how long it is (seconds).
        public var start: Double
        public var duration: Double
        public var hasCamera: Bool
        /// How late camera frames reached the app after their capture time while
        /// recording (0 if unknown). camera.mov keeps capture times, so only the rest
        /// of the lip-sync delay is made up here.
        public var cameraLatency: Double
        var markers: [JSONValue]

        public init(rawFolder: URL) throws {
            guard let data = try? Data(contentsOf: rawFolder.appending(path: "timeline.json")), let t = try? JSONValue.parse(data) else {
                throw CaptureError("This recording has no timeline, so it can't be laid out again (it was made before raw tracks were kept).")
            }
            guard FileManager.default.fileExists(atPath: rawFolder.appending(path: "screen.mov").path) else {
                throw CaptureError("This recording's screen track is missing.")
            }
            self.rawFolder = rawFolder
            start = t["composite_starts_at_seconds"]?.doubleValue ?? 0
            duration = t["duration_seconds"]?.doubleValue ?? 0
            guard duration > 0 else { throw CaptureError("This recording's timeline has no length.") }
            hasCamera = FileManager.default.fileExists(atPath: rawFolder.appending(path: "camera.mov").path)
            cameraLatency = (t["camera_latency_ms"]?.doubleValue ?? 0) / 1000
            markers = t["markers"]?.arrayValue ?? []
            original = Options(layout: Self.layout(t["inset"]), profile: Self.profile(t["inset"]), showCamera: hasCamera)
        }

        static func layout(_ inset: JSONValue?) -> InsetLayout {
            var l = InsetLayout()
            if let c = inset?["corner"]?.stringValue.flatMap(InsetCorner.init(rawValue:)) { l.corner = c }
            if let v = inset?["size"]?.doubleValue { l.size = v }
            if let v = inset?["margin"]?.doubleValue { l.margin = v }
            if let v = inset?["border_width"]?.doubleValue { l.borderWidth = v }
            if let v = inset?["corner_radius"]?.doubleValue { l.cornerRadius = v }
            return l.normalized
        }

        static func profile(_ inset: JSONValue?) -> DeviceProfile {
            var p = DeviceProfile.defaults(for: .camera)
            if let r = inset?["rotation"]?.stringValue.flatMap(InsetRotation.init(rawValue:)) { p.rotation = r }
            if let aspect = inset?["aspect"] { p.crop.aspect = aspect.doubleValue }  // "fit" = the whole picture
            if let v = inset?["zoom"]?.doubleValue { p.crop.zoom = v }
            if let v = inset?["center_x"]?.doubleValue { p.crop.centerX = v }
            if let v = inset?["center_y"]?.doubleValue { p.crop.centerY = v }
            if let v = inset?["video_delay_ms"]?.doubleValue { p.videoDelayMs = v }
            if let b = inset?["background"], b != .null, let data = try? b.encoded(),
               let background = try? JSONDecoder().decode(CameraBackground.self, from: data) {
                p.background = background
            }
            p.crop = p.crop.normalized
            return p
        }

        /// Where to look in camera.mov for the picture that goes with sound at `time`.
        func cameraTime(_ time: Double, options: Options) -> Double {
            time + options.profile.videoDelayMs / 1000 - cameraLatency
        }
    }

    static let fps: Int32 = 30

    /// Renders the new layout to "<name> (new layout).mp4" next to `video` (with its
    /// captions and chapters). `progress` gets 0…1. Cancelling the task stops it and
    /// leaves no file behind.
    public static func render(_ recording: Recording, video: URL, options: Options, backgroundImage: CIImage? = nil,
                              progress: @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let output = RecordingEditor.sibling(of: video, suffix: options.resolution == .uhd4K ? "new layout 4K" : "new layout", ext: "mp4")
        // Written under a hidden name and moved into place only when complete.
        let partial = output.deletingLastPathComponent().appending(path: ".\(output.deletingPathExtension().lastPathComponent).partial.mp4")
        try? FileManager.default.removeItem(at: partial)
        do {
            try await write(recording, to: partial, options: options, backgroundImage: backgroundImage, progress: progress)
            try FileManager.default.moveItem(at: partial, to: output)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        // Same timing as the original's composite, so its captions still fit.
        for ext in ["srt", "vtt"] {
            let caption = video.deletingPathExtension().appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: caption.path) {
                try? FileManager.default.copyItem(at: caption, to: output.deletingPathExtension().appendingPathExtension(ext))
            }
        }
        if let vtt = Chapters.vtt(Chapters.marks(fromTimeline: recording.markers, start: recording.start), duration: recording.duration) {
            try? vtt.write(to: Chapters.url(forMovie: output), atomically: true, encoding: .utf8)
        }
        return output
    }

    static func write(_ recording: Recording, to url: URL, options: Options, backgroundImage: CIImage?,
                      progress: @Sendable (Double) -> Void) async throws {
        let canvas = options.resolution.canvas
        let audio = try? await AudioSource(recording.rawFolder.appending(path: "mic.mov"), start: recording.start, duration: recording.duration)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let hevc = options.resolution == .uhd4K
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: hevc ? 40_000_000 : 12_000_000,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: 2 * fps,
        ]
        if !hevc { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: Int(canvas.width), AVVideoHeightKey: Int(canvas.height),
            AVVideoCompressionPropertiesKey: compression,
        ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(canvas.width),
            kCVPixelBufferHeightKey as String: Int(canvas.height),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        writer.add(videoInput)
        var audioInput: AVAssetWriterInput?
        if let audio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audio.aacSettings)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }
        guard writer.startWriting() else {
            throw CaptureError("Can't write the new video: \(writer.error?.localizedDescription ?? "unknown error")")
        }
        writer.startSession(atSourceTime: .zero)
        // Sound goes in on its own queue whenever the writer asks for it, so the writer
        // can interleave as it likes (feeding it from the frame loop can deadlock).
        if let audio, let audioInput { audio.feed(audioInput) }
        do {
            try await writeFrames(recording, writer: writer, input: videoInput, adaptor: adaptor, options: options,
                                  backgroundImage: backgroundImage, progress: progress)
            videoInput.markAsFinished()
            while let audio, audioInput != nil, !audio.isDone, writer.status == .writing {
                try await Task.sleep(for: .milliseconds(5))
            }
        } catch {
            writer.cancelWriting()  // also stops the sound queue
            throw error
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw CaptureError("The new video couldn't be finished: \(writer.error?.localizedDescription ?? "unknown error")")
        }
        progress(1)
    }

    static func writeFrames(_ recording: Recording, writer: AVAssetWriter, input videoInput: AVAssetWriterInput,
                            adaptor: AVAssetWriterInputPixelBufferAdaptor, options: Options, backgroundImage: CIImage?,
                            progress: @Sendable (Double) -> Void) async throws {
        let raw = recording.rawFolder
        let canvas = options.resolution.canvas
        let screen = try await FrameSource(raw.appending(path: "screen.mov"))
        let camera = options.showCamera && recording.hasCamera ? try await FrameSource(raw.appending(path: "camera.mov")) : nil

        let context = MTLCreateSystemDefaultDevice().map { CIContext(mtlDevice: $0) } ?? CIContext()
        let spec = CompositeSpec(canvas: canvas, layout: options.layout, profile: options.profile)
        let segmenter = options.profile.background.isActive && options.showCamera ? PersonSegmenter() : nil
        let frames = max(1, Int((recording.duration * Double(fps)).rounded()))
        for i in 0..<frames {
            try Task.checkCancellation()
            let time = CMTime(value: CMTimeValue(i), timescale: fps)
            let t = recording.start + time.seconds
            let screenImage = screen.frame(at: t)?.image
            var cameraImage: CIImage?
            if let frame = camera?.frame(at: recording.cameraTime(t, options: options)) {
                cameraImage = segmenter?.apply(frame, background: options.profile.background, image: backgroundImage) ?? frame.image
            }
            let image = Compositor.compose(screen: screenImage, camera: cameraImage, spec: spec)
            while !videoInput.isReadyForMoreMediaData, writer.status == .writing {
                try await Task.sleep(for: .milliseconds(2))
            }
            guard writer.status == .writing, let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw CaptureError("Ran out of memory while making the new video.") }
            context.render(image, to: buffer, bounds: CGRect(origin: .zero, size: canvas), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            adaptor.append(buffer, withPresentationTime: time)
            if i % 15 == 0 { progress(Double(i) / Double(frames)) }
        }
    }

    /// One frame of a layout, `seconds` into the recording, for previews (960×540).
    public static func preview(_ recording: Recording, at seconds: Double, options: Options, backgroundImage: CIImage? = nil) async throws -> CGImage {
        let t = recording.start + min(max(seconds, 0), recording.duration)
        let screen = try? await still(recording.rawFolder.appending(path: "screen.mov"), at: t)
        var camera: CIImage?
        if options.showCamera, recording.hasCamera,
           let picture = try? await still(recording.rawFolder.appending(path: "camera.mov"), at: recording.cameraTime(t, options: options)) {
            camera = picture
            if options.profile.background.isActive,
               let mask = try? BackgroundEffect.personMask(quality: .balanced, size: picture.extent.size, perform: {
                   try VNImageRequestHandler(ciImage: picture).perform([$0])
               }) {
                camera = BackgroundRenderer.render(camera: picture, mask: mask, background: options.profile.background, image: backgroundImage)
            }
        }
        let canvas = CGSize(width: 960, height: 540)
        var spec = CompositeSpec(canvas: canvas, layout: options.layout, profile: options.profile)
        spec.canvas = canvas
        let image = Compositor.compose(screen: screen, camera: camera, spec: spec)
        guard let cg = CIContext().createCGImage(image, from: CGRect(origin: .zero, size: canvas)) else {
            throw CaptureError("Couldn't draw the preview.")
        }
        return cg
    }

    /// The picture of a raw track at `time`: the newest frame at or before it.
    static func still(_ url: URL, at time: Double) async throws -> CIImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 1)  // before its first frame: the first one
        let (image, _) = try await generator.image(at: CMTime(seconds: max(0, time), preferredTimescale: 600))
        return CIImage(cgImage: image)
    }
}

/// Decoded frames of a raw video track, read forward.
final class FrameSource {
    struct Frame {
        let time: Double
        let pixels: CVPixelBuffer
        var image: CIImage { CIImage(cvPixelBuffer: pixels) }
    }

    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var current: Frame?
    private var upcoming: Frame?

    init(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CaptureError("There's no picture in \(url.lastPathComponent).")
        }
        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw CaptureError("Can't read \(url.lastPathComponent): \(reader.error?.localizedDescription ?? "unknown error")")
        }
        upcoming = next()
    }

    private func next() -> Frame? {
        while let sample = output.copyNextSampleBuffer() {
            if let pixels = CMSampleBufferGetImageBuffer(sample) {
                return Frame(time: CMSampleBufferGetPresentationTimeStamp(sample).seconds, pixels: pixels)
            }
        }
        return nil
    }

    /// The newest frame at or before `time`. Frames are held, as in the recording (the
    /// screen only sends one when it changes). Just before the first frame, that one.
    func frame(at time: Double) -> Frame? {
        while let u = upcoming, u.time <= time {
            current = u
            upcoming = next()
        }
        return current ?? upcoming.flatMap { $0.time - time < 1 ? $0 : nil }
    }
}

/// The mic track, cut to the composite's time range and retimed to start at zero.
/// `append` runs on one queue (the writer's request queue); `isDone` from anywhere.
final class AudioSource: @unchecked Sendable {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let start: CMTime
    private let lock = NSLock()
    private var done = false
    var isDone: Bool { lock.withLock { done } }
    let aacSettings: [String: Any]

    init(_ url: URL, start: Double, duration: Double) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw CaptureError("No sound in \(url.lastPathComponent).") }
        let format = try await track.load(.formatDescriptions).first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let channels = min(Int(format?.mChannelsPerFrame ?? 1), 2)
        let rate = format?.mSampleRate ?? 48_000
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        aacSettings = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: channels, AVSampleRateKey: rate,
            AVEncoderBitRateKey: channels == 1 ? 160_000 : 256_000,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
        ]
        reader = try AVAssetReader(asset: asset)
        self.start = CMTime(seconds: start, preferredTimescale: CMTimeScale(rate))
        reader.timeRange = CMTimeRange(start: self.start, duration: CMTime(seconds: duration, preferredTimescale: CMTimeScale(rate)))
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw CaptureError("Can't read the sound: \(reader.error?.localizedDescription ?? "unknown error")") }
    }

    private var input: AVAssetWriterInput?
    private let queue = DispatchQueue(label: "com.snazzy.pro.relayout-audio")

    /// Feeds `input` on its own queue whenever the writer asks, until the sound runs out.
    func feed(_ input: AVAssetWriterInput) {
        self.input = input
        input.requestMediaDataWhenReady(on: queue) { [self] in appendAvailable() }
    }

    /// Appends as much sound as the input takes now; marks it finished at the end.
    private func appendAvailable() {
        guard let input else { return }
        while !isDone, input.isReadyForMoreMediaData {
            guard let sample = output.copyNextSampleBuffer() else {
                lock.withLock { done = true }
                input.markAsFinished()
                return
            }
            if let retimed = sample.retimed(to: CMSampleBufferGetPresentationTimeStamp(sample) - start) { input.append(retimed) }
        }
    }
}

/// Person masks for recorded camera frames: every frame gets its own (live
/// capture skips frames while busy; here there's time).
final class PersonSegmenter {
    private let handler = VNSequenceRequestHandler()
    private var last: (time: Double, image: CIImage)?

    func apply(_ frame: FrameSource.Frame, background: CameraBackground, image: CIImage?) -> CIImage {
        if let last, last.time == frame.time { return last.image }
        let size = CGSize(width: CVPixelBufferGetWidth(frame.pixels), height: CVPixelBufferGetHeight(frame.pixels))
        var result = frame.image
        if let mask = try? BackgroundEffect.personMask(quality: .balanced, size: size, perform: { try handler.perform([$0], on: frame.pixels) }) {
            result = BackgroundRenderer.render(camera: frame.image, mask: mask, background: background, image: image)
        }
        last = (frame.time, result)
        return result
    }
}

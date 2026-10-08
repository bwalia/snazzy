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
        /// 9:16 for Shorts, Reels, TikTok: the screen on top, the camera below.
        case vertical = "Vertical"

        public var canvas: CGSize {
            switch self {
            case .hd1080: CGSize(width: 1920, height: 1080)
            case .uhd4K: CGSize(width: 3840, height: 2160)
            case .vertical: CGSize(width: 1080, height: 1920)
            }
        }

        var arrangement: CompositeSpec.Arrangement { self == .vertical ? .stacked : .inset }
    }

    public struct Options: Equatable, Sendable {
        public var layout: InsetLayout
        public var profile: DeviceProfile
        public var showCamera: Bool
        public var resolution: Resolution
        /// Only this part of the recording (seconds from its start); nil = all of it.
        public var range: ClosedRange<Double>?
        /// The camera grows to this size on title slides (needs a recording that noted them).
        public var titleSlideInsetSize: Double?

        public init(layout: InsetLayout, profile: DeviceProfile, showCamera: Bool = true, resolution: Resolution = .hd1080,
                    range: ClosedRange<Double>? = nil, titleSlideInsetSize: Double? = nil) {
            self.layout = layout
            self.profile = profile
            self.showCamera = showCamera
            self.resolution = resolution
            self.range = range
            self.titleSlideInsetSize = titleSlideInsetSize
        }

        /// "new layout", "clip 4K", "vertical clip"…: what the new file is called after.
        var suffix: String {
            switch (resolution, range != nil) {
            case (.vertical, true): "vertical clip"
            case (.vertical, false): "vertical"
            case (_, true): resolution == .uhd4K ? "clip 4K" : "clip"
            case (_, false): resolution == .uhd4K ? "new layout 4K" : "new layout"
            }
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
        /// Slide changes noted with whether each was a title slide (raw-track time).
        var titleSlides: [TitleSlides.Change]
        /// Whether "bigger camera on title slides" can be used: it has title slides on record.
        public var hasTitleSlides: Bool { titleSlides.contains(where: \.isTitle) }

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
            titleSlides = TitleSlides.changes(fromTimeline: markers)
            original = Options(layout: Self.layout(t["inset"]), profile: Self.profile(t["inset"]), showCamera: hasCamera,
                               titleSlideInsetSize: t["inset"]?["title_slide_size"]?.doubleValue)
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

        /// The part to make, in seconds from the recording's start, and its length.
        public func part(_ options: Options) throws -> (start: Double, length: Double) {
            guard let range = options.range else { return (0, duration) }
            let start = max(0, range.lowerBound), end = min(range.upperBound, duration)
            guard end - start >= 1 else { throw CaptureError("A clip has to be at least a second long.") }
            return (start, end - start)
        }

        /// The spec for the moment `time` (raw-track time): the camera bigger on title slides.
        func spec(_ base: CompositeSpec, at time: Double, options: Options) -> CompositeSpec {
            guard let title = options.titleSlideInsetSize, base.arrangement == .inset, !titleSlides.isEmpty else { return base }
            var spec = base
            spec.insetSize = TitleSlides.insetSize(at: time, changes: titleSlides, normal: options.layout.normalized.size, title: title)
            return spec
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
        let part = try recording.part(options)
        let output = RecordingEditor.sibling(of: video, suffix: options.suffix, ext: "mp4")
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
        // The original's captions, cut and retimed to the part that was made.
        if let srt = try? String(contentsOf: video.deletingPathExtension().appendingPathExtension("srt"), encoding: .utf8) {
            let cues = Captions.clip(Captions.parseSRT(srt), from: part.start, length: part.length)
            if !cues.isEmpty {
                try? Captions.srt(cues).write(to: output.deletingPathExtension().appendingPathExtension("srt"), atomically: true, encoding: .utf8)
                try? Captions.vtt(cues).write(to: output.deletingPathExtension().appendingPathExtension("vtt"), atomically: true, encoding: .utf8)
            }
        }
        let marks = Chapters.marks(fromTimeline: recording.markers, start: recording.start + part.start)
        if let vtt = Chapters.vtt(marks, duration: part.length) {
            try? vtt.write(to: Chapters.url(forMovie: output), atomically: true, encoding: .utf8)
        }
        return output
    }

    static func write(_ recording: Recording, to url: URL, options: Options, backgroundImage: CIImage?,
                      progress: @Sendable (Double) -> Void) async throws {
        let canvas = options.resolution.canvas
        let part = try recording.part(options)
        let audio = try? await AudioSource(recording.rawFolder.appending(path: "mic.mov"), start: recording.start + part.start, duration: part.length)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let hevc = options.resolution == .uhd4K
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: hevc ? 40_000_000 : options.resolution == .vertical ? 10_000_000 : 12_000_000,
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
        var spec = CompositeSpec(canvas: canvas, layout: options.layout, profile: options.profile)
        spec.arrangement = options.resolution.arrangement
        let part = try recording.part(options)
        let segmenter = options.profile.background.isActive && options.showCamera ? PersonSegmenter() : nil
        let frames = max(1, Int((part.length * Double(fps)).rounded()))
        for i in 0..<frames {
            try Task.checkCancellation()
            let time = CMTime(value: CMTimeValue(i), timescale: fps)
            let t = recording.start + part.start + time.seconds
            let screenImage = screen.frame(at: t)?.image
            var cameraImage: CIImage?
            if let frame = camera?.frame(at: recording.cameraTime(t, options: options)) {
                cameraImage = segmenter?.apply(frame, background: options.profile.background, image: backgroundImage) ?? frame.image
            }
            let image = Compositor.compose(screen: screenImage, camera: cameraImage, spec: recording.spec(spec, at: t, options: options))
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

    /// One frame of a layout, `seconds` into the recording, for previews (960×540, or 540×960 vertical).
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
        let canvas = options.resolution == .vertical ? CGSize(width: 540, height: 960) : CGSize(width: 960, height: 540)
        var spec = CompositeSpec(canvas: canvas, layout: options.layout, profile: options.profile)
        spec.arrangement = options.resolution.arrangement
        let image = Compositor.compose(screen: screen, camera: camera, spec: recording.spec(spec, at: t, options: options))
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

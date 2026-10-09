@preconcurrency import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import CaptureEngine
@testable import SnazzyCore

/// A movie of one solid colour.
func solidMovie(_ url: URL, color: CIColor, seconds: Double, size: CGSize) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
    ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    let context = CIContext()
    for i in 0..<Int(seconds * 30) {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        context.render(CIImage(color: color).cropped(to: CGRect(origin: .zero, size: size)), to: buffer!)
        adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
    }
    input.markAsFinished()
    await writer.finishWriting()
}

/// A movie of a 440 Hz tone (16-bit PCM, like the recorder's mic track).
func toneMovie(_ url: URL, seconds: Double) async throws {
    let rate = 48_000.0
    var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                           mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                           mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
                                           mBitsPerChannel: 16, mReserved: 0)
    var format: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                   extensions: nil, formatDescriptionOut: &format)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    let chunk = 4_800
    for k in 0..<Int(seconds * rate) / chunk {
        let samples = (0..<chunk).map { Int16(sin(Double(k * chunk + $0) * 2 * .pi * 440 / rate) * 8_000) }
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: chunk * 2, blockAllocator: nil, customBlockSource: nil,
                                           offsetToData: 0, dataLength: chunk * 2, flags: 0, blockBufferOut: &block)
        samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: chunk * 2) }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: chunk,
                                                             presentationTimeStamp: CMTime(value: CMTimeValue(k * chunk), timescale: CMTimeScale(rate)),
                                                             packetDescriptions: nil, sampleBufferOut: &sample)
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
        input.append(sample!)
    }
    input.markAsFinished()
    await writer.finishWriting()
}

/// RGBA of a pixel, `x` and `y` as fractions from the top left.
func pixel(_ image: CGImage, x: Double, y: Double) -> (r: Int, g: Int, b: Int) {
    let w = image.width, h = image.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    let context = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let o = (Int(y * Double(h)) * w + Int(x * Double(w))) * 4
    return (Int(data[o]), Int(data[o + 1]), Int(data[o + 2]))
}

@Suite(.serialized) struct RelayoutTests {
    /// A recording's folder: a red screen, a blue camera, a tone, and a timeline whose
    /// composite starts 0.5 s into the raw tracks and lasts 3.5 s.
    func recording() async throws -> (video: URL, raw: URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "relayout-\(UUID().uuidString)", directoryHint: .isDirectory)
        let raw = dir.appending(path: "presentation-1 raw", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        try await solidMovie(raw.appending(path: "screen.mov"), color: CIColor(red: 1, green: 0, blue: 0), seconds: 4.5, size: CGSize(width: 320, height: 180))
        try await solidMovie(raw.appending(path: "camera.mov"), color: CIColor(red: 0, green: 0, blue: 1), seconds: 4.5, size: CGSize(width: 160, height: 90))
        try await toneMovie(raw.appending(path: "mic.mov"), seconds: 4.5)
        let timeline: JSONValue = [
            "composite_starts_at_seconds": 0.5, "duration_seconds": 3.5, "camera_latency_ms": 40,
            "inset": ["corner": "bottomRight", "size": 0.4, "border_width": 0, "corner_radius": 0, "aspect": "fit",
                      "rotation": "none", "zoom": 1, "center_x": 0.5, "center_y": 0.5, "video_delay_ms": 200],
            "markers": [["type": "slide", "index": 0, "title": "Intro", "at_seconds": 0.5],
                        ["type": "slide", "index": 1, "title": "Results", "at_seconds": 2.2]],
        ]
        try timeline.encoded().write(to: raw.appending(path: "timeline.json"))
        let video = dir.appending(path: "presentation-1.mov")
        try Data("original".utf8).write(to: video)
        try "1\n00:00:00,000 --> 00:00:01,000\nHello\n\n2\n00:00:01,200 --> 00:00:02,000\nWorld\n".write(
            to: video.deletingPathExtension().appendingPathExtension("srt"), atomically: true, encoding: .utf8)
        return (video, raw)
    }

    @Test func readsTheOriginalSettings() async throws {
        let (video, raw) = try await recording()
        defer { try? FileManager.default.removeItem(at: video.deletingLastPathComponent()) }
        let rec = try Relayout.Recording(rawFolder: raw)
        #expect(rec.start == 0.5 && rec.duration == 3.5 && rec.hasCamera)
        #expect(rec.original.layout.corner == .bottomRight && rec.original.layout.size == 0.4)
        #expect(rec.original.profile.crop.aspect == nil && rec.original.profile.videoDelayMs == 200)
        // Lip sync: 200 ms behind the sound, 40 of it already in camera.mov's own times.
        #expect(abs(rec.cameraTime(1, options: rec.original) - 1.16) < 1e-9)
    }

    @Test func rendersANewLayoutFromTheRawTracks() async throws {
        let (video, raw) = try await recording()
        let dir = video.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rec = try Relayout.Recording(rawFolder: raw)
        var options = rec.original
        options.layout.corner = .topLeft
        let output = try await Relayout.render(rec, video: video, options: options)

        #expect(output.lastPathComponent == "presentation-1 (new layout).mp4")
        let asset = AVURLAsset(url: output)
        #expect(abs(try await asset.load(.duration).seconds - 3.5) < 0.15)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        let size = try await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize)
        #expect(size == CGSize(width: 1920, height: 1080))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (frame, _) = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600))
        let camera = pixel(frame, x: 0.1, y: 0.15), screen = pixel(frame, x: 0.9, y: 0.85)
        #expect(camera.b > 150 && camera.r < 90, "camera now top left: \(camera)")
        #expect(screen.r > 150 && screen.b < 90, "screen where the camera was: \(screen)")

        // Captions and chapters come along; nothing half-written is left; the original is untouched.
        #expect(FileManager.default.fileExists(atPath: output.deletingPathExtension().appendingPathExtension("srt").path))
        let chapters = try String(contentsOf: Chapters.url(forMovie: output), encoding: .utf8)
        #expect(chapters.contains("Intro") && chapters.contains("Results"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).allSatisfy { !$0.contains("partial") })
        #expect(try String(contentsOf: video, encoding: .utf8) == "original")
    }

    /// A 1.5 s vertical clip: screen on top, camera below, its own captions.
    @Test func makesAVerticalClip() async throws {
        let (video, raw) = try await recording()
        defer { try? FileManager.default.removeItem(at: video.deletingLastPathComponent()) }
        let rec = try Relayout.Recording(rawFolder: raw)
        var options = rec.original
        options.resolution = .vertical
        options.range = 1.0...2.5
        let output = try await Relayout.render(rec, video: video, options: options)
        #expect(output.lastPathComponent == "presentation-1 (vertical clip).mp4")
        let asset = AVURLAsset(url: output)
        #expect(abs(try await asset.load(.duration).seconds - 1.5) < 0.15)
        #expect(try await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize) == CGSize(width: 1080, height: 1920))
        let generator = AVAssetImageGenerator(asset: asset)
        let (frame, _) = try await generator.image(at: CMTime(seconds: 0.7, preferredTimescale: 600))
        #expect(pixel(frame, x: 0.5, y: 0.1).r > 150 && pixel(frame, x: 0.5, y: 0.8).b > 150)
        // Only the caption inside the clip, from its start: 1.2–2.0 s → 0.2–1.0 s.
        let srt = try String(contentsOf: output.deletingPathExtension().appendingPathExtension("srt"), encoding: .utf8)
        #expect(Captions.parseSRT(srt) == [CaptionCue(start: 0.2, end: 1.0, text: "World")])
        // Too short to be a clip.
        options.range = 1.0...1.5
        await #expect(throws: CaptureError.self) { try await Relayout.render(rec, video: video, options: options) }
    }

    /// A recording that noted its title slides: the camera bigger on them, as it was live.
    @Test func biggerCameraOnTitleSlides() async throws {
        let (video, raw) = try await recording()
        defer { try? FileManager.default.removeItem(at: video.deletingLastPathComponent()) }
        let timelineURL = raw.appending(path: "timeline.json")
        var t = try #require(try JSONValue.parse(Data(contentsOf: timelineURL)).objectValue)
        t["markers"] = [["type": "slide", "index": 0, "title": "Intro", "title_slide": true, "at_seconds": 0.5],
                        ["type": "slide", "index": 1, "title": "Results", "title_slide": false, "at_seconds": 2.2]]
        var inset = try #require(t["inset"]?.objectValue)
        inset["title_slide_size"] = 0.6
        t["inset"] = .object(inset)
        try JSONValue.object(t).encoded().write(to: timelineURL)

        let rec = try Relayout.Recording(rawFolder: raw)
        #expect(rec.hasTitleSlides && rec.original.titleSlideInsetSize == 0.6)
        // (0.5, 0.5) is inside the big inset (0.6 of the height) but not the normal one (0.4).
        #expect(pixel(try await Relayout.preview(rec, at: 0.5, options: rec.original), x: 0.5, y: 0.5).b > 150)  // title slide
        #expect(pixel(try await Relayout.preview(rec, at: 2.5, options: rec.original), x: 0.5, y: 0.5).r > 150)  // content slide
        var off = rec.original
        off.titleSlideInsetSize = nil
        #expect(pixel(try await Relayout.preview(rec, at: 0.5, options: off), x: 0.5, y: 0.5).r > 150)
    }

    @Test func previewShowsTheLayoutAndCanHideTheCamera() async throws {
        let (video, raw) = try await recording()
        defer { try? FileManager.default.removeItem(at: video.deletingLastPathComponent()) }
        let rec = try Relayout.Recording(rawFolder: raw)
        let image = try await Relayout.preview(rec, at: 1, options: rec.original)
        #expect(image.width == 960 && image.height == 540)
        #expect(pixel(image, x: 0.9, y: 0.85).b > 150)  // camera bottom right
        var hidden = rec.original
        hidden.showCamera = false
        #expect(pixel(try await Relayout.preview(rec, at: 1, options: hidden), x: 0.9, y: 0.85).r > 150)
    }

    @Test func cancellingLeavesNothingBehind() async throws {
        let (video, raw) = try await recording()
        let dir = video.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rec = try Relayout.Recording(rawFolder: raw)
        let task = Task { try await Relayout.render(rec, video: video, options: rec.original) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).allSatisfy { !$0.contains("new layout") && !$0.contains("partial") })
    }

    @Test func refusesARecordingWithoutRawTracks() {
        #expect(throws: CaptureError.self) { try Relayout.Recording(rawFolder: FileManager.default.temporaryDirectory.appending(path: "nope")) }
    }
}

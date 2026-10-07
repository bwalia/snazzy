@preconcurrency import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import CaptureEngine
@testable import SnazzyCore

/// Writes a small H.264 movie of solid frames.
func makeMovie(_ url: URL, seconds: Double, fps: Int32 = 30, fileType: AVFileType = .mov) async throws {
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90,
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 90,
    ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    let ctx = CIContext()
    for i in 0..<Int(seconds * Double(fps)) {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        ctx.render(CIImage(color: CIColor(red: Double(i % 30) / 30, green: 0.3, blue: 0.6)).cropped(to: CGRect(x: 0, y: 0, width: 160, height: 90)), to: pb!)
        adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
    }
    input.markAsFinished()
    await writer.finishWriting()
}

@Suite(.serialized) struct RecordingEditorTests {
    @Test func rangeResolution() throws {
        #expect(try RecordingEditor.resolveRange(start: 5, end: 20, duration: 30) == (5, 20))
        #expect(try RecordingEditor.resolveRange(start: 0, end: -3, duration: 30) == (0, 27))
        #expect(try RecordingEditor.resolveRange(start: -2, end: 99, duration: 30) == (0, 30))
        #expect(throws: CaptureError.self) { try RecordingEditor.resolveRange(start: 10, end: 10.2, duration: 30) }
    }

    @Test func siblingNames() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let v = dir.appending(path: "presentation-1.mov")
        let a = RecordingEditor.sibling(of: v, suffix: "trimmed", ext: "mp4")
        #expect(a.lastPathComponent == "presentation-1 (trimmed).mp4")
        FileManager.default.createFile(atPath: a.path, contents: Data())
        #expect(RecordingEditor.sibling(of: v, suffix: "trimmed", ext: "mp4").lastPathComponent == "presentation-1 (trimmed 2).mp4")
        #expect(RecordingEditor.sibling(of: a, suffix: "trimmed", ext: "mp4").lastPathComponent == "presentation-1 (trimmed 2).mp4")
    }

    @Test func trimsVideoAndRawTracksWithoutTouchingTheOriginal() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "trim-\(UUID().uuidString)")
        let raw = dir.appending(path: "presentation-1 raw")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = dir.appending(path: "presentation-1.mov")
        try await makeMovie(video, seconds: 3)
        try await makeMovie(raw.appending(path: "screen.mov"), seconds: 3.2)
        let timeline: JSONValue = ["composite_starts_at_seconds": 0.2, "duration_seconds": 3,
                                   "camera_freezes": [["at_seconds": 1.5, "duration_seconds": 0.4], ["at_seconds": 0.1, "duration_seconds": 0.1]]]
        try timeline.encoded().write(to: raw.appending(path: "timeline.json"))
        let originalSize = try FileManager.default.attributesOfItem(atPath: video.path)[.size] as? Int

        let result = try await RecordingEditor.trim(video, start: 0.5, end: 2.0)
        #expect(result.video.lastPathComponent == "presentation-1 (trimmed).mp4")
        let d = try await AVURLAsset(url: result.video).load(.duration).seconds
        #expect(abs(d - 1.5) < 0.1)
        let rawD = try await AVURLAsset(url: try #require(result.rawFolder).appending(path: "screen.mov")).load(.duration).seconds
        #expect(abs(rawD - 1.5) < 0.1)
        let t = try JSONValue.parse(Data(contentsOf: result.rawFolder!.appending(path: "timeline.json")))
        #expect(t["camera_freezes"]?.arrayValue?.count == 1)
        #expect(t["camera_freezes"]?.arrayValue?.first?["at_seconds"]?.doubleValue == 1.0)
        #expect(t["duration_seconds"]?.doubleValue == 1.5)
        #expect(try FileManager.default.attributesOfItem(atPath: video.path)[.size] as? Int == originalSize)
    }
}

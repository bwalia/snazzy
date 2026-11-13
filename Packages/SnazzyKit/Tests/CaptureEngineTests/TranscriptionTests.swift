@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import CaptureEngine

@Suite struct TranscriptionTests {
    @Test func preparedAudioKeepsAReadableSoundFile() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "snazzy-tone-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeSilentAudio(url, seconds: 0.25)
        let prepared = try await RecordingTranscriber.preparedAudio(url)
        #expect(prepared.url == url)
        #expect(prepared.deleteWhenDone == false)
    }

    @Test func extractAudioFromSoundFileWritesM4A() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "snazzy-tone-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeSilentAudio(url, seconds: 0.4)
        let m4a = try await RecordingTranscriber.extractAudio(url)
        defer { try? FileManager.default.removeItem(at: m4a) }
        #expect(m4a.pathExtension == "m4a")
        #expect(FileManager.default.fileExists(atPath: m4a.path))
        let asset = AVURLAsset(url: m4a)
        #expect(try await !asset.loadTracks(withMediaType: .audio).isEmpty)
    }

    @Test func siblingTranscriptNamesStayBesideTheOriginal() {
        let src = URL(fileURLWithPath: "/tmp/talk.m4a")
        let txt = RecordingEditor.sibling(of: src, suffix: "transcript", ext: "txt")
        #expect(txt.lastPathComponent == "talk (transcript).txt")
        #expect(txt.deletingLastPathComponent().path == "/tmp")
    }
}

private func writeSilentAudio(_ url: URL, seconds: Double) throws {
    try? FileManager.default.removeItem(at: url)
    guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1) else {
        throw CaptureError("Couldn't make an audio format for the test.")
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let frames = AVAudioFrameCount(16_000 * seconds)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
        throw CaptureError("Couldn't make an audio buffer for the test.")
    }
    buffer.frameLength = frames
    try file.write(from: buffer)
}

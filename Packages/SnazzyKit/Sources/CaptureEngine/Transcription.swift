@preconcurrency import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit
import Foundation
import SnazzyCore
@preconcurrency import Speech

/// On-device transcription of a recording's audio, with word timings.
public enum RecordingTranscriber {
    /// Transcribes the audio track of a movie. Audio never leaves the Mac.
    public static func words(in movie: URL, locale: Locale = .current) async throws -> [TimedWord] {
        let audio = try await extractAudio(movie)
        defer { try? FileManager.default.removeItem(at: audio) }
        if #available(macOS 26.0, *) {
            return try await analyzerWords(audio, locale: locale)
        }
        return try await legacyWords(audio, locale: locale)
    }

    /// Audio track → temporary .m4a (SpeechAnalyzer reads audio files).
    static func extractAudio(_ movie: URL) async throws -> URL {
        let asset = AVURLAsset(url: movie)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
            throw CaptureError("This recording has no sound to transcribe.")
        }
        let out = FileManager.default.temporaryDirectory.appending(path: "snazzy-audio-\(UUID().uuidString).m4a")
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw CaptureError("Can't read this recording's audio.")
        }
        try await session.export(to: out, as: .m4a)
        return out
    }

    @available(macOS 26.0, *)
    static func analyzerWords(_ audio: URL, locale: Locale) async throws -> [TimedWord] {
        var match = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        if match == nil { match = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) }
        guard let supported = match else {
            throw CaptureError("On-device transcription isn't available for \(locale.identifier).")
        }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        // The speech model is a system download from Apple the first time.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () -> [TimedWord] in
            var words: [TimedWord] = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let piece = String(result.text[run.range].characters)
                    // A run can hold several words; spread its time across them.
                    let parts = piece.split(whereSeparator: \.isWhitespace).map(String.init)
                    guard !parts.isEmpty else { continue }
                    let step = range.duration.seconds / Double(parts.count)
                    for (i, p) in parts.enumerated() {
                        let s = range.start.seconds + step * Double(i)
                        words.append(TimedWord(p, s, s + step))
                    }
                }
            }
            return words
        }
        let file = try AVAudioFile(forReading: audio)
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        return try await collector.value
    }

    /// macOS 15: the classic recognizer, forced on-device.
    static func legacyWords(_ audio: URL, locale: Locale) async throws -> [TimedWord] {
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.supportsOnDeviceRecognition else {
            throw CaptureError("On-device transcription isn't available on this Mac.")
        }
        let request = SFSpeechURLRecognitionRequest(url: audio)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        return try await withCheckedThrowingContinuation { continuation in
            var done = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !done else { return }
                if let error {
                    done = true
                    continuation.resume(throwing: error)
                } else if let result, result.isFinal {
                    done = true
                    continuation.resume(returning: result.bestTranscription.segments.map {
                        TimedWord($0.substring, $0.timestamp, $0.timestamp + $0.duration)
                    })
                }
            }
        }
    }
}

/// Writes a copy of a video with captions drawn into the picture (re-encoded).
public enum CaptionBurner {
    public static func burn(_ video: URL, cues: [CaptionCue], to output: URL) async throws {
        let asset = AVURLAsset(url: video)
        let renderer = CueRenderer(cues: cues)
        let composition = try await AVVideoComposition.videoComposition(with: asset) { request in
            let source = request.sourceImage.clampedToExtent()
            let extent = request.sourceImage.extent
            var image = source
            if let overlay = renderer.overlay(at: request.compositionTime.seconds, in: extent) {
                image = overlay.composited(over: source)
            }
            request.finish(with: image.cropped(to: extent), context: nil)
        }
        try? FileManager.default.removeItem(at: output)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw CaptureError("This recording can't be exported.")
        }
        session.videoComposition = composition
        try await session.export(to: output, as: .mp4)
    }
}

/// Draws a caption cue as white text on a dark rounded box, bottom centre.
final class CueRenderer: @unchecked Sendable {
    let cues: [CaptionCue]
    private var cache: [Int: CIImage] = [:]
    private let lock = NSLock()

    init(cues: [CaptionCue]) { self.cues = cues }

    func overlay(at time: Double, in extent: CGRect) -> CIImage? {
        guard let index = cues.firstIndex(where: { time >= $0.start && time < $0.end }) else { return nil }
        let image = lock.withLock { () -> CIImage? in
            if let c = cache[index] { return c }
            let made = Self.render(cues[index].text, height: extent.height)
            cache[index] = made
            return made
        }
        guard let image else { return nil }
        let x = extent.midX - image.extent.width / 2
        let y = extent.minY + extent.height * 0.06
        return image.transformed(by: CGAffineTransform(translationX: x - image.extent.minX, y: y - image.extent.minY))
    }

    static func render(_ text: String, height: CGFloat) -> CIImage? {
        let size = max(18, height * 0.042)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ])
        let generator = CIFilter.attributedTextImageGenerator()
        generator.text = attributed
        generator.scaleFactor = 1
        guard let textImage = generator.outputImage else { return nil }
        let pad = size * 0.45
        let box = textImage.extent.insetBy(dx: -pad * 1.4, dy: -pad)
        let background = CIFilter.roundedRectangleGenerator()
        background.extent = box
        background.radius = Float(size * 0.35)
        background.color = CIColor(red: 0.04, green: 0.06, blue: 0.13)
        guard let bg = background.outputImage else { return textImage }
        // The generator ignores colour alpha, so fade the box explicitly (premultiplied).
        let faded = bg.cropped(to: box).applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.85, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0.85, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.85, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.85),
        ])
        return textImage.composited(over: faded)
    }
}

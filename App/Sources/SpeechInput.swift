@preconcurrency import AVFoundation
import Foundation
import Observation
import SnazzyCore
@preconcurrency import Speech

/// Push-to-talk: records the chosen mic, transcribes on-device with the Speech
/// framework, and keeps the audio (for the session log).
@MainActor @Observable
final class SpeechInput {
    enum State: Equatable {
        case idle
        case listening
        case finishing
        case failed(String)
    }

    struct Result {
        var text: String
        var audioURL: URL?
        var duration: TimeInterval
    }

    private(set) var state: State = .idle
    private(set) var partial = ""
    /// 0…1 input level for the meter.
    private(set) var level: Double = 0
    private(set) var onDevice = false

    @ObservationIgnored private var session: AVCaptureSession?
    @ObservationIgnored private var tap: AudioTap?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var finalText: String?
    @ObservationIgnored private var started = Date()
    @ObservationIgnored private var audioURL: URL?

    var isListening: Bool { state == .listening }

    /// Starts listening on the given mic (or the system default).
    func start(micID: String?, saveAudioTo directory: URL?) async {
        guard state != .listening else { return }
        partial = ""
        finalText = nil
        guard await Self.authorize() else {
            state = .failed("Allow Microphone and Speech Recognition for Snazzy Pro in System Settings → Privacy & Security.")
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            state = .failed("Speech recognition isn't available for \(Locale.current.identifier).")
            return
        }
        guard let mic = micID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .audio) else {
            state = .failed("No microphone found.")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        onDevice = recognizer.supportsOnDeviceRecognition
        if onDevice { request.requiresOnDeviceRecognition = true }

        var fileURL: URL?
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = "voice-\(Self.stamp.string(from: Date())).m4a"
            fileURL = directory.appending(path: name)
        }
        let tap = AudioTap(request: request, fileURL: fileURL) { [weak self] level in
            Task { @MainActor in self?.level = level }
        }

        let session = AVCaptureSession()
        do {
            session.beginConfiguration()
            let input = try AVCaptureDeviceInput(device: mic)
            guard session.canAddInput(input) else { throw CaptureActionError(message: "Can't use \(mic.localizedName)") }
            session.addInput(input)
            let output = AVCaptureAudioDataOutput()
            output.setSampleBufferDelegate(tap, queue: tap.queue)
            guard session.canAddOutput(output) else { throw CaptureActionError(message: "Can't read audio from \(mic.localizedName)") }
            session.addOutput(output)
            session.commitConfiguration()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil && result == nil
            Task { @MainActor in
                guard let self else { return }
                if let text { self.partial = text }
                if isFinal || failed { self.finalText = text ?? self.partial }
            }
        }
        self.request = request
        self.tap = tap
        self.session = session
        self.audioURL = fileURL
        started = Date()
        state = .listening
        await Task.detached { session.startRunning() }.value
    }

    /// Stops listening and returns the transcript (waits briefly for the final result).
    func stop() async -> Result? {
        guard state == .listening, let session else { return nil }
        state = .finishing
        await Task.detached { session.stopRunning() }.value
        request?.endAudio()
        await tap?.finish()
        for _ in 0..<30 where finalText == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        task?.cancel()
        let text = (finalText ?? partial).trimmingCharacters(in: .whitespacesAndNewlines)
        let result = Result(text: text, audioURL: tap?.wroteAudio == true ? audioURL : nil,
                            duration: Date().timeIntervalSince(started))
        self.session = nil
        self.tap = nil
        self.request = nil
        self.task = nil
        level = 0
        state = .idle
        return result
    }

    func cancel() async {
        _ = await stop()
        partial = ""
    }

    static func authorize() async -> Bool {
        let speech: Bool = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}

/// Receives mic sample buffers: feeds the recognizer, measures level, and
/// writes AAC audio.
final class AudioTap: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.snazzy.pro.voice")
    private let request: SFSpeechAudioBufferRecognitionRequest
    private let fileURL: URL?
    private let onLevel: @Sendable (Double) -> Void
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var lastLevel = Date.distantPast
    private(set) var wroteAudio = false

    init(request: SFSpeechAudioBufferRecognitionRequest, fileURL: URL?, onLevel: @escaping @Sendable (Double) -> Void) {
        self.request = request
        self.fileURL = fileURL
        self.onLevel = onLevel
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        request.appendAudioSampleBuffer(sampleBuffer)
        write(sampleBuffer)
        if Date().timeIntervalSince(lastLevel) > 0.05 {
            lastLevel = Date()
            onLevel(Self.level(sampleBuffer))
        }
    }

    private func write(_ buffer: CMSampleBuffer) {
        guard let fileURL else { return }
        if writer == nil {
            guard let w = try? AVAssetWriter(outputURL: fileURL, fileType: .m4a) else { return }
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 1,
                                           AVSampleRateKey: 48_000, AVEncoderBitRateKey: 96_000]
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            i.expectsMediaDataInRealTime = true
            guard w.canAdd(i) else { return }
            w.add(i)
            w.startWriting()
            w.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(buffer))
            writer = w
            input = i
        }
        if let input, input.isReadyForMoreMediaData, input.append(buffer) { wroteAudio = true }
    }

    func finish() async {
        let (writer, input): (AVAssetWriter?, AVAssetWriterInput?) = queue.sync { (self.writer, self.input) }
        guard let writer, writer.status == .writing else { return }
        input?.markAsFinished()
        await writer.finishWriting()
    }

    /// RMS level of 16-bit or float PCM, mapped to 0…1 (−50 dB … 0 dB).
    static func level(_ buffer: CMSampleBuffer) -> Double {
        guard let block = CMSampleBufferGetDataBuffer(buffer),
              let format = CMSampleBufferGetFormatDescription(buffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return 0 }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let pointer else { return 0 }
        var sum = 0.0
        var count = 0
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

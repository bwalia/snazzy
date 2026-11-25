@preconcurrency import AVFoundation
import Foundation
import Observation
import SnazzyCore
@preconcurrency import Speech
import UIKit

/// Voice notes on iPhone and iPad: record while you talk, see the words as you
/// say them, mark good ideas. Speech is turned into text on this device only.
/// Notes are the same format as on the Mac (`docs/specs/voice-notes.md`), kept in
/// Documents/Voice Notes so they show in the Files app.
@MainActor @Observable
final class VoiceNotesModel {
    enum Phase: Equatable { case idle, recording, saving }

    private(set) var notes: [VoiceNote] = []
    private(set) var phase: Phase = .idle
    private(set) var started: Date?
    private(set) var partial = ""
    private(set) var level: Double = 0
    private(set) var pendingMarks: [VoiceNote.Mark] = []
    private(set) var polishing: Set<String> = []
    var problem: String?
    var query = ""

    @ObservationIgnored let store: VoiceNoteStore
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var file: AVAudioFile?
    @ObservationIgnored private var fileURL: URL?
    /// Text from recognizer sessions that already ended (a long pause ends one; a new one starts).
    @ObservationIgnored private var finished = ""
    @ObservationIgnored private var generation = 0

    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "Voice Notes", directoryHint: .isDirectory)
    }

    init(root: URL = VoiceNotesModel.folder) {
        store = VoiceNoteStore(root: root)
        reload()
    }

    var isRecording: Bool { phase == .recording }
    var shown: [VoiceNote] { notes.filter { $0.matches(query) } }
    func note(_ id: String) -> VoiceNote? { notes.first { $0.id == id } }
    func reload() { notes = store.all() }

    static var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }

    // MARK: Recording

    func start() async {
        guard phase == .idle else { return }
        problem = nil
        partial = ""
        finished = ""
        pendingMarks = []
        guard await Self.authorize() else {
            problem = "Allow the microphone and speech recognition for Snazzy Pro in Settings."
            return
        }
        guard let recognizer = Self.recognizer() else {
            problem = "Speech can only be turned into text on this device, and it can't do that for your language yet. Turn on Dictation for it in Settings › General › Keyboard."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else { throw VoiceNoteError("No microphone is available.") }
            let url = FileManager.default.temporaryDirectory.appending(path: "voice-note-\(UUID().uuidString).m4a")
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount, AVEncoderBitRateKey: 64_000,
            ], commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            let feed = AudioFeed(file: file) { [weak self] level in Task { @MainActor in self?.level = level } }
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in feed.take(buffer) }
            self.engine = engine
            self.file = file
            self.fileURL = url
            self.feed = feed
            listen(with: recognizer)
            engine.prepare()
            try engine.start()
            started = Date()
            phase = .recording
            UIApplication.shared.isIdleTimerDisabled = true
        } catch {
            problem = error.localizedDescription
            teardown()
        }
    }

    @ObservationIgnored private var feed: AudioFeed?

    /// One recognizer session; when it ends by itself (a long pause), keep its text and start another.
    private func listen(with recognizer: SFSpeechRecognizer) {
        generation += 1
        let current = generation
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        feed?.request = request
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let ended = (result?.isFinal ?? false) || error != nil
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                if let text { self.partial = Self.joined(self.finished, text) }
                if ended, self.phase == .recording {
                    self.finished = self.partial
                    self.listen(with: recognizer)
                }
            }
        }
    }

    static func joined(_ a: String, _ b: String) -> String {
        [a, b].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    func mark(_ label: String = "Idea") {
        guard isRecording, let started else { return }
        pendingMarks.append(VoiceNote.Mark(at: Date().timeIntervalSince(started), label: label))
    }

    @discardableResult
    func stop() async -> VoiceNote? {
        guard phase == .recording else { return nil }
        phase = .saving
        let duration = started.map { Date().timeIntervalSince($0) } ?? 0
        request?.endAudio()
        try? await Task.sleep(for: .milliseconds(600))
        let text = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        let audio = fileURL
        teardown()
        defer { phase = .idle; started = nil }
        var note = VoiceNote(duration: duration, transcript: text, marks: pendingMarks, device: Self.device,
                             language: Locale.current.identifier.replacingOccurrences(of: "_", with: "-"),
                             transcribedBy: text.isEmpty ? "none" : "on-device")
        pendingMarks = []
        do {
            if let audio, FileManager.default.fileExists(atPath: audio.path) { try store.adoptAudio(audio, into: &note) }
            note = try store.save(note)
        } catch {
            problem = "The voice note couldn't be saved: \(error.localizedDescription)"
            return nil
        }
        reload()
        let id = note.id
        Task { await polish(id) }
        return note
    }

    private func teardown() {
        generation += 1
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        task?.cancel()
        engine = nil
        task = nil
        request = nil
        feed = nil
        file = nil  // closes the file
        fileURL = nil
        level = 0
        UIApplication.shared.isIdleTimerDisabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// The whole recording, transcribed again on this device: cleaner text, with times.
    func polish(_ id: String) async {
        guard let note = store.note(id), let audio = store.audioURL(for: note), !polishing.contains(id) else { return }
        polishing.insert(id)
        defer { polishing.remove(id) }
        guard let segments = try? await SpeechFile.segments(audio), !segments.isEmpty,
              var current = store.note(id), current.transcript == note.transcript else { return }
        current.segments = segments
        current.transcript = VoiceNote.transcript(from: segments)
        current.transcribedBy = "on-device"
        _ = try? store.save(current)
        reload()
    }

    // MARK: Editing

    func update(_ id: String, title: String? = nil, transcript: String? = nil, tags: [String]? = nil) {
        guard var note = store.note(id) else { return }
        if let title { note.title = title }
        if let transcript, transcript != note.transcript { note.transcript = transcript }
        if let tags { note.tags = tags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        _ = try? store.save(note)
        reload()
    }

    func delete(_ id: String) {
        try? store.delete(id)
        reload()
    }

    func audioURL(_ id: String) -> URL? { note(id).flatMap(store.audioURL(for:)) }

    /// The note as a Markdown file to share (AirDrop, Mail, Files, the Mac).
    func markdownFile(_ id: String) -> URL? {
        guard let note = note(id) else { return nil }
        let name = String(note.displayTitle.map { "/:\\".contains($0) ? "-" : $0 }).prefix(80)
        let url = FileManager.default.temporaryDirectory.appending(path: "\(name).md")
        return (try? note.markdown().write(to: url, atomically: true, encoding: .utf8)) == nil ? nil : url
    }

    // MARK: Speech

    static func recognizer() -> SFSpeechRecognizer? {
        guard let r = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              r.supportsOnDeviceRecognition else { return nil }
        return r
    }

    nonisolated static func authorize() async -> Bool {
        let speech: Bool = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in c.resume(returning: status == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}

/// Mic buffers: written to the file, fed to the recognizer, measured for the meter.
/// Runs on the audio thread.
final class AudioFeed: @unchecked Sendable {
    private let lock = NSLock()
    private let file: AVAudioFile
    private let onLevel: @Sendable (Double) -> Void
    private var _request: SFSpeechAudioBufferRecognitionRequest?
    private var lastLevel = Date.distantPast

    init(file: AVAudioFile, onLevel: @escaping @Sendable (Double) -> Void) {
        self.file = file
        self.onLevel = onLevel
    }

    var request: SFSpeechAudioBufferRecognitionRequest? {
        get { lock.withLock { _request } }
        set { lock.withLock { _request = newValue } }
    }

    func take(_ buffer: AVAudioPCMBuffer) {
        try? file.write(from: buffer)
        request?.append(buffer)
        guard Date().timeIntervalSince(lastLevel) > 0.05, let data = buffer.floatChannelData?[0] else { return }
        lastLevel = Date()
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        let db = 20 * log10(max(sqrt(Double(sum) / Double(n)), 1e-6))
        onLevel(min(max((db + 50) / 50, 0), 1))
    }
}

/// Transcribes a saved audio file on this device, with times.
enum SpeechFile {
    static func segments(_ audio: URL, locale: Locale = .current) async throws -> [VoiceNote.Segment] {
        if #available(iOS 26.0, *) { return try await analyzer(audio, locale: locale) }
        return try await legacy(audio, locale: locale)
    }

    @available(iOS 26.0, *)
    static func analyzer(_ audio: URL, locale: Locale) async throws -> [VoiceNote.Segment] {
        var match = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        if match == nil { match = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) }
        guard let supported = match else { throw VoiceNoteError("On-device transcription isn't available for \(locale.identifier).") }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () -> [VoiceNote.Segment] in
            var out: [VoiceNote.Segment] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let times = result.text.runs.compactMap(\.audioTimeRange)
                let start = times.first?.start.seconds ?? result.range.start.seconds
                let end = times.last.map { $0.start.seconds + $0.duration.seconds } ?? (result.range.start.seconds + result.range.duration.seconds)
                out.append(VoiceNote.Segment(start: start, end: end, text: text))
            }
            return out
        }
        try await analyzer.start(inputAudioFile: try AVAudioFile(forReading: audio), finishAfterFile: true)
        return try await collector.value
    }

    static func legacy(_ audio: URL, locale: Locale) async throws -> [VoiceNote.Segment] {
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.supportsOnDeviceRecognition else { throw VoiceNoteError("On-device transcription isn't available.") }
        let request = SFSpeechURLRecognitionRequest(url: audio)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        let words: [(String, Double, Double)] = try await withCheckedThrowingContinuation { continuation in
            var done = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !done else { return }
                if let error {
                    done = true
                    continuation.resume(throwing: error)
                } else if let result, result.isFinal {
                    done = true
                    continuation.resume(returning: result.bestTranscription.segments.map { ($0.substring, $0.timestamp, $0.timestamp + $0.duration) })
                }
            }
        }
        // Words → sentence-sized segments (break after . ! ? or a pause of a second).
        var out: [VoiceNote.Segment] = []
        var current: VoiceNote.Segment?
        for (word, start, end) in words {
            if var c = current, start - c.end < 1 {
                c.text += " " + word
                c.end = end
                current = c
            } else {
                if let c = current { out.append(c) }
                current = VoiceNote.Segment(start: start, end: end, text: word)
            }
            if let c = current, let last = c.text.last, ".!?".contains(last) {
                out.append(c)
                current = nil
            }
        }
        if let c = current { out.append(c) }
        return out
    }
}

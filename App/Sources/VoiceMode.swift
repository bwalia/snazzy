@preconcurrency import AVFoundation
import CaptureEngine
import Foundation
import Observation
import SnazzyCore

/// Voice Mode: a hands-free conversation with the assistant. It listens,
/// runs short commands straight away ("next slide", "start recording"), sends
/// everything else to the assistant, and says the reply out loud with the Mac's
/// built-in voices.
///
/// - While it speaks, the mic is muted everywhere (`MicMute`): its voice isn't
///   recorded, streamed or sent to the live room, and it doesn't hear itself.
/// - While recording, live or streaming, only lines that start with the wake
///   word are for it ("Snazzy, next slide"), so talking to the audience isn't.
/// - Anything that needs your OK (going live, deleting) still asks on screen.
@MainActor @Observable
final class VoiceMode: NSObject, AVSpeechSynthesizerDelegate {
    enum State: Equatable {
        case off
        case listening
        case thinking
        case speaking
    }

    private(set) var state: State = .off
    /// What it heard last, and what it did about it.
    private(set) var heard = ""
    private(set) var lastAction = ""
    var isOn: Bool { state != .off }

    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored let speech = SpeechInput()
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var finishedSpeaking: CheckedContinuation<Void, Never>?

    /// For the confirmation dialog (a static path in ChatSession).
    static weak var current: VoiceMode?

    init(app: AppModel) {
        self.app = app
        super.init()
        synthesizer.delegate = self
        Self.current = self
    }

    /// The live partial transcript while listening.
    var partial: String { scripted ?? speech.partial }
    /// Tours and self-tests: words shown as if heard.
    private(set) var scripted: String?
    var level: Double { speech.level }

    /// Recording, live room or a stream is on: only wake-word lines count.
    var needsWakeWord: Bool {
        app.settings.alwaysNeedWakeWord || app.capture.recorder.isActive || app.live.isRunning || app.broadcast.isActive
    }

    // MARK: On and off

    func toggle() { isOn ? stop() : start() }

    func start() {
        guard !isOn else { return }
        if app.chat.speech.isListening { Task { await app.chat.speech.cancel() } }
        heard = ""
        lastAction = ""
        listen()
    }

    func stop() {
        loop?.cancel()
        loop = nil
        synthesizer.stopSpeaking(at: .immediate)
        resumeAfterSpeaking()
        MicMute.isMuted = false
        Task { await speech.cancel() }
        state = .off
    }

    /// Stops the current reply (it goes back to listening).
    func stopTalking() { synthesizer.stopSpeaking(at: .word) }

    // MARK: Listening

    private func listen() {
        state = .listening
        loop?.cancel()
        loop = Task { [weak self] in
            guard let self else { return }
            guard let text = await self.nextUtterance(), !Task.isCancelled, self.isOn else { return }
            await self.handle(text)
            if !Task.isCancelled, self.isOn { self.listen() }
        }
    }

    /// Listens until the speaker pauses after saying something.
    private func nextUtterance() async -> String? {
        await speech.start(micID: app.capture.setup.mic?.uniqueID, saveAudioTo: nil)
        if case .failed(let message) = speech.state {
            app.chat.voiceNote(message, isError: true)
            stop()
            return nil
        }
        var last = "", changed = Date(), started = Date()
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(150))
            let p = speech.partial
            if p != last { last = p; changed = Date() }
            if !p.isEmpty, Date().timeIntervalSince(changed) > 1.1 { break }
            // The recogniser stops after about a minute: start a fresh one when it's quiet.
            if p.isEmpty, Date().timeIntervalSince(started) > 50 {
                await speech.cancel()
                await speech.start(micID: app.capture.setup.mic?.uniqueID, saveAudioTo: nil)
                started = Date()
            }
        }
        guard !Task.isCancelled else { return nil }
        let text = await speech.stop()?.text ?? last
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Acting

    /// What to do with something said (internal: the tours and self-tests use it).
    func handle(_ said: String) async {
        let wake = app.settings.wakeWord
        var text = said
        if needsWakeWord {
            // Not for us: the presenter was talking to the audience.
            guard let rest = VoiceCommands.afterWakeWord(said, wakeWord: wake) else {
                lastAction = "Ignored: didn't start with “\(wake)”"
                return
            }
            text = rest
        } else if let rest = VoiceCommands.afterWakeWord(said, wakeWord: wake) {
            text = rest
        }
        guard !text.isEmpty else { return }
        heard = text
        if let command = VoiceCommands.parse(text) {
            await run(command)
            return
        }
        await ask(text)
    }

    private func run(_ command: VoiceCommand) async {
        let builder = app.builder, capture = app.capture
        switch command {
        case .nextSlide:
            await move { builder.nextSlide() }
            done("Next slide (\(builder.currentSlide + 1) of \(builder.deckSlides.count))")
        case .previousSlide:
            await move { builder.previousSlide() }
            done("Previous slide (\(builder.currentSlide + 1) of \(builder.deckSlides.count))")
        case .goToSlide(let n):
            await move { builder.goToSlide(n - 1) }
            done("Slide \(builder.currentSlide + 1) of \(builder.deckSlides.count)")
        case .startRecording:
            do {
                try await capture.startRecording()
                done("Recording started")
            } catch {
                done("Couldn't start recording: \(error.localizedDescription)", isError: true)
            }
        case .stopRecording:
            await capture.stopRecording()
            done("Recording stopped and saved")
        case .pauseRecording:
            capture.pauseRecording()
            done("Recording paused")
        case .resumeRecording:
            capture.resumeRecording()
            done("Recording resumed")
        case .startPrompter:
            app.prompter.show()
            app.prompter.start()
            done("Prompter scrolling")
        case .pausePrompter:
            app.prompter.pause()
            done("Prompter paused")
        case .stopListening:
            done("Voice Mode off")
            stop()
        }
    }

    /// Changes slide and waits (briefly) for the deck to report where it is.
    private func move(_ change: () -> Void) async {
        let before = app.builder.currentSlide
        change()
        for _ in 0..<10 where app.builder.currentSlide == before { try? await Task.sleep(for: .milliseconds(60)) }
    }

    private func done(_ action: String, isError: Bool = false) {
        lastAction = action
        app.chat.voiceNote("🎙 “\(heard)” → \(action)", isError: isError)
    }

    /// Sends it to the assistant and says the reply.
    private func ask(_ text: String) async {
        state = .thinking
        let before = app.chat.transcript.count
        guard app.chat.send(text, viaVoice: true, context: context()) else {
            if app.unavailableReason(app.activeSelection.provider) != nil {
                await speak("No AI is set up, but I can still do commands like next slide, start recording or stop recording.")
            }
            return
        }
        while app.chat.isRunning, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard !Task.isCancelled, app.settings.speakReplies else { return }
        let reply = app.chat.transcript.dropFirst(before).last { $0.kind == .assistant && !$0.text.isEmpty }?.text ?? ""
        let spoken = VoiceCommands.speakable(reply)
        if !spoken.isEmpty { await speak(spoken) }
    }

    #if DEBUG
    /// Tours and self-tests: Voice Mode on without the mic.
    func startScripted() {
        heard = ""
        lastAction = ""
        state = .listening
    }

    /// Shows the words appear as if spoken, then acts on them like real speech.
    func say(_ text: String, wordsPerSecond: Double = 3.2, volume: Float? = nil) async {
        state = .listening
        var shown: [Substring] = []
        for word in text.split(separator: " ") {
            shown.append(word)
            scripted = shown.joined(separator: " ")
            try? await Task.sleep(for: .seconds(1 / wordsPerSecond))
        }
        try? await Task.sleep(for: .seconds(0.8))
        scripted = nil
        if let volume { speakVolume = volume }
        await handle(text)
        if isOn { state = .listening }
    }
    #endif

    /// 0…1; self-tests speak silently.
    @ObservationIgnored var speakVolume: Float = 1

    /// What's on screen, so "this slide" means something to the assistant.
    func context() -> String {
        var parts = ["The user is talking in Voice Mode; the reply is read out loud, so answer in a few short spoken sentences, no lists or code."]
        let b = app.builder
        if b.isDeckOpen, b.deckSlides.indices.contains(b.currentSlide) {
            let s = b.deckSlides[b.currentSlide]
            parts.append("Showing slide \(b.currentSlide + 1) of \(b.deckSlides.count), “\(s.displayTitle)”, of the deck “\(b.current?.name ?? "")”.")
            if !s.notes.isEmpty { parts.append("Its speaker notes: \(s.notes.prefix(600))") }
            let titles = b.deckSlides.map(\.displayTitle).enumerated().map { "\($0 + 1). \($1)" }.joined(separator: "; ")
            parts.append("All slides: \(titles.prefix(800))")
        }
        if app.capture.recorder.isActive { parts.append("Recording is on.") }
        if app.live.isRunning { parts.append("A live room is open with \(app.live.viewers) viewers.") }
        if app.broadcast.isActive { parts.append("Streaming is on.") }
        return parts.joined(separator: " ")
    }

    // MARK: Speaking

    /// Says something with the mic muted, then waits for it to finish.
    func speak(_ text: String) async {
        state = .speaking
        MicMute.isMuted = true
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice(identifier: app.settings.voiceIdentifier)
        utterance.rate = Float(app.settings.speechRate)
        utterance.volume = speakVolume
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            finishedSpeaking = c
            synthesizer.speak(utterance)
        }
        // Let the room's echo die down before the mic opens again.
        try? await Task.sleep(for: .milliseconds(300))
        MicMute.isMuted = false
        if isOn { state = .listening }
    }

    /// A heads-up before a confirmation dialog (it can't listen for "yes": you click).
    func announceConfirmation() {
        guard isOn, app.settings.speakReplies else { return }
        MicMute.isMuted = true
        let u = AVSpeechUtterance(string: "I need your OK on screen first.")
        u.voice = Self.voice(identifier: app.settings.voiceIdentifier)
        u.rate = Float(app.settings.speechRate)
        synthesizer.speak(u)
    }

    private func resumeAfterSpeaking() {
        finishedSpeaking?.resume()
        finishedSpeaking = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if self.finishedSpeaking == nil { MicMute.isMuted = false }  // a heads-up line, not a reply
            self.resumeAfterSpeaking()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.resumeAfterSpeaking() }
    }

    // MARK: Voices

    /// The chosen voice, else the best installed one for the user's language.
    static func voice(identifier: String) -> AVSpeechSynthesisVoice? {
        if !identifier.isEmpty, let v = AVSpeechSynthesisVoice(identifier: identifier) { return v }
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(language) && !$0.voiceTraits.contains(.isNoveltyVoice) }
        let region = Locale.current.region?.identifier ?? ""
        return candidates.max { a, b in
            (a.quality.rawValue, a.language.hasSuffix(region) ? 1 : 0) < (b.quality.rawValue, b.language.hasSuffix(region) ? 1 : 0)
        } ?? AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
    }

    /// Voices for the picker: the user's language first, best quality first.
    static func voices() -> [AVSpeechSynthesisVoice] {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language) && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
    }
}

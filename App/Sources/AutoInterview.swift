@preconcurrency import AVFoundation
import Builder
import CaptureEngine
import Foundation
import Interview
import Observation
import SnazzyCore

/// Auto Interview at this Mac: the role's deck on the Present window, each
/// question spoken aloud, answers heard on this Mac (on-device speech
/// recognition), slides kept in step with the interview, and an optional
/// recording of the slides, camera and mic. With local models it works offline.
@MainActor @Observable
final class AutoInterview: NSObject, AVSpeechSynthesizerDelegate {
    struct Options: Equatable {
        var speak = true
        var listen = true
        var showDeck = true
    }

    enum Phase: Equatable {
        case idle, speaking, listening, waiting, done
    }

    private(set) var sessionID: UUID?
    private(set) var options = Options()
    private(set) var phase: Phase = .idle
    /// Words heard so far for the current answer.
    var partial: String { speech.partial }
    var level: Double { speech.level }
    private(set) var problem: String?

    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private let speech = SpeechInput()
    @ObservationIgnored private var spokenTurns = 0
    @ObservationIgnored private var speakQueue: [String] = []
    @ObservationIgnored private var listenTask: Task<Void, Never>?
    @ObservationIgnored private var deckProject: String?
    private var recording = false
    @ObservationIgnored private var finishedSpeaking: CheckedContinuation<Void, Never>?

    init(app: AppModel) {
        self.app = app
        super.init()
        synthesizer.delegate = self
    }

    var isRunning: Bool { sessionID != nil && phase != .done }

    // MARK: Starting and stopping

    /// Prepares the deck (and recording) for an interview at this Mac. The candidate
    /// then reads the notice and starts.
    func prepare(_ id: UUID, options: Options) async {
        stop()
        sessionID = id
        self.options = options
        problem = nil
        spokenTurns = 0
        phase = .idle
        guard let s = app.interviews.session(id) else { return }
        if options.showDeck {
            do {
                let outline = Self.deck(for: s.kit)
                try app.builder.createDeck(outline)
                deckProject = app.builder.current?.name
                app.builder.openPopOut()
            } catch {
                problem = "The interview deck couldn't be made: \(error.localizedDescription)"
            }
        }
        if options.listen, !(await SpeechInput.authorize()) {
            problem = "Speech recognition isn't allowed, so answers are typed. Allow it in System Settings › Privacy & Security › Speech Recognition."
            self.options.listen = false
        }
    }

    /// Called once the candidate has started: records with their camera if they agreed.
    func candidateStarted() async {
        guard let id = sessionID, let s = app.interviews.session(id), s.cameraAgreed, !recording else { return }
        let capture = app.capture
        savedInset = capture.insetFeed?.device
        savedSetup = capture.setup
        // Real cameras only: an iPad or iPhone over USB is its *screen*, and Desk View
        // films the desk. The inset camera counts if it's one of these.
        let cameras = Self.candidateCameras(capture.catalog.cameras)
        let current = capture.insetFeed?.device
        var camera = cameras.first { $0.id == current?.id }
            ?? cameras.first { $0.transport.lowercased().contains("built") } ?? cameras.first
        #if DEBUG
        // Tours may film with an iPad showing its Camera app (its screen, chosen on purpose).
        if let tourCamera { camera = tourCamera }
        #endif
        guard let camera else {
            problem = "No camera found, so the interview isn't recorded."
            return
        }
        capture.setInsetDevice(camera)
        capture.selectSlidesSource()
        do {
            try await capture.startRecording(countdown: 0)
            recording = true
            app.interviews.note(id, "recording_started", detail: camera.name)
        } catch {
            problem = "Recording didn't start: \(error.localizedDescription). The interview carries on without it."
            restoreCapture()
        }
    }

    /// Cameras a candidate may be filmed with: real cameras, not screens or desk views.
    static func candidateCameras(_ cameras: [CaptureDeviceInfo]) -> [CaptureDeviceInfo] {
        cameras.filter { c in
            let name = c.name.lowercased()
            return c.kind == .camera && !name.contains("desk view") && !name.contains("screen")
        }
    }

    /// The candidate turned the camera off: stop, and delete what was recorded.
    func cameraWithdrawn() async {
        guard recording else { return }
        recording = false
        if let result = await app.capture.stopRecording() {
            for url in [result.composite, Chapters.url(forMovie: result.composite), result.rawFolder] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        restoreCapture()
        app.interviews.note(sessionID, "recording_deleted", detail: "camera turned off by the candidate")
    }

    /// Stops recording and links the files to the interview.
    private func finishRecording() async {
        guard recording else { return }
        recording = false
        if let result = await app.capture.stopRecording(), let id = sessionID {
            app.interviews.attachRecording(id, files: [result.composite, Chapters.url(forMovie: result.composite), result.rawFolder])
        }
        restoreCapture()
    }

    #if DEBUG
    /// Tours only: a device to film with even if it isn't a real camera.
    @ObservationIgnored var tourCamera: CaptureDeviceInfo?
    #endif
    @ObservationIgnored private var savedInset: CaptureDeviceInfo?
    @ObservationIgnored private var savedSetup: CaptureSetup?

    private func restoreCapture() {
        if let savedSetup { app.capture.apply(savedSetup) }
        app.capture.setInsetDevice(savedInset)
        savedSetup = nil
        savedInset = nil
    }

    /// Whether the candidate's camera is recording now (for the self-view).
    var isRecording: Bool { recording }

    /// Stops everything and waits for a recording to be saved (tours, quitting).
    func stopAndWait() async {
        let wasRecording = recording
        stop()
        guard wasRecording else { return }
        for _ in 0..<100 where app.capture.recorder.isActive { try? await Task.sleep(for: .milliseconds(100)) }
    }

    func stop() {
        listenTask?.cancel()
        listenTask = nil
        Task { await speech.cancel() }
        synthesizer.stopSpeaking(at: .immediate)
        queued = 0
        speakQueue.removeAll()
        resumeSpeaking()
        if recording { Task { await finishRecording() } }
        phase = sessionID == nil ? .idle : .done
    }

    // MARK: Following the interview

    /// Called after every change to the running interview.
    func update(_ engine: InterviewEngine, busy: Bool) {
        guard engine.session.id == sessionID else { return }
        let s = engine.session
        if deckProject != nil { app.builder.goToSlide(Self.slideIndex(for: engine)) }
        let new = s.turns.dropFirst(spokenTurns).filter { $0.role == .interviewer }
        spokenTurns = s.turns.count
        if s.isFinished {
            listenTask?.cancel()
            Task { await speech.cancel() }
            if options.speak {
                for t in new { say(t.text) }
            }
            Task {
                await waitForSpeech()
                await finishRecording()
                phase = .done
            }
            return
        }
        guard s.state == .inProgress else {
            listenTask?.cancel()
            Task { await speech.cancel() }
            phase = .idle
            return
        }
        if busy {
            phase = .waiting
            return
        }
        if options.speak { for t in new { say(t.text) } }
        if options.listen, listenTask == nil {
            listenTask = Task { [weak self] in
                await self?.waitForSpeech()
                await self?.listen()
                self?.listenTask = nil
            }
        } else if !options.listen, phase != .speaking {
            phase = .idle
        }
    }

    /// Waits until the interviewer has finished speaking (tours).
    func untilQuiet() async {
        try? await Task.sleep(for: .milliseconds(300))
        for _ in 0..<300 where queued > 0 || synthesizer.isSpeaking { try? await Task.sleep(for: .milliseconds(200)) }
    }

    /// The candidate would rather type (or asked for text instead of voice).
    func useTyping() {
        options.listen = false
        listenTask?.cancel()
        listenTask = nil
        Task { await speech.cancel() }
        if phase == .listening { phase = .idle }
    }

    /// The candidate pressed "I've finished answering".
    func finishAnswer() {
        guard phase == .listening else { return }
        doneListening = true
    }

    @ObservationIgnored private var doneListening = false

    private func listen() async {
        guard let id = sessionID, let s = app.interviews.session(id), s.state == .inProgress, !Task.isCancelled else { return }
        phase = .listening
        doneListening = false
        await speech.start(micID: app.capture.setup.mic?.uniqueID, saveAudioTo: nil)
        // Stops after 3.5 s without new words once something has been said, or when they press the button.
        var last = ""
        var still = Date()
        while !Task.isCancelled, !doneListening {
            try? await Task.sleep(for: .milliseconds(250))
            let now = speech.partial
            if now != last { last = now; still = Date() }
            if !now.isEmpty, Date().timeIntervalSince(still) > 3.5 { break }
            if case .failed(let why) = speech.state { problem = why; break }
        }
        let result = await speech.stop()
        guard !Task.isCancelled else { return }
        phase = .waiting
        let text = (result?.text ?? last).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { phase = .idle; listenTask = nil; return }
        app.interviews.send(Self.event(for: text, choices: app.interviews.engine(id)?.currentChoices), to: id)
    }

    /// Short spoken requests ("could you repeat that?") become events; answers to
    /// yes/no questions become the choice.
    static func event(for text: String, choices: [String]?) -> CandidateEvent {
        let t = text.lowercased()
        let words = t.split(separator: " ").count
        if words <= 8 {
            if t.contains("repeat") { return .repeatQuestion }
            if t.contains("rephrase") || t.contains("say that differently") || t.contains("another way") { return .rephraseQuestion }
            if t.contains("speak to a person") || t.contains("talk to a person") || t.contains("speak to a human") || t.contains("talk to a human") { return .askForPerson }
            if t.hasPrefix("pause") || t.contains("take a break") { return .pause }
        }
        if let choices {
            if let c = choices.first(where: { t.contains($0.lowercased()) }) { return .answer(c, input: .spoken) }
            if choices == ["Yes", "No"] {
                if ["yeah", "yep", "i do", "i have", "correct", "that's right", "sure"].contains(where: t.contains) { return .answer("Yes", input: .spoken) }
                if ["nope", "i don't", "i do not", "i haven't"].contains(where: t.contains) { return .answer("No", input: .spoken) }
            }
        }
        return .answer(text, input: .spoken)
    }

    // MARK: Speaking

    private func say(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        u.voice = VoiceMode.voice(identifier: app.settings.voiceIdentifier)
        u.rate = Float(app.settings.speechRate)
        phase = .speaking
        queued += 1
        synthesizer.speak(u)
    }

    /// Sentences given to the synthesizer and not yet finished (its own isSpeaking
    /// can still be true when the last one's "finished" arrives).
    @ObservationIgnored private var queued = 0

    private func waitForSpeech() async {
        guard queued > 0 else { return }
        // At most a minute, so a lost "finished" can't stall the interview.
        let guardTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(60))
            self?.queued = 0
            self?.resumeSpeaking()
        }
        await withCheckedContinuation { c in
            if queued > 0 { finishedSpeaking = c } else { c.resume() }
        }
        guardTask.cancel()
        // Let the room's echo die down before listening.
        try? await Task.sleep(for: .milliseconds(400))
    }

    private func resumeSpeaking() {
        finishedSpeaking?.resume()
        finishedSpeaking = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.utteranceEnded() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.utteranceEnded() }
    }

    private func utteranceEnded() {
        queued = max(0, queued - 1)
        if queued == 0 { resumeSpeaking() }
    }

    // MARK: The deck

    /// A deck for the role: title, how it works, then one slide per question, the
    /// candidate's questions and a closing slide. Speaker notes carry the full question.
    static func deck(for kit: RoleKit) -> DeckOutline {
        typealias Slide = SampleDeck.Slide
        let org = kit.organisation.isEmpty ? "First-round interview" : kit.organisation
        var slides: [Slide] = [
            Slide(.title, kit.title, [org], notes: "Welcome. The interviewer is an AI; a person decides."),
            Slide(.steps, "How this interview works", [
                "\(kit.questions.count) main questions, the same for every candidate",
                "Short follow-ups about your answers",
                "Ask for any question to be repeated or rephrased",
                "Your questions at the end",
                "A person on the hiring team reviews everything and decides",
            ], notes: "Explain the format."),
        ]
        if !kit.eligibility.isEmpty {
            slides.append(Slide(.bullets, "A few quick questions", kit.eligibility.map(\.text), notes: "The role's requirements."))
        }
        for (i, q) in kit.questions.enumerated() {
            slides.append(Slide(.quote, q.text, ["Question \(i + 1) of \(kit.questions.count)"], notes: q.text))
        }
        slides.append(Slide(.bullets, "Your questions", ["Ask about the role, the team or the process"], notes: "Candidate questions."))
        slides.append(Slide(.closing, "Thank you", [kit.settings.nextSteps], notes: "Closing."))
        return DeckOutline(title: "Interview: \(kit.title)", slides: slides)
    }

    /// The slide for where the interview is.
    static func slideIndex(for engine: InterviewEngine) -> Int {
        let kit = engine.session.kit
        let eligibilitySlides = kit.eligibility.isEmpty ? 0 : 1
        let firstQuestion = 2 + eligibilitySlides
        switch engine.currentStep {
        case .eligibility?: return 2
        case .core(let q)?: return firstQuestion + (kit.questions.firstIndex { $0.id == q.id } ?? 0)
        case .candidateQuestions?: return firstQuestion + kit.questions.count
        case .closing?, nil:
            return engine.session.state == .invited ? 0 : firstQuestion + kit.questions.count + 1
        }
    }
}

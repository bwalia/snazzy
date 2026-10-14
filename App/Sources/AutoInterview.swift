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
        var record = false
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
    @ObservationIgnored private var recording = false
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

    /// Called once the candidate has started: begins recording if chosen.
    func candidateStarted() async {
        guard options.record, !recording else { return }
        app.capture.selectSlidesSource()
        do {
            try await app.capture.startRecording(countdown: 0)
            recording = true
            app.interviews.note(sessionID, "recording_started")
        } catch {
            problem = "Recording didn't start: \(error.localizedDescription). The interview carries on without it."
        }
    }

    func stop() {
        listenTask?.cancel()
        listenTask = nil
        Task { await speech.cancel() }
        synthesizer.stopSpeaking(at: .immediate)
        speakQueue.removeAll()
        resumeSpeaking()
        if recording {
            recording = false
            Task { _ = await app.capture.stopRecording() }
        }
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
                if recording {
                    recording = false
                    _ = await app.capture.stopRecording()
                    app.interviews.note(sessionID, "recording_saved")
                }
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
        synthesizer.speak(u)
    }

    private func waitForSpeech() async {
        guard synthesizer.isSpeaking else { return }
        await withCheckedContinuation { c in
            if synthesizer.isSpeaking { finishedSpeaking = c } else { c.resume() }
        }
        // Let the room's echo die down before listening.
        try? await Task.sleep(for: .milliseconds(400))
    }

    private func resumeSpeaking() {
        finishedSpeaking?.resume()
        finishedSpeaking = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in if !self.synthesizer.isSpeaking { self.resumeSpeaking() } }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.resumeSpeaking() }
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

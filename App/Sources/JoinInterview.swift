@preconcurrency import AVFoundation
import Builder
import Foundation
import Interview
import Observation
import SnazzyCore

/// The candidate's side of an interview by invite link. OpsAPI runs the
/// interview (the same model and questions for everyone); this Mac shows the
/// interview deck, speaks the questions and hears the answers on-device. If the
/// invite has a pack, it's downloaded with a short-lived link, checked and
/// decrypted here: the link itself is the key, so there's no passcode.
@MainActor @Observable
final class JoinInterview: NSObject, AVSpeechSynthesizerDelegate {
    enum Stage: Equatable {
        case idle, loading, downloading(Double), ready, failed(String)
    }

    private(set) var stage: Stage = .idle
    private(set) var view: CandidateView?
    private(set) var kit: RoleKit?
    private(set) var busy = false
    private(set) var problem: String?
    private(set) var phase: AutoInterview.Phase = .idle
    private(set) var hasIntro = false
    var speak = true
    var listen = true
    var partial: String { speech.partial }
    /// Opens the join window.
    var windowRequest = 0

    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private var client: InviteClient?
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private let speech = SpeechInput()
    @ObservationIgnored private var spoken: Set<String> = []
    @ObservationIgnored private var queued = 0
    @ObservationIgnored private var listenTask: Task<Void, Never>?
    @ObservationIgnored private var doneListening = false
    @ObservationIgnored private var deckProject: String?
    @ObservationIgnored private var introProject: String?

    init(app: AppModel) {
        self.app = app
        super.init()
        synthesizer.delegate = self
    }

    /// This Mac's id for invites (the first device to open an invite keeps it).
    static var deviceID: String {
        let key = "SnazzyPro.interviewDeviceID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString + "-" + UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    var isRunning: Bool { view.map { !$0.isFinished && $0.state != "invited" } ?? false }

    // MARK: Joining

    /// Opens an invite (web link or snazzypro:// link): gets the interview and its pack.
    func join(_ text: String) async {
        guard stage != .loading, !isRunning else { return }
        guard let link = InviteLink(text) else {
            stage = .failed("That isn't an interview link. Paste the whole link from your invitation.")
            return
        }
        reset()
        stage = .loading
        let client = InviteClient(link: link)
        self.client = client
        do {
            var v = try await client.view()
            if v.hasPack == true, !v.isFinished {
                try await openPack(client)
                v = try await client.view()
            }
            view = v
            stage = .ready
            if v.state == "in_progress" { begin() }
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    private func openPack(_ client: InviteClient) async throws {
        let pack = try await client.pack(deviceID: Self.deviceID)
        guard let url = URL(string: pack.url), url.scheme == "https" || ["localhost", "127.0.0.1"].contains(url.host() ?? "") else {
            throw InterviewError("The interview pack's link isn't secure.")
        }
        stage = .downloading(0)
        let progress = DownloadProgress { [weak self] fraction in Task { @MainActor in self?.stage = .downloading(fraction) } }
        let (file, response) = try await URLSession.shared.download(from: url, delegate: progress)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw InterviewError("The interview pack didn't download. Please try again.") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("interview-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let opened = try await Task.detached {
            try InterviewPack.open(file, keyBase64: pack.key, sha256: pack.sha256, into: folder)
        }.value
        try? FileManager.default.removeItem(at: file)
        kit = opened.manifest.kit
        // The interview deck, made from the kit (as at a recruiter's Mac).
        try app.builder.createDeck(AutoInterview.deck(for: opened.manifest.kit))
        deckProject = app.builder.current?.name
        if let intro = opened.introFolder {
            // Shared: served without internet access.
            let project = try app.builder.workspace.importFolder(intro, name: "Intro: \(opened.manifest.kit.title)")
            introProject = project.name
            hasIntro = true
            app.builder.refreshProjects()
        }
        if let deckProject { app.builder.open(deckProject, announce: false) }
    }

    /// Shows the recruiter's introduction deck (if the pack has one).
    func showIntro() {
        guard let introProject else { return }
        app.builder.open(introProject, announce: false)
        app.builder.openPopOut()
    }

    // MARK: The interview

    func start(adjustments: [String]) async {
        guard let client, let v = view else { return }
        if adjustments.contains("text instead of voice") { listen = false }
        if listen, !(await SpeechInput.authorize()) {
            problem = "Speech recognition isn't allowed, so answers are typed. Allow it in System Settings › Privacy & Security › Speech Recognition."
            listen = false
        }
        await call { try await client.start(noticeHash: v.noticeHash, adjustments: adjustments) }
        begin()
    }

    private func begin() {
        app.interviews.enterInterviewMode(lockMac: false)
        if let deckProject {
            app.builder.open(deckProject, announce: false)
            app.builder.openPopOut()
        }
        if let view { apply(view) }
    }

    func answer(_ text: String, input: String = "typed") async {
        guard let client, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await call { try await client.answer(text, input: input) }
    }

    /// repeat | rephrase | pause | resume | person | withdraw | adjustment
    func event(_ type: String) async {
        guard let client else { return }
        await call { try await client.event(type) }
    }

    func sendSelfID(_ answers: [String: String]) async {
        guard let client else { return }
        await call { try await client.selfID(answers) }
    }

    private func call(_ step: () async throws -> CandidateView) async {
        busy = true
        phase = .waiting
        defer { busy = false }
        do {
            let v = try await step()
            problem = nil
            apply(v)
        } catch {
            problem = error.localizedDescription
            phase = .idle
        }
    }

    /// After every answer: slides in step, new questions spoken, then listening.
    private func apply(_ v: CandidateView) {
        view = v
        if let kit, deckProject != nil { app.builder.goToSlide(v.slideIndex(for: kit)) }
        let new = v.turns.filter { $0.role == "interviewer" && !spoken.contains($0.id) }
        spoken.formUnion(new.map(\.id))
        if speak { for t in new { say(t.text) } }
        guard v.state == "in_progress" else {
            listenTask?.cancel()
            Task { await speech.cancel() }
            phase = v.isFinished ? .done : .idle
            if v.isFinished { finish() }
            return
        }
        if listen, listenTask == nil {
            listenTask = Task { [weak self] in
                await self?.waitForSpeech()
                await self?.listenForAnswer()
                self?.listenTask = nil
            }
        } else if !listen {
            phase = .idle
        }
    }

    private func finish() {
        Task {
            await waitForSpeech()
            app.interviews.endInterviewModeOnOwnMac()
        }
    }

    func useTyping() {
        listen = false
        listenTask?.cancel()
        listenTask = nil
        Task { await speech.cancel() }
        if phase == .listening { phase = .idle }
    }

    func finishAnswer() {
        if phase == .listening { doneListening = true }
    }

    private func listenForAnswer() async {
        guard view?.state == "in_progress", !Task.isCancelled else { return }
        phase = .listening
        doneListening = false
        await speech.start(micID: app.capture.setup.mic?.uniqueID, saveAudioTo: nil)
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
        let text = (result?.text ?? last).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { phase = .idle; return }
        listenTask = nil
        switch AutoInterview.event(for: text, choices: view?.choices) {
        case .repeatQuestion: await event("repeat")
        case .rephraseQuestion: await event("rephrase")
        case .askForPerson: await event("person")
        case .pause: await event("pause")
        case .answer(let t, _): await answer(t, input: "spoken")
        default: await answer(text, input: "spoken")
        }
    }

    /// Stops everything and forgets the interview (the window was closed, or another link opened).
    func reset() {
        listenTask?.cancel()
        listenTask = nil
        synthesizer.stopSpeaking(at: .immediate)
        Task { await speech.cancel() }
        view = nil
        kit = nil
        client = nil
        spoken = []
        problem = nil
        phase = .idle
        hasIntro = false
        deckProject = nil
        introProject = nil
        stage = .idle
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

    @ObservationIgnored private var finishedSpeaking: CheckedContinuation<Void, Never>?

    private func waitForSpeech() async {
        guard queued > 0 else { return }
        let guardTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(60))
            self?.queued = 0
            self?.finishedSpeaking?.resume()
            self?.finishedSpeaking = nil
        }
        await withCheckedContinuation { c in
            if queued > 0 { finishedSpeaking = c } else { c.resume() }
        }
        guardTask.cancel()
        try? await Task.sleep(for: .milliseconds(400))
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.utteranceEnded() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.utteranceEnded() }
    }

    private func utteranceEnded() {
        queued = max(0, queued - 1)
        if queued == 0 {
            finishedSpeaking?.resume()
            finishedSpeaking = nil
        }
    }
}

/// Download progress for the interview pack.
final class DownloadProgress: NSObject, URLSessionDownloadDelegate, Sendable {
    let report: @Sendable (Double) -> Void
    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        report(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

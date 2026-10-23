#if DEBUG
import AppKit
import Broadcast
import Builder
import CaptureEngine
import Foundation
import Interview
@preconcurrency import ScreenCaptureKit
import SnazzyCore

/// Films product tours of the real app (debug builds only).
///
/// Launch with `-SnazzyPro.tour <name>`: the app runs the tour's steps through
/// its own controllers (as if the user clicked and typed) while recording its
/// main window with ScreenCaptureKit, then quits. Tours start a fresh
/// conversation, hide the conversation list, record slides rather than the
/// screen, leave the camera off, and put settings back afterwards.
@MainActor
enum Tours {
    static let all = ["deck-by-talking", "sample-decks", "present-and-record", "live-classroom", "share", "go-live",
                      "voice-presenter", "agent-classroom", "interview-recruiter", "auto-interview",
                      "interview-kit-from-jd", "auto-interview-camera", "interview-online"]
    /// Tours that film sound (the assistant speaking).
    static let withSound: Set<String> = ["voice-presenter", "auto-interview", "auto-interview-camera", "interview-online"]
    /// Interview tours: `-SnazzyPro.tourRole cdn|devops|fde|mlops` picks the sample role
    /// (the film is named after it), `-SnazzyPro.tourCamera iPad` the candidate's camera.
    static let interviewTours: Set<String> = ["interview-recruiter", "auto-interview", "interview-kit-from-jd", "auto-interview-camera", "interview-online"]
    static var tourRole: String? { UserDefaults.standard.string(forKey: "SnazzyPro.tourRole") }

    static var folder: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appending(path: "Snazzy Pro/Tours", directoryHint: .isDirectory)
    }

    static func run(_ name: String, app: AppModel) async {
        setvbuf(stdout, nil, _IOLBF, 0)  // progress shows up in logs as it happens
        print("TOUR \(name): starting")
        let savedSetup = app.capture.setup
        let savedTab = app.sidePanelTab
        let savedSettings = app.settings
        app.sessionLoggingSuspended = true
        app.hideConversations = true
        let projectsBefore = Set(app.builder.workspace.listProjects().map(\.name))
        let conversationsBefore = Set(app.chat.conversations.map(\.id))
        app.chat.clear()
        app.capture.setInsetDevice(nil)
        guard let window = NSApp.windows.first(where: { $0.title == "Snazzy Pro" && $0.isVisible }) else {
            print("TOUR \(name): no main window"); NSApp.terminate(nil); return
        }
        // On a Retina screen if there is one (sharper film), fully on screen.
        let screen = NSScreen.screens.first { $0.backingScaleFactor >= 2 } ?? NSScreen.main ?? NSScreen.screens[0]
        let v = screen.visibleFrame
        let size = NSSize(width: min(1600, v.width - 40), height: min(1000, v.height - 40))
        window.setFrame(NSRect(x: v.midX - size.width / 2, y: v.midY - size.height / 2, width: size.width, height: size.height), display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(for: .seconds(1.5))

        // Interview tours film their own windows: the Interviews window, or the
        // whole screen (deck and candidate window side by side).
        var filmed = window
        var wholeScreen = false
        var interviewSetup: InterviewTour?
        if interviewTours.contains(name) {
            do {
                print("TOUR \(name): preparing \(tourRole ?? "default role")")
                let setup = try await InterviewTour.prepare(name, app: app, screen: screen)
                print("TOUR \(name): prepared")
                interviewSetup = setup
                if let w = setup.window { filmed = w } else { wholeScreen = true }
            } catch {
                print("TOUR \(name): setup failed: \(error.localizedDescription)"); NSApp.terminate(nil); return
            }
        }

        let film = WindowFilm()
        let url = folder.appending(path: "\(name)\(interviewTours.contains(name) ? tourRole.map { "-\($0)" } ?? "" : "").mp4")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: url)
            if wholeScreen {
                try await film.start(screen: screen, to: url, sound: withSound.contains(name))
            } else {
                try await film.start(window: filmed, to: url, sound: withSound.contains(name))
            }
        } catch {
            print("TOUR \(name): can't film: \(error.localizedDescription)")
        }
        var cleanUp: [() async -> Void] = []
        do {
            switch name {
            case "deck-by-talking": try await deckByTalking(app)
            case "sample-decks": try await sampleDecks(app)
            case "present-and-record": cleanUp.append(try await presentAndRecord(app))
            case "live-classroom": try await liveClassroom(app)
            case "share": try await share(app)
            case "go-live": cleanUp.append(try await goLive(app))
            case "voice-presenter": cleanUp.append(try await voicePresenter(app))
            case "agent-classroom": cleanUp.append(try await agentClassroom(app))
            case "interview-recruiter", "auto-interview", "interview-kit-from-jd", "auto-interview-camera", "interview-online": if let interviewSetup { cleanUp.append(try await interviewSetup.play(app)) }
            default: print("TOUR: unknown tour \(name). Tours: \(all.joined(separator: ", "))")
            }
        } catch {
            print("TOUR \(name): step failed: \(error.localizedDescription)")
        }
        try? await Task.sleep(for: .seconds(1.5))
        await film.stop()
        for c in cleanUp { await c() }
        // Leave no trace: the tour's conversations and new (non-sample) projects.
        for c in app.chat.conversations where !conversationsBefore.contains(c.id) { app.chat.delete(c.id) }
        for p in app.builder.workspace.listProjects() where !projectsBefore.contains(p.name) && !p.name.hasPrefix("sample-") {
            try? app.builder.workspace.deleteProject(p.name)
        }
        // Even if a step failed before its own clean-up was set up.
        Confirm.autoApproveAfter = nil
        app.settings = savedSettings
        app.capture.apply(savedSetup)
        app.sidePanelTab = savedTab
        app.hideConversations = false
        print("TOUR \(name): saved \(url.path)")
        NSApp.terminate(nil)
    }

    static func pause(_ s: Double) async throws { try await Task.sleep(for: .seconds(s)) }

    /// Types into the chat box a few characters at a time, then sends.
    static func type(_ text: String, app: AppModel) async throws {
        app.chat.draft = ""
        var typed = ""
        for ch in text {
            typed.append(ch)
            app.chat.draft = typed
            try await Task.sleep(for: .milliseconds(28))
        }
        try await pause(0.6)
        _ = app.chat.sendDraft()
    }

    static func waitForAssistant(_ app: AppModel, max: Double = 300) async throws {
        try await pause(1)
        let end = Date().addingTimeInterval(max)
        while app.chat.isRunning && Date() < end { try await pause(0.5) }
    }

    static func showSlides(_ app: AppModel, from: Int = 0, count: Int, each: Double) async throws {
        for i in from..<min(from + count, app.builder.deckSlides.count) {
            app.builder.goToSlide(i)
            try await pause(each)
        }
    }

    static func openSample(_ id: String, app: AppModel) throws {
        guard let s = SampleDeck.all.first(where: { $0.id == id }) else { return }
        try app.builder.openSample(s)
    }

    // MARK: Tours

    static func deckByTalking(_ app: AppModel) async throws {
        app.sidePanelTab = .builder
        try await pause(1.5)
        try await type("Make a 4-slide deck introducing our coffee shop's new loyalty app to the team: what it is, how customers earn points, launch dates, and what staff need to do. Add speaker notes.", app: app)
        try await waitForAssistant(app)
        try await pause(1)
        try await showSlides(app, count: 4, each: 2.5)
        app.sidePanelTab = .slides
        app.slidesMode = .present
        try await pause(3)
    }

    static func sampleDecks(_ app: AppModel) async throws {
        app.sidePanelTab = .slides
        app.slidesMode = .samples
        try await pause(5)
        try openSample("hand-hygiene", app: app)
        app.sidePanelTab = .builder
        try await pause(2)
        try await showSlides(app, count: 4, each: 2)
        app.sidePanelTab = .slides
        app.slidesMode = .samples
        try await pause(2)
        try openSample("onboarding", app: app)
        app.sidePanelTab = .builder
        try await pause(1.5)
        try await showSlides(app, count: 3, each: 2)
    }

    static func presentAndRecord(_ app: AppModel) async throws -> () async -> Void {
        try openSample("sales-demo", app: app)
        app.capture.selectSlidesSource()
        app.sidePanelTab = .slides
        app.slidesMode = .present
        try await pause(2.5)
        app.builder.openPopOut()
        try await pause(1)
        NSApp.windows.first(where: { $0.title == "Snazzy Pro" })?.makeKeyAndOrderFront(nil)
        try await app.capture.startRecording(countdown: 3)
        // While recording: the slides themselves (Builder preview), then the notes view.
        try await pause(1)
        app.sidePanelTab = .builder
        try await showSlides(app, from: 0, count: 4, each: 2.8)
        app.sidePanelTab = .slides
        try await showSlides(app, from: 4, count: 2, each: 2.8)
        let result = await app.capture.stopRecording()
        app.builder.closePopOutIfOpen()
        app.sidePanelTab = .recordings
        try await pause(4)
        return {
            if let r = result {
                for u in [r.composite, Chapters.url(forMovie: r.composite), r.rawFolder] { try? FileManager.default.removeItem(at: u) }
            }
        }
    }

    /// The assistant on the local model, so tours don't need a cloud key. Puts the
    /// user's choice back afterwards.
    static func useLocalModel(_ app: AppModel) -> () -> Void {
        let saved = app.settings
        let model = ProcessInfo.processInfo.environment["SNAZZY_TOUR_MODEL"] ?? "qwen3-coder:30b"
        for task in AssistantTask.allCases { app.settings.setSelection(ModelSelection(provider: .ollama, model: model), for: task) }
        return { app.settings = saved }
    }

    /// Voice Mode runs a talk: slides and the recording by voice, audience talk
    /// ignored, and a question answered out loud with the mic muted.
    static func voicePresenter(_ app: AppModel) async throws -> () async -> Void {
        let restoreModel = useLocalModel(app)
        try openSample("sales-demo", app: app)
        app.capture.selectSlidesSource()
        app.sidePanelTab = .slides
        app.slidesMode = .present
        try await pause(2)
        app.builder.openPopOut()
        try await pause(1)
        NSApp.windows.first(where: { $0.title == "Snazzy Pro" })?.makeKeyAndOrderFront(nil)
        let voice = app.voice!
        voice.startScripted()
        try await pause(2)
        await voice.say("Go to the first slide")
        try await pause(1.5)
        await voice.say("Snazzy, start recording")
        while app.capture.recorder.state != .recording { try await pause(0.3) }
        try await pause(1.5)
        // Talking to the audience: not for the assistant.
        await voice.say("Good morning everyone, thanks for joining. Today I'll show you how we cut onboarding from two weeks to two days.")
        try await pause(2.5)
        await voice.say("Snazzy, next slide")
        try await pause(3)
        await voice.say("Snazzy, next slide")
        try await pause(2.5)
        await voice.say("Snazzy, in one sentence, what's the key point of this slide?")
        try await pause(1.5)
        await voice.say("Snazzy, next slide")
        try await pause(3)
        await voice.say("Snazzy, stop recording")
        while app.capture.recorder.isActive { try await pause(0.3) }
        let result = app.capture.recorder.lastResult
        try await pause(1.5)
        await voice.say("Snazzy, stop listening")
        app.builder.closePopOutIfOpen()
        app.sidePanelTab = .recordings
        try await pause(3)
        return {
            restoreModel()
            if let r = result {
                for u in [r.composite, Chapters.url(forMovie: r.composite), r.rawFolder] { try? FileManager.default.removeItem(at: u) }
            }
        }
    }

    /// The assistant runs a live lesson from the chat: opens the room (you
    /// approve it), welcomes the class, seeds the board, then turns the
    /// students' ideas into a deck.
    static func agentClassroom(_ app: AppModel) async throws -> () async -> Void {
        let restoreModel = useLocalModel(app)
        Confirm.autoApproveAfter = 3
        try openSample("lesson-photosynthesis", app: app)
        app.capture.selectSlidesSource()
        app.builder.openPopOut()
        NSApp.windows.first(where: { $0.title == "Snazzy Pro" })?.makeKeyAndOrderFront(nil)
        app.sidePanelTab = .live
        try await pause(2)
        // One request per message: local models do several-in-one less reliably.
        try await type("Start a live room for my class to brainstorm “How could our school use less energy?”", app: app)
        try await waitForAssistant(app)
        try await pause(1.5)
        try await type("Post a short welcome message to the students.", app: app)
        try await waitForAssistant(app)
        try await pause(1.5)
        try await type("Add two starter ideas of your own to the board.", app: app)
        try await waitForAssistant(app)
        try await pause(2)
        guard let url = app.live.joinURL, let base = URL(string: "/", relativeTo: url) else {
            return { Confirm.autoApproveAfter = nil; restoreModel() }
        }
        let ideas = [("Turn off screens at the end of every lesson", "Maya"), ("Solar panels on the sports hall roof", "Leo"),
                     ("An energy monitor display in the hall", "Priya"), ("Walk or cycle to school week", "Sam")]
        for (i, idea) in ideas.enumerated() {
            try await post("api/notes", ["text": .string(idea.0), "name": .string(idea.1)], client: "student-\(i)", base: base, code: app.live.code)
            try await pause(1.4)
        }
        let noteIDs = app.live.board.ranked.map(\.id)
        for v in 0..<8 {
            if let id = noteIDs[safe: [1, 0, 1, 2, 1, 0, 3, 1][v]] {
                try await post("api/vote", ["id": .string(id)], client: "voter-\(v)", base: base, code: app.live.code)
            }
            try await pause(0.4)
        }
        try await pause(1.5)
        try await type("Tell the class that voting is closed.", app: app)
        try await waitForAssistant(app)
        try await pause(1.5)
        try await type("Create a new presentation project with 3 slides from the top ideas on the board, with speaker notes.", app: app)
        try await waitForAssistant(app)
        app.sidePanelTab = .builder
        try await pause(1.5)
        try await showSlides(app, count: 3, each: 2.5)
        return {
            Confirm.autoApproveAfter = nil
            app.live.stop()
            restoreModel()
        }
    }

    static func liveClassroom(_ app: AppModel) async throws {
        try openSample("lesson-photosynthesis", app: app)
        app.capture.selectSlidesSource()
        app.builder.openPopOut()
        NSApp.windows.first(where: { $0.title == "Snazzy Pro" })?.makeKeyAndOrderFront(nil)
        app.sidePanelTab = .live
        app.live.pendingTopic = "How could our school use less energy?"
        try await pause(2.5)
        await app.live.start()
        try await pause(3)
        guard let url = app.live.joinURL, let base = URL(string: "/", relativeTo: url) else { return }
        // Students post from their browsers (here: over HTTP, like the page does).
        let ideas = [("Turn off screens at the end of every lesson", "Maya"), ("Solar panels on the sports hall roof", "Leo"),
                     ("An energy monitor display in the hall", "Priya"), ("Walk or cycle to school week", "Sam")]
        for (i, idea) in ideas.enumerated() {
            try await post("api/notes", ["text": .string(idea.0), "name": .string(idea.1)], client: "student-\(i)", base: base, code: app.live.code)
            try await pause(1.6)
        }
        app.live.announce("Two minutes left: vote for your favourite two ideas!")
        try await pause(1.5)
        app.live.addIdea("Swap old bulbs for LEDs in every classroom")
        let noteIDs = app.live.board.ranked.map(\.id)
        for v in 0..<9 {
            if let id = noteIDs[safe: [1, 0, 1, 2, 1, 0, 3, 1, 4][v]] {
                try await post("api/vote", ["id": .string(id)], client: "voter-\(v)", base: base, code: app.live.code)
            }
            try await pause(0.5)
        }
        try await pause(2)
        app.live.turnIdeasIntoDeck()
        try await pause(2)
        app.sidePanelTab = .builder
        try await waitForAssistant(app)
        try await showSlides(app, count: 4, each: 2.2)
        app.live.stop()
        try await pause(1)
    }

    static func post(_ path: String, _ body: [String: JSONValue], client: String, base: URL, code: String) async throws {
        var r = URLRequest(url: URL(string: "\(path)?k=\(code)", relativeTo: base)!)
        r.httpMethod = "POST"
        r.setValue(client, forHTTPHeaderField: "X-Snazzy-Client")
        r.httpBody = try JSONValue.object(body).encoded()
        _ = try await URLSession.shared.data(for: r)
    }

    static func share(_ app: AppModel) async throws {
        try openSample("board-results", app: app)
        app.sidePanelTab = .builder
        try await pause(2.5)
        app.sharing.beginExport(project: app.builder.current?.name)
        try await pause(2)
        app.sharing.exportDraft?.note = "Here's the board deck for Thursday. Let me know what you'd change."
        try await pause(5)
        app.sharing.exportDraft = nil
        try await pause(1)
    }

    /// Streams to a local test server (rtmp://127.0.0.1:19360/live, run
    /// `ffmpeg -listen 1 -i rtmp://127.0.0.1:19360/live/tour -f null -`).
    static func goLive(_ app: AppModel) async throws -> () async -> Void {
        let b = app.broadcast!
        let saved = (b.platform, b.destinations, b.servers, b.recordWhileLive, b.savedKeys.contains(.custom))
        try openSample("release-demo", app: app)
        app.capture.selectSlidesSource()
        app.builder.openPopOut()
        NSApp.windows.first(where: { $0.title == "Snazzy Pro" })?.makeKeyAndOrderFront(nil)
        app.sidePanelTab = .live
        try await pause(1)
        app.liveScrollTarget = "broadcast"
        b.platform = .youtube
        try await pause(3)
        b.platform = .custom
        b.servers[.custom] = "rtmp://127.0.0.1:19360/live"
        if !saved.4 { b.saveKey("tour", for: .custom) }
        b.destinations = [.custom]
        b.recordWhileLive = false
        try await pause(2)
        await b.start([.custom])
        try await pause(3)
        // What viewers see: the slides, streaming.
        app.sidePanelTab = .builder
        try await showSlides(app, from: 0, count: 3, each: 2.5)
        app.sidePanelTab = .live
        try await pause(0.5)
        app.liveScrollTarget = "broadcast"
        try await pause(3)
        await b.stop()
        try await pause(1.5)
        return {
            if !saved.4 { b.deleteKey(for: .custom) }
            b.platform = saved.0
            b.destinations = saved.1
            b.servers = saved.2
            b.recordWhileLive = saved.3
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// Records one window to an MP4 with ScreenCaptureKit (macOS 15 recording output).
/// The Snazzy Interview tours, on the local model with the sample role.
/// - interview-recruiter: the Interviews window. The sample role is approved, a
///   simulated candidate is interviewed live, the evidence appears, and the
///   recruiter decides; then the fairness report.
/// - auto-interview: the whole screen, with sound. The role's deck (left) follows
///   an Auto Interview in the candidate window (right): questions spoken aloud, a
///   simulated candidate's answers, then the thank-you page.
/// - interview-online: the whole screen, with sound, against a test OpsAPI
///   (`-SnazzyPro.tourOpsAPI http://127.0.0.1:4021`, token in `SNAZZY_TOUR_OPSAPI_TOKEN`).
///   The recruiter invites five candidates in bulk (the pack is encrypted here and
///   uploaded once to S3), then a candidate opens their link: the pack is downloaded
///   and decrypted, the introduction deck plays, and OpsAPI runs the interview while
///   this Mac shows the slides and reads the questions aloud.
@MainActor
struct InterviewTour {
    let name: String
    let window: NSWindow?
    let kitID: UUID
    let sessionID: UUID?
    let restore: () -> Void
    let jobDescription: String
    var introDeck: String?

    static func prepare(_ name: String, app: AppModel, screen: NSScreen) async throws -> InterviewTour {
        let iv = app.interviews!
        iv.unlockForTesting()
        // Anything an interrupted tour left (with its recording) goes first.
        for s in iv.interviews where s.candidate.reference == "Simulation: tour" { iv.delete(s) }
        let restoreModel = Tours.useLocalModel(app)
        let resource = "interview-kit" + ((Tours.tourRole ?? (name == "interview-online" ? "cdn" : nil)).map { "-\($0)" } ?? "")
        guard let kit = iv.addSample(resource) else { throw CaptureError("No sample kit \(resource).") }
        let v = screen.visibleFrame
        if name == "interview-online" {
            return try await prepareOnline(app, kit: kit, frame: v, restore: restoreModel)
        }
        if name == "interview-recruiter" || name == "interview-kit-from-jd" {
            iv.windowRequest += 1
            let w = try await waitForWindow("Interviews")
            let size = NSSize(width: min(1500, v.width - 40), height: min(940, v.height - 40))
            w.setFrame(NSRect(x: v.midX - size.width / 2, y: v.midY - size.height / 2, width: size.width, height: size.height), display: true)
            w.makeKeyAndOrderFront(nil)
            if name == "interview-kit-from-jd" {
                // The tour drafts its own kit from this role's job description.
                iv.delete(kit)
                return InterviewTour(name: name, window: w, kitID: kit.id, sessionID: nil, restore: restoreModel, jobDescription: kit.jobDescription)
            }
            iv.focus = .kit(kit.id)
            try await Tours.pause(1)
            return InterviewTour(name: name, window: w, kitID: kit.id, sessionID: nil, restore: restoreModel)
        }
        // Auto Interview: approve now, make the interview, deck on the left, candidate window on the right.
        try iv.approve(iv.kits.first { $0.id == kit.id }!)
        let approved = iv.kits.first { $0.id == kit.id }!
        let (created, _) = try await iv.createInterview(kit: approved, candidate: Candidate(name: "Jordan Lee", reference: "Simulation: tour"), channel: .thisMac)
        var session = created
        if name == "auto-interview-camera" {
            // The candidate's camera (an iPad over USB, say): set as the inset before they agree.
            // A real camera (an iPhone through Continuity Camera, say), never a device's screen.
            // A real camera by default; an iPad only when asked for by name (its screen, showing
            // its Camera app: check the film before publishing it).
            let query = UserDefaults.standard.string(forKey: "SnazzyPro.tourCamera") ?? "iPhone Camera"
            let catalog = app.capture.catalog
            catalog.refreshAVDevices()
            var camera = AutoInterview.candidateCameras(catalog.cameras).first { $0.name.localizedCaseInsensitiveContains(query) }
            if camera == nil, let device = await catalog.waitForIOSDevice(matching: query, timeout: 20) {
                camera = device
                iv.auto.tourCamera = device
            }
            guard let camera else { throw CaptureError("No camera matching “\(query)”.") }
            app.capture.setInsetDevice(camera)
            session.cameraOffered = true
            iv.save(session: session)
        } else {
            session.cameraOffered = false
            iv.save(session: session)
        }
        await iv.auto.prepare(session.id, options: AutoInterview.Options(speak: true, listen: false, showDeck: true))
        iv.candidateWindowRequest += 1
        let candidate = try await waitForWindow("Interview")
        try await Tours.pause(1.5)
        NSApp.windows.first { $0.title == "Snazzy Pro" }?.orderOut(nil)
        let deckWidth = (v.width * 0.6).rounded()
        if let present = app.builder.presentWindow {
            present.setFrame(NSRect(x: v.minX, y: v.minY, width: deckWidth, height: v.height), display: true)
            present.orderFront(nil)
        }
        candidate.setFrame(NSRect(x: v.minX + deckWidth, y: v.minY, width: v.width - deckWidth, height: v.height), display: true)
        candidate.makeKeyAndOrderFront(nil)
        try await Tours.pause(1)
        return InterviewTour(name: name, window: nil, kitID: kit.id, sessionID: session.id, restore: restoreModel)
    }

    init(name: String, window: NSWindow?, kitID: UUID, sessionID: UUID?, restore: @escaping () -> Void, jobDescription: String = "") {
        self.name = name
        self.window = window
        self.kitID = kitID
        self.sessionID = sessionID
        self.restore = restore
        self.jobDescription = jobDescription
    }

    /// interview-online: a test OpsAPI, the approved kit, an introduction deck, the
    /// join window opened and put aside, then the Interviews window on its own.
    static func prepareOnline(_ app: AppModel, kit: RoleKit, frame v: NSRect, restore: @escaping () -> Void) async throws -> InterviewTour {
        let iv = app.interviews!
        guard let api = UserDefaults.standard.string(forKey: "SnazzyPro.tourOpsAPI").flatMap(URL.init(string:)),
              let token = ProcessInfo.processInfo.environment["SNAZZY_TOUR_OPSAPI_TOKEN"], !token.isEmpty else {
            throw CaptureError("Give a test OpsAPI: -SnazzyPro.tourOpsAPI <url>, token in SNAZZY_TOUR_OPSAPI_TOKEN.")
        }
        iv.tourLink = OpsAPILink(baseURL: api, token: token)
        try iv.approve(iv.kits.first { $0.id == kit.id }!)
        try app.builder.createDeck(DeckOutline(title: "Welcome to Northwind Edge", accent: "#0E9F8F", slides: [
            .init(.title, "Welcome to Northwind Edge", ["Your first-round interview: CDN Engineer"], notes: "Welcome."),
            .init(.stats, "Who we are", ["40", "edge locations", "2.1 Tbps", "peak traffic", "18", "engineers on the CDN team"], notes: "The team."),
            .init(.steps, "What happens next", ["This interview: about 20 minutes, the same questions for everyone",
                                                "A person on the team reads your answers",
                                                "We reply within five working days"], notes: "The process."),
            .init(.closing, "Take your time", ["You can ask for a question again, pause, or speak to a person instead"], notes: "Good luck."),
        ]))
        let intro = app.builder.current?.name
        app.builder.refreshProjects()
        // The join window opens now (while the main window can still open windows), then waits off screen.
        iv.join.windowRequest += 1
        let join = try await waitForWindow("Join an Interview")
        join.orderOut(nil)
        iv.windowRequest += 1
        let w = try await waitForWindow("Interviews")
        // The film is the whole screen: the recruiter's window fills it, so it can be read.
        w.setFrame(v, display: true)
        w.makeKeyAndOrderFront(nil)
        iv.focus = .kit(kit.id)
        NSApp.windows.first { $0.title == "Snazzy Pro" }?.orderOut(nil)
        try await Tours.pause(1.5)
        var tour = InterviewTour(name: "interview-online", window: nil, kitID: kit.id, sessionID: nil, restore: restore)
        tour.introDeck = intro
        return tour
    }

    /// interview-online, played: the recruiter's bulk invite, then one candidate's interview.
    func playOnline(_ app: AppModel, cleanUp: @escaping () async -> Void) async throws -> () async -> Void {
        let iv = app.interviews!
        let join = iv.join!
        let done: () async -> Void = {
            join.reset()
            iv.tourLink = nil
            for title in ["Join an Interview", "Interviews"] { NSApp.windows.first { $0.title == title }?.close() }
            app.builder.closePopOutIfOpen()
            await cleanUp()
        }
        guard let screen = NSApp.windows.first(where: { $0.title == "Interviews" })?.screen ?? NSScreen.main else { return done }
        let v = screen.visibleFrame
        // The recruiter: the approved kit, then Invite in Bulk with a list pasted in.
        try await Tours.pause(3)
        iv.bulkInviteRequest = .init(kitID: kitID, list: """
            Jordan Lee, jordan.lee@example.com
            Priya Shah, priya.shah@example.com
            Sam Okafor, sam.okafor@example.com
            Mei Chen, mei.chen@example.com
            Alex Moreno, alex.moreno@example.com
            """, intro: introDeck ?? "", send: true)
        for _ in 0..<600 where iv.lastInvites == nil { try await Tours.pause(0.2) }
        guard let first = iv.lastInvites?.results.first(where: { $0.appUrl != nil }), let appURL = first.appUrl else {
            throw CaptureError("The invites weren't made.")
        }
        try await Tours.pause(6)
        // A candidate (Jordan) opens their link in Snazzy Pro.
        NSApp.windows.first { $0.title == "Interviews" }?.orderOut(nil)
        guard let joinWindow = NSApp.windows.first(where: { $0.title == "Join an Interview" }) else { throw CaptureError("No join window.") }
        let side = (v.width * 0.4).rounded()
        joinWindow.setFrame(NSRect(x: v.maxX - side, y: v.minY, width: side, height: v.height), display: true)
        joinWindow.makeKeyAndOrderFront(nil)
        join.linkText = ""
        try await Tours.pause(1.5)
        for chunk in stride(from: 0, to: appURL.count, by: 6) {
            join.linkText = String(appURL.prefix(chunk + 6))
            try await Tours.pause(0.02)
        }
        try await Tours.pause(1.5)
        join.speak = true
        join.listen = false
        await join.join(appURL)
        guard join.stage == .ready else { throw CaptureError("The invite didn't open: \(join.stage)") }
        func placeDeck() {
            app.builder.presentWindow?.setFrame(NSRect(x: v.minX, y: v.minY, width: v.width - side, height: v.height), display: true)
            app.builder.presentWindow?.orderFront(nil)
            joinWindow.makeKeyAndOrderFront(nil)
        }
        // The notice, then the recruiter's introduction deck (it came in the encrypted pack).
        try await Tours.pause(4)
        if join.hasIntro {
            join.showIntro()
            try await Tours.pause(1)
            placeDeck()
            try await Tours.showSlides(app, count: 4, each: 3)
        }
        // Jordan starts: OpsAPI runs the interview, this Mac shows the slides and reads the questions.
        await join.start(adjustments: [])
        try await Tours.pause(1)
        placeDeck()
        let answers = [
            "I designed cache keys that ignore tracking parameters, which raised our offload from 70% to 93%, and I checked it against the edge logs.",
            "A 503 spike: I compared edge and origin logs, found the origin was rate-limiting edge addresses, and fixed the allow list with the network team.",
            "I'd move changes into code with review, test them on staging, and keep a one-click rollback to the last version.",
            "We measured it for two weeks with real-user monitoring: the 95th percentile load time fell by about a third.",
        ]
        var n = 0
        while let view = join.view, view.state == "in_progress", n < 20 {
            await join.untilQuiet()
            try await Tours.pause(1.5)
            n += 1
            if let choices = view.choices, let first = choices.first {
                await join.answer(choices.contains("Yes") ? "Yes" : first)
            } else if view.turns.last?.text.contains("questions for me") == true || view.turns.last?.text.contains("anything else") == true {
                await join.answer("No more questions, thank you.")
            } else {
                await join.answer(answers[min(n - 1, answers.count - 1)])
            }
            if let p = join.problem { throw CaptureError(p) }
        }
        await join.untilQuiet()
        // The thank-you page (interview mode has ended and brought the main window back).
        try await Tours.pause(1)
        NSApp.windows.first { $0.title == "Snazzy Pro" }?.orderOut(nil)
        joinWindow.setFrame(NSRect(x: v.midX - 450, y: v.minY + 60, width: 900, height: v.height - 120), display: true)
        joinWindow.makeKeyAndOrderFront(nil)
        try await Tours.pause(6)
        return done
    }

    static func waitForWindow(_ title: String) async throws -> NSWindow {
        for _ in 0..<50 {
            if let w = NSApp.windows.first(where: { $0.title == title && $0.isVisible }) { return w }
            try await Tours.pause(0.2)
        }
        throw CaptureError("The \(title) window didn't open.")
    }

    /// Runs the tour; returns its clean-up (removes the tour's kit and interviews).
    func play(_ app: AppModel) async throws -> () async -> Void {
        let iv = app.interviews!
        let cleanUp: () async -> Void = {
            await iv.auto.stopAndWait()
            for s in iv.interviews where s.kit.id == kitID { iv.delete(s) }
            if let k = iv.kits.first(where: { $0.id == kitID }) { iv.delete(k) }
            NSApp.windows.first { $0.title == "Snazzy Pro" }?.makeKeyAndOrderFront(nil)
            restore()
        }
        if name == "interview-online" { return try await playOnline(app, cleanUp: cleanUp) }
        if name == "interview-kit-from-jd" {
            // A job description in, a draft kit out: competencies, rubric, questions, eligibility.
            try await Tours.pause(1.5)
            let kit = try await iv.generateKit(from: jobDescription)
            iv.focus = .kit(kit.id)
            try await Tours.pause(7)
            if KitValidator.canApprove(kit) {
                try iv.approve(kit)
                try await Tours.pause(3)
            }
            let drafted = kit.id
            return {
                if let k = iv.kits.first(where: { $0.id == drafted }) { iv.delete(k) }
                await cleanUp()
            }
        }
        if name == "interview-recruiter" {
            // The kit editor: competencies, questions, rubric; then approve.
            try await Tours.pause(4)
            try iv.approve(iv.kits.first { $0.id == kitID }!)
            try await Tours.pause(2.5)
            // A simulated candidate, interviewed live.
            let kit = iv.kits.first { $0.id == kitID }!
            let before = Set(iv.interviews.map(\.id))
            let run = Task { try await iv.simulate(kit: kit, persona: SimulatedCandidate.all[0]) }
            var id: UUID?
            for _ in 0..<50 where id == nil {
                id = iv.interviews.first { !before.contains($0.id) }?.id
                try await Tours.pause(0.2)
            }
            if let id { iv.focus = .interview(id) }
            _ = try await run.value
            try await Tours.pause(5)
            // The recruiter decides (a person, never the AI).
            if let id, let s = iv.session(id) {
                let levels = Dictionary(uniqueKeysWithValues: (s.evaluation?.competencies ?? []).compactMap { r in r.level.map { (r.id, $0) } })
                iv.decide(id, .advance, reason: "Evidence meets the role's needs", note: "Strong coaching example; probe data skills next round.", levels: levels)
            }
            try await Tours.pause(4)
            iv.focus = .fairness
            try await Tours.pause(3)
            return cleanUp
        }
        guard let id = sessionID else { return cleanUp }
        // The candidate reads the notice, then starts.
        try await Tours.pause(5)
        if name == "auto-interview-camera" {
            // The candidate ticks the camera box themselves.
            iv.setCamera(id, agreed: true)
            try await Tours.pause(3)
        }
        let notice = InterviewPrompts.notice(for: iv.session(id)!.kit, provider: iv.providerName)
        iv.start(id, noticeHash: InterviewPrompts.hash(notice), adjustments: [])
        try await iv.playCandidate(SimulatedCandidate.all[0], in: id) { await iv.auto.untilQuiet() }
        await iv.auto.untilQuiet()
        try await Tours.pause(4)
        if name == "auto-interview-camera" {
            // Then the recruiter's side: the evidence, and the recording played back.
            for _ in 0..<600 where iv.session(id)?.evaluation == nil || iv.session(id)?.recordingMovie == nil { try await Tours.pause(0.5) }
            iv.windowRequest += 1
            let w = try await InterviewTour.waitForWindow("Interviews")
            if let screen = NSApp.windows.first(where: { $0.title == "Interview" })?.screen ?? NSScreen.main {
                w.setFrame(screen.visibleFrame, display: true)
            }
            w.makeKeyAndOrderFront(nil)
            iv.focus = .interview(id)
            try await Tours.pause(4)
            iv.playRecording = id
            try await Tours.pause(14)
        }
        return cleanUp
    }
}

final class WindowFilm: NSObject, SCRecordingOutputDelegate, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private var finished: CheckedContinuation<Void, Never>?

    @MainActor
    func start(window: NSWindow, to url: URL, sound: Bool = false) async throws {
        // A window that has only just opened takes a moment to reach the screen.
        var found: SCWindow?
        for _ in 0..<30 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            found = content.windows.first { $0.windowID == CGWindowID(window.windowNumber) }
            if let f = found, f.isOnScreen, f.frame.width > 0 { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard let w = found else { throw CaptureError("The window isn't available to capture.") }
        let filter = SCContentFilter(desktopIndependentWindow: w)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * scale) & ~1
        config.height = Int(filter.contentRect.height * scale) & ~1
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = false
        config.scalesToFit = true
        // Sound: the app's own audio (the assistant's voice), not the mic.
        config.capturesAudio = sound
        config.excludesCurrentProcessAudio = false
        let out = SCRecordingOutputConfiguration()
        out.outputURL = url
        out.outputFileType = .mp4
        out.videoCodecType = .h264
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addRecordingOutput(SCRecordingOutput(configuration: out, delegate: self))
        try await stream.startCapture()
        self.stream = stream
    }

    /// Films a whole screen (several of the app's windows at once).
    @MainActor
    func start(screen: NSScreen, to url: URL, sound: Bool = false) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first else {
            throw CaptureError("No screen to film.")
        }
        // Only this app's windows: anything else on the screen (other apps, notifications)
        // stays out of the film, whatever the user is doing meanwhile.
        let mine = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, including: mine, exceptingWindows: [])
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * scale) & ~1
        config.height = Int(filter.contentRect.height * scale) & ~1
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = false
        config.capturesAudio = sound
        config.excludesCurrentProcessAudio = false
        let out = SCRecordingOutputConfiguration()
        out.outputURL = url
        out.outputFileType = .mp4
        out.videoCodecType = .h264
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addRecordingOutput(SCRecordingOutput(configuration: out, delegate: self))
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        await withCheckedContinuation { c in
            finished = c
            Task { try? await stream.stopCapture() }
        }
        self.stream = nil
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        finished?.resume()
        finished = nil
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        print("TOUR film failed: \(error.localizedDescription)")
        finished?.resume()
        finished = nil
    }
}
#endif

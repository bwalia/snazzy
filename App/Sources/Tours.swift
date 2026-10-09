#if DEBUG
import AppKit
import Broadcast
import Builder
import CaptureEngine
import Foundation
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
                      "voice-presenter", "agent-classroom"]
    /// Tours that film sound (the assistant speaking).
    static let withSound: Set<String> = ["voice-presenter"]

    static var folder: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appending(path: "Snazzy Pro/Tours", directoryHint: .isDirectory)
    }

    static func run(_ name: String, app: AppModel) async {
        print("TOUR \(name): starting")
        let savedSetup = app.capture.setup
        let savedTab = app.sidePanelTab
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

        let film = WindowFilm()
        let url = folder.appending(path: "\(name).mp4")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: url)
            try await film.start(window: window, to: url, sound: withSound.contains(name))
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
        await voice.say("Start recording")
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
final class WindowFilm: NSObject, SCRecordingOutputDelegate, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private var finished: CheckedContinuation<Void, Never>?

    @MainActor
    func start(window: NSWindow, to url: URL, sound: Bool = false) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let w = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw CaptureError("The window isn't available to capture.")
        }
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

#if DEBUG
import AppKit
import Assistant
import Builder
import CaptureEngine
import Foundation
@preconcurrency import ScreenCaptureKit
import SnazzyCore

/// App Store screenshots of the real app (debug builds only).
///
/// Launch with `-SnazzyPro.screenshots YES`: each scene is set up with demo
/// content through the app's own controllers, the window is captured with
/// ScreenCaptureKit (Snazzy Pro Dev needs Screen Recording), and the raw
/// captures plus `shots.json` (each one's headline) go to
/// ~/Movies/Snazzy Pro/Screenshots/raw. `Scripts/frame-screenshots.swift` then
/// makes the 2880×1800 framed versions. The user's conversations are hidden,
/// and demo projects, recordings and settings are cleaned up afterwards.
@MainActor
enum Screenshots {
    struct Shot: Codable {
        let file: String
        let headline: String
        let detail: String
    }

    static var folder: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appending(path: "Snazzy Pro/Screenshots/raw", directoryHint: .isDirectory)
    }

    static func run(app: AppModel) async {
        setvbuf(stdout, nil, _IONBF, 0)  // progress shows as it happens, even through a pipe
        print("SCREENSHOTS: starting")
        // Demo content only: confirmations (the live room) are approved after a moment.
        Confirm.autoApproveAfter = 1
        let savedSetup = app.capture.setup, savedTab = app.sidePanelTab, savedSettings = app.settings
        let projectsBefore = Set(app.builder.workspace.listProjects().map(\.name))
        app.sessionLoggingSuspended = true
        app.hideConversations = true
        app.capture.setInsetDevice(nil)
        guard let window = mainWindow else { print("SCREENSHOTS: no main window"); NSApp.terminate(nil); return }
        // 1440×900 points: 2880×1800 pixels on a Retina screen, the App Store's 16:10 size.
        let screen = NSScreen.screens.first { $0.backingScaleFactor >= 2 } ?? NSScreen.main ?? NSScreen.screens[0]
        let v = screen.visibleFrame
        let size = NSSize(width: min(1440, v.width), height: min(900, v.height))
        window.setFrame(NSRect(x: v.midX - size.width / 2, y: v.midY - size.height / 2, width: size.width, height: size.height), display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var shots: [Shot] = []
        var recordings: [RecordingResult] = []
        var number = 0
        func take(_ name: String, _ headline: String, _ detail: String, window w: NSWindow? = nil) async {
            await pause(1.5)
            number += 1
            let file = String(format: "%02d-%@.png", number, name)
            do {
                let image = try await capture(w ?? window)
                guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
                try png.write(to: folder.appending(path: file))
                shots.append(Shot(file: file, headline: headline, detail: detail))
                print("SCREENSHOTS: \(file) \(image.width)×\(image.height)")
            } catch {
                print("SCREENSHOTS: \(file) failed: \(error.localizedDescription)")
            }
        }

        // 1. The assistant builds a deck from one request.
        open("lesson-photosynthesis", app)
        app.sidePanelTab = .builder
        app.chat.stage(buildConversation, title: "Photosynthesis lesson")
        await pause(2)
        await take("just-say-it", "Just say it.", "Ask for a deck. The assistant writes it, slide by slide, with speaker notes.")
        app.chat.clear()

        // 2. Presenting from the notes while recording the slides.
        open("sales-demo", app)
        app.capture.selectSlidesSource()
        app.sidePanelTab = .slides
        app.slidesMode = .present
        await pause(2)
        app.builder.goToSlide(1)
        if (try? await app.capture.startRecording(countdown: 0)) != nil {
            await pause(3)
            await take("present-and-record", "Present and record in one place.", "Your slides, your speaker notes and your camera, recorded together.")
            if let r = await app.capture.stopRecording() { recordings.append(r) }
        } else {
            await take("present-and-record", "Present and record in one place.", "Your slides, your speaker notes and your camera, recorded together.")
        }

        // 3. Voice Mode running the deck.
        let voice = app.voice!
        voice.startScripted()
        app.builder.goToSlide(2)
        let saying = Task { await voice.say("Snazzy, next slide", wordsPerSecond: 1.2, volume: 0) }
        await pause(1.6)
        await take("voice-mode", "Run the show by voice.", "“Snazzy, next slide.” Commands and questions, hands-free, recognised on your Mac.")
        await saying.value
        voice.stop()

        // 4. A live classroom: students join in a browser and brainstorm.
        open("lesson-photosynthesis", app)
        app.sidePanelTab = .live
        app.live.pendingTopic = "How could our school use less energy?"
        await app.live.start()
        await pause(2)
        if let url = app.live.joinURL, let base = URL(string: "/", relativeTo: url) {
            let ideas = [("Turn off screens at the end of every lesson", "Maya"), ("Solar panels on the sports hall roof", "Leo"),
                         ("An energy monitor display in the hall", "Priya"), ("Walk or cycle to school week", "Sam")]
            for (i, idea) in ideas.enumerated() {
                try? await Tours.post("api/notes", ["text": .string(idea.0), "name": .string(idea.1)], client: "student-\(i)", base: base, code: app.live.code)
            }
            let ids = app.live.board.ranked.map(\.id)
            for (v, i) in [1, 0, 1, 2, 1, 3].enumerated() where ids.indices.contains(i) {
                try? await Tours.post("api/vote", ["id": .string(ids[i])], client: "voter-\(v)", base: base, code: app.live.code)
            }
        }
        await take("live-classroom", "Teach a live room on your Wi‑Fi.", "Students join from any browser, no app or account, and brainstorm on a shared board.")
        app.live.stop()

        // 5. Models: on this Mac, or in the cloud.
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        await pause(1.5)
        if let settings = NSApp.windows.first(where: { $0.isVisible && $0 !== window && $0.styleMask.contains(.titled) && $0.title != "Snazzy Pro" }) {
            await take("models", "On your Mac, or in the cloud.", "Apple's on-device model, Ollama or Claude. Nothing leaves your Mac unless you choose.", window: settings)
            settings.close()
        }

        if let data = try? JSONEncoder().encode(shots) { try? data.write(to: folder.appending(path: "shots.json")) }
        // Leave no trace.
        for r in recordings {
            for u in [r.composite, Chapters.url(forMovie: r.composite), r.rawFolder] { try? FileManager.default.removeItem(at: u) }
        }
        app.builder.closePopOutIfOpen()
        for p in app.builder.workspace.listProjects() where !projectsBefore.contains(p.name) && !p.name.hasPrefix("sample-") {
            try? app.builder.workspace.deleteProject(p.name)
        }
        Confirm.autoApproveAfter = nil
        app.settings = savedSettings
        app.capture.apply(savedSetup)
        app.sidePanelTab = savedTab
        app.hideConversations = false
        print("SCREENSHOTS: \(shots.count) saved in \(folder.resolvingSymlinksInPath().path). Frame them with: swift Scripts/frame-screenshots.swift")
        await pause(1)  // let the Settings window finish closing
        NSApp.terminate(nil)
        // ponytail: terminate is sometimes ignored here (main loop idle, nothing recording,
        // no sheet; cause not found). Settings are already put back and saved, so exit.
        await pause(3)
        UserDefaults.standard.synchronize()
        exit(0)
    }

    static var mainWindow: NSWindow? { NSApp.windows.first { $0.title == "Snazzy Pro" && $0.isVisible } }

    static func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    static func open(_ id: String, _ app: AppModel) {
        guard let s = SampleDeck.all.first(where: { $0.id == id }) else { return }
        _ = try? app.builder.openSample(s)
    }

    /// One window, at its full pixel size.
    static func capture(_ window: NSWindow) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let w = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw CaptureError("The window isn't available to capture. Is Screen Recording on for Snazzy Pro Dev?")
        }
        let filter = SCContentFilter(desktopIndependentWindow: w)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// What the chat shows in the first screenshot: one request, the tools the
    /// assistant used, and its answer (made up, but what a real run looks like).
    static var buildConversation: [ChatMessage] {
        let calls = [
            ToolCall(id: "s1", name: "create_project", arguments: ["name": "Photosynthesis lesson", "kind": "presentation"]),
            ToolCall(id: "s2", name: "write_file", arguments: ["project": "Photosynthesis lesson", "path": "index.html"]),
            ToolCall(id: "s3", name: "check_preview", arguments: ["project": "Photosynthesis lesson"]),
        ]
        return [
            .user("Make a five-minute lesson on photosynthesis for Year 7, with a quick quiz at the end. Add speaker notes I can read from."),
            ChatMessage(role: .assistant, parts: [.text("I'll build it as a seven-slide deck.")] + calls.map { .toolCall($0) }),
            ChatMessage(role: .tool, parts: calls.map { .toolResult(ToolResult(callID: $0.id, name: $0.name, content: "ok")) }),
            ChatMessage(role: .assistant, parts: [.text("""
                Done: **seven slides**, from what a plant needs to a three-question quiz, with speaker notes on every slide.

                Want me to add a diagram of the inside of a leaf on slide 4?
                """)]),
        ]
    }
}
#endif

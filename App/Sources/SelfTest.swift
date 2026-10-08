#if DEBUG
import Assistant
import CaptureEngine
import AppKit
import AVFoundation
import Builder
import MCP
import CoreImage
import Foundation
import ImageIO
import SnazzyCore

/// Headless checks run inside the sandboxed app:
///   SnazzyPro --self-test [--ollama-model NAME] [--anthropic-model NAME]
/// Anthropic is tested with the key in the Keychain, or ANTHROPIC_API_KEY in
/// the environment (self-test only; never persisted).
@MainActor
enum SelfTest {
    static func run(arguments: [String]) async -> Bool {
        var ok = true
        func report(_ name: String, _ passed: Bool, _ detail: String) {
            print("\(passed ? "PASS" : "FAIL")  \(name): \(detail)")
            ok = ok && passed
        }
        func value(after flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }

        if arguments.contains("--slides-record") {
            // Record a deck from its Present window while changing slides; check markers and chapters.
            let app = AppModel()
            app.sessionLoggingSuspended = true
            let savedSetup = app.capture.setup
            let tag = UUID().uuidString.prefix(6).lowercased()
            let name = "slides-test-\(tag)"
            defer {
                app.capture.apply(savedSetup)
                try? app.builder.workspace.deleteProject(name)
                app.builder.refreshProjects()
            }
            do {
                let sample = SampleDeck.all.first { $0.sector == .sales }!
                let project = try app.builder.workspace.createProject(name: name, kind: .presentation)
                for (path, content) in sample.files() { try app.builder.workspace.write(project: project.name, path: path, content: content) }
                app.builder.refreshProjects()
                app.builder.open(project.name)
                for _ in 0..<40 where !app.builder.isDeckOpen { try? await Task.sleep(for: .milliseconds(100)) }
                report("deck loaded", app.builder.deckSlides.count == sample.slides.count,
                       "\(app.builder.deckSlides.count) slides, notes on slide 1: \(app.builder.deckSlides.first?.notes.isEmpty == false)")
                app.capture.selectSlidesSource()
                try await app.capture.startRecording(countdown: 0)
                report("recording slides", app.capture.recorder.state == .recording, "stage=\(app.builder.stage.map { "\($0.size.width)x\($0.size.height) top=\($0.topInset)" } ?? "none") screen=\(app.capture.screen.frameSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? "?")")
                for i in 1...3 {
                    try? await Task.sleep(for: .seconds(2.5))
                    app.builder.nextSlide()
                    for _ in 0..<20 where app.builder.currentSlide != i { try? await Task.sleep(for: .milliseconds(50)) }
                    print("slide -> \(app.builder.currentSlide): \(app.builder.deckSlides[app.builder.currentSlide].displayTitle)")
                }
                try? await Task.sleep(for: .seconds(2.5))
                guard let result = await app.capture.stopRecording() else { report("stop", false, "no result"); return ok }
                print("MOVIE \(result.composite.path)")
                print("RAW \(result.rawFolder.path)")
                let timeline = try JSONValue.parse(Data(contentsOf: result.rawFolder.appending(path: "timeline.json")))
                let markers = timeline["markers"]?.arrayValue ?? []
                report("slide markers", markers.count == 4, markers.map { "\($0["at_seconds"]?.doubleValue ?? -1)s \($0["title"]?.stringValue ?? "")" }.joined(separator: " | "))
                let chapters = Chapters.url(forMovie: result.composite)
                let vtt = (try? String(contentsOf: chapters, encoding: .utf8)) ?? ""
                print("CHAPTERS \(chapters.path)")
                report("chapters file", vtt.components(separatedBy: " --> ").count - 1 == 4, "\(vtt.components(separatedBy: " --> ").count - 1) chapters")
                report("present window unlocked", app.builder.stage != nil, "")
                if !arguments.contains("--keep") {
                    for url in [result.composite, chapters, result.rawFolder] { try? FileManager.default.removeItem(at: url) }
                }
            } catch {
                report("slides record", false, error.localizedDescription)
            }
            return ok
        }
        if let server = value(after: "--broadcast-test") {
            // Streams the real composite + mic to a test RTMP server through the app's controller.
            let app = AppModel()
            app.sessionLoggingSuspended = true
            let b = app.broadcast!
            let savedPlatform = b.platform, savedServers = b.servers
            let savedDestinations = b.destinations, savedRecord = b.recordWhileLive
            b.recordWhileLive = arguments.contains("--record")
            let hadKey = b.savedKeys.contains(.custom)
            b.platform = .custom
            b.servers[.custom] = server
            if !hadKey { b.saveKey("testkey", for: .custom) }
            b.quality = .hd720
            b.destinations = [.custom]
            await b.start([.custom])
            report("broadcast live", b.state == .live, "\(b.stateJSON())")
            // Once a second, so a server restart mid-test shows the reconnect.
            for _ in 0..<(Int(value(after: "--seconds") ?? "6") ?? 6) {
                try? await Task.sleep(for: .seconds(1))
                print("  \(b.state) recorder: \(app.capture.recorder.state) \(b.message ?? "")")
            }
            await b.stop()
            // A recording outlives a lost stream on purpose; end it here.
            if app.capture.recorder.isActive { await app.capture.stopRecording() }
            report("broadcast stopped", b.state == .idle, "\(b.stateJSON())")
            if !hadKey { b.deleteKey(for: .custom) }
            b.platform = savedPlatform
            b.servers = savedServers
            b.destinations = savedDestinations
            b.recordWhileLive = savedRecord
            return ok
        }
        if let title = value(after: "--forget-conversations") {
            // Deletes conversations with exactly this title (left by interrupted tests).
            let app = AppModel()
            app.sessionLoggingSuspended = true
            let gone = app.chat.conversations.filter { $0.title == title }
            gone.forEach { app.chat.delete($0.id) }
            report("forget conversations", true, "removed \(gone.count)")
            return ok
        }
        if let names = value(after: "--forget-devices") {
            // Removes paired remote devices by name (test simulators).
            let app = AppModel()
            app.sessionLoggingSuspended = true
            let wanted = Set(names.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            let gone = app.remote.devices.filter { wanted.contains($0.name) }
            gone.forEach { app.remote.remove($0) }
            report("forget devices", true, "removed \(gone.count); remaining: \(app.remote.devices.map(\.name))")
            return ok
        }
        if arguments.contains("--remote-tour") {
            // A Mac for the iPhone/iPad UI tests: a demo deck presented as slides,
            // pairing open (one device per --pairings), then everything cleaned up.
            let app = AppModel()
            app.sessionLoggingSuspended = true
            let savedSetup = app.capture.setup
            let devicesBefore = Set(app.remote.devices.map(\.id))
            let conversationsBefore = Set(app.chat.conversations.map(\.id))
            var recordings: [RecordingResult] = []
            app.chat.clear()  // a fresh conversation: the assistant only knows this session
            app.capture.onRecordingSaved = { if let r = app.capture.recorder.lastResult { recordings.append(r) } }
            if let s = SampleDeck.all.first(where: { $0.id == "sales-demo" }) { _ = try? app.builder.openSample(s) }
            app.capture.setInsetDevice(nil)
            // The built-in mic, so a running Snazzy Pro keeps the usual one to itself.
            if let mic = value(after: "--mic") { _ = try? app.capture.selectMic(mic) }
            app.capture.selectSlidesSource()
            for _ in 0..<40 where !app.builder.isDeckOpen { try? await Task.sleep(for: .milliseconds(100)) }
            app.builder.openPopOut()
            let pairings = Int(value(after: "--pairings") ?? "1") ?? 1
            let end = Date().addingTimeInterval(Double(value(after: "--seconds") ?? "300") ?? 300)
            var paired = 0
            await app.remote.openPairing()
            print("PAIR \(app.remote.pairingURL?.absoluteString ?? "none")")
            var last = ""
            while Date() < end {
                try? await Task.sleep(for: .milliseconds(500))
                let count = app.remote.devices.filter { !devicesBefore.contains($0.id) }.count
                if count > paired {
                    paired = count
                    if paired < pairings {
                        await app.remote.openPairing()
                        print("PAIR \(app.remote.pairingURL?.absoluteString ?? "none")")
                    }
                }
                let now = "devices=\(app.remote.devices.map(\.name)) connected=\(app.remote.connected) recording=\(app.capture.recorder.state) slide=\(app.builder.currentSlide)"
                if now != last { print(now); last = now }
            }
            if app.capture.recorder.isActive { _ = await app.capture.stopRecording() }
            for d in app.remote.devices where !devicesBefore.contains(d.id) { app.remote.remove(d) }
            for c in app.chat.conversations where !conversationsBefore.contains(c.id) { app.chat.delete(c.id) }
            for r in recordings { for u in [r.composite, Chapters.url(forMovie: r.composite), r.rawFolder] { try? FileManager.default.removeItem(at: u) } }
            app.capture.apply(savedSetup)
            report("remote tour host", true, "paired \(paired), \(recordings.count) test recording(s) deleted")
            return ok
        }
        if arguments.contains("--remote-pair") {
            // Opens pairing for the iPhone/iPad app, reports connections, then removes test devices.
            let app = AppModel()
            app.sessionLoggingSuspended = true
            let before = Set(app.remote.devices.map(\.id))
            await app.remote.openPairing()
            print("PAIR \(app.remote.pairingURL?.absoluteString ?? "none")")
            let end = Date().addingTimeInterval(Double(value(after: "--seconds") ?? "60") ?? 60)
            var last = ""
            while Date() < end {
                try? await Task.sleep(for: .milliseconds(500))
                let now = "devices=\(app.remote.devices.map(\.name)) connected=\(app.remote.connected)"
                if now != last { print(now); last = now }
            }
            for d in app.remote.devices where !before.contains(d.id) { app.remote.remove(d) }
            report("remote pairing", !last.contains("connected=[]"), last)
            return ok
        }
        if arguments.contains("--live-deck") {
            // Ideas posted over the network become a deck via the assistant (get_brainstorm + builder tools).
            let app = AppModel()
            app.sessionLoggingSuspended = true
            app.live.pendingTopic = "What should our next class project be?"
            await app.live.start()
            guard let url = app.live.joinURL, let base = URL(string: "/", relativeTo: url) else { report("live room", false, app.live.error ?? "no URL"); return ok }
            let ideas = [("A school garden we look after all year", "Priya"), ("Build a weather station on the roof", "Tom"),
                         ("Make a podcast about local history", "Sam"), ("Grow vegetables for the school kitchen", "Ana"),
                         ("Interview grandparents about the town 50 years ago", "Leo")]
            for (i, idea) in ideas.enumerated() {
                var r = URLRequest(url: URL(string: "api/notes?k=\(app.live.code)", relativeTo: base)!)
                r.httpMethod = "POST"
                r.setValue("student-\(i)", forHTTPHeaderField: "X-Snazzy-Client")
                r.httpBody = try? JSONValue.object(["text": .string(idea.0), "name": .string(idea.1)]).encoded()
                _ = try? await URLSession.shared.data(for: r)
            }
            try? await Task.sleep(for: .milliseconds(300))
            report("ideas posted over the network", app.live.board.notes.count == ideas.count, "\(app.live.board.notes.count) ideas")
            let before = Set(app.builder.workspace.listProjects().map(\.name))
            let prompt = "Turn the ideas from the live brainstorm into a slide deck. Call get_brainstorm for the ideas, group them into themes, then build a presentation: a title slide with the topic, one slide per theme, and a closing slide with next steps. Add short speaker notes to every slide."
            _ = await toolChat(prompt: prompt, model: value(after: "--model") ?? "qwen3-coder:30b", provider: "ollama", app: app)
            let new = app.builder.workspace.listProjects().filter { !before.contains($0.name) }
            if let deck = new.first, let html = try? app.builder.workspace.read(project: deck.name, path: "index.html") {
                let titles = html.components(separatedBy: "<h1").count - 1 + html.components(separatedBy: "<h2").count - 1
                report("deck from ideas", deck.kind == .presentation && titles >= 3, "\(deck.name): \(titles) headings, notes=\(html.components(separatedBy: "class=\"notes\"").count - 1)")
                print("DECK \(app.builder.workspace.projectURL(deck.name).path)")
                if !arguments.contains("--keep") { for p in new { try? app.builder.workspace.deleteProject(p.name) } }
            } else {
                report("deck from ideas", false, "no new presentation project")
            }
            app.live.stop()
            return ok
        }
        if arguments.contains("--live-room") {
            // Runs a live room for a while so it can be tested from browsers and tools.
            let app = AppModel()
            app.sessionLoggingSuspended = true
            let seconds = Double(value(after: "--seconds") ?? "60") ?? 60
            app.live.pendingTopic = value(after: "--topic") ?? "Self-test ideas"
            if let q = value(after: "--quality") { app.live.quality = LiveController.Quality.allCases.first { "\($0)" == q } ?? .standard }
            for _ in 0..<30 where app.capture.screen.state != .live {
                app.capture.useScreen("selftest", true)
                try? await Task.sleep(for: .milliseconds(200))
            }
            await app.live.start()
            if arguments.contains("--presenter") {
                app.live.announce("Welcome! Add your ideas, then vote for your favourite two.")
                app.live.addIdea("A science fair where each class runs one experiment")
            }
            print("JOIN \(app.live.joinURL?.absoluteString ?? "none") code=\(app.live.code) error=\(app.live.error ?? "none")")
            let end = Date().addingTimeInterval(seconds)
            var lastViewers = -1, lastIdeas = -1
            while Date() < end {
                try? await Task.sleep(for: .seconds(1))
                if app.live.viewers != lastViewers || app.live.board.notes.count != lastIdeas {
                    lastViewers = app.live.viewers
                    lastIdeas = app.live.board.notes.count
                    print("viewers=\(lastViewers) ideas=\(lastIdeas)")
                }
                if Int(end.timeIntervalSinceNow) % 5 == 0 { print("encoder: \(app.live.encoderStats) screen=\(app.capture.screen.state.description) source=\(app.capture.screenSource.map { "\($0)" } ?? "nil")") }
            }
            print("BOARD\n\(app.live.board.summaryText)")
            app.live.stop()
            try? await Task.sleep(for: .milliseconds(500))
            report("live room", app.live.error == nil, (app.live.error ?? "ran \(Int(seconds)) s") + ", video restarts: \(app.live.restarts)")
            return ok
        }
        if arguments.contains("--share-roundtrip") {
            // Export a project + preset + background image, open the file, import, verify, clean up.
            let app = AppModel()
            app.sessionLoggingSuspended = true
            let tag = UUID().uuidString.prefix(6).lowercased()
            let library = app.capture.backgrounds
            var made: (projects: [String], presets: [String], images: [String]) = ([], [], [])
            func cleanUp() {
                for p in made.projects { try? app.builder.workspace.deleteProject(p) }
                for p in made.presets { _ = try? app.presets.store.delete(p) }
                for i in made.images { library.delete(i) }
                app.presets.refresh()
                app.builder.refreshProjects()
            }
            do {
                // A real JPEG for the background library.
                let ctx = CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.setFillColor(CGColor(red: 0.4, green: 0.3, blue: 1, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
                let jpg = FileManager.default.temporaryDirectory.appending(path: "share-test-\(tag).jpg")
                let dest = CGImageDestinationCreateWithURL(jpg as CFURL, "public.jpeg" as CFString, 1, nil)!
                CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
                CGImageDestinationFinalize(dest)
                let image = try library.add(jpg)
                made.images.append(image.id)

                var setup = CaptureSetup()
                setup.profiles["share-test-cam"] = DeviceProfile(crop: InsetCrop(), background: .image(id: image.id))
                let presetName = "Share test \(tag)"
                try app.presets.store.save(SettingsPreset(name: presetName, capture: setup, app: app.settings))
                made.presets.append(presetName)
                app.presets.refresh()

                let project = try app.builder.workspace.createProject(name: "share-test-\(tag)", kind: .presentation, title: "Share test")
                made.projects.append(project.name)
                let fakeToken = "ghp" + "_" + String(repeating: "A1b2", count: 9)
                try app.builder.workspace.write(project: project.name, path: "js/config.js", content: "const token = '\(fakeToken)';\n")

                let draft = SharingController.ExportDraft(project: project.name, presetNames: [presetName], includeBackgrounds: true, note: "Test note")
                let share = try app.sharing.build(draft)
                report("export contents", share.project?.files.count == 4 && share.backgrounds.count == 1 && share.presets.first?.app == nil,
                       share.contentsSummary.joined(separator: "; "))
                let warnings = app.sharing.secretWarnings(share)
                report("secret warning", warnings.count == 1 && warnings[0].hasPrefix("js/config.js"), warnings.joined())

                let file = try app.sharing.temporaryFile(for: share)
                print("file: \(file.lastPathComponent) \((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) bytes")
                app.sharing.open(file)
                report("open", app.sharing.pendingImport?.share.note == "Test note", app.sharing.message ?? "pending import ready")
                app.sharing.confirmImport()
                print("result: \(app.sharing.message ?? "")")

                let importedName = "share-test-\(tag)-2"
                made.projects.append(importedName)
                let same = try app.builder.workspace.read(project: importedName, path: "index.html") == app.builder.workspace.read(project: project.name, path: "index.html")
                report("project imported", same && app.builder.workspace.files(project: importedName).count == 4, importedName)

                let importedPreset = app.presets.store.load("\(presetName) (shared)")
                if let p = importedPreset { made.presets.append(p.name) }
                let newID: String? = { if case .image(let id)? = importedPreset?.capture?.profiles["share-test-cam"]?.background { return id }; return nil }()
                if let newID { made.images.append(newID) }
                report("preset + background imported", newID != nil && newID != image.id && library.images.contains { $0.id == newID },
                       "preset=\(importedPreset?.name ?? "missing") image=\(newID ?? "missing")")
                try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
                try? FileManager.default.removeItem(at: jpg)
            } catch {
                report("share round trip", false, error.localizedDescription)
            }
            cleanUp()
            let left = app.builder.workspace.listProjects().filter { $0.name.hasPrefix("share-test-\(tag)") }.count
                + app.presets.presets.filter { $0.name.hasPrefix("Share test \(tag)") }.count
                + library.images.filter { made.images.contains($0.id) }.count
            report("cleaned up", left == 0, "\(left) leftover items")
            return ok
        }
        if let endpoint = value(after: "--s3-test") {
            // Real S3 round trip (e.g. a local MinIO): bucket, upload, signed link, delete.
            let dest = S3Destination(endpoint: endpoint, region: "us-east-1", bucket: "snazzy-test", prefix: "shares/", pathStyle: true)
            let signer = SigV4(accessKey: value(after: "--access") ?? "", secretKey: value(after: "--secret") ?? "", region: "us-east-1")
            let session = URLSession(configuration: .ephemeral)
            do {
                var mk = URLRequest(url: URL(string: "\(endpoint)/snazzy-test")!)
                mk.httpMethod = "PUT"
                signer.sign(&mk, payloadHash: SigV4.emptyPayloadHash)
                let (_, r0) = try await session.data(for: mk)
                print("create bucket: HTTP \((r0 as? HTTPURLResponse)?.statusCode ?? 0)")
                let movie = FileManager.default.temporaryDirectory.appending(path: "share test (trimmed).mov")
                try Data(repeating: 7, count: 300_000).write(to: movie)
                let url = ShareService.objectURL(dest, key: "shares/" + movie.lastPathComponent)!
                var put = URLRequest(url: url)
                put.httpMethod = "PUT"
                put.setValue("video/quicktime", forHTTPHeaderField: "Content-Type")
                signer.sign(&put)
                let (d1, r1) = try await session.upload(for: put, fromFile: movie)
                try ShareService.check(r1, d1, "S3")
                print("upload: HTTP \((r1 as? HTTPURLResponse)?.statusCode ?? 0) \(url.lastPathComponent)")
                let link = signer.presignedURL(url: url, expires: 3600)
                let (got, r2) = try await session.data(from: link)
                print("signed link GET: HTTP \((r2 as? HTTPURLResponse)?.statusCode ?? 0), \(got.count) bytes")
                let (_, rBad) = try await session.data(from: URL(string: link.absoluteString.replacingOccurrences(of: "X-Amz-Signature=", with: "X-Amz-Signature=0"))!)
                print("tampered link: HTTP \((rBad as? HTTPURLResponse)?.statusCode ?? 0)")
                var del = URLRequest(url: url)
                del.httpMethod = "DELETE"
                signer.sign(&del, payloadHash: SigV4.emptyPayloadHash)
                let (_, r3) = try await session.data(for: del)
                let (_, r4) = try await session.data(from: link)
                print("delete: HTTP \((r3 as? HTTPURLResponse)?.statusCode ?? 0); link after delete: HTTP \((r4 as? HTTPURLResponse)?.statusCode ?? 0)")
                let ok = got.count == 300_000 && (rBad as? HTTPURLResponse)?.statusCode == 403 && (r4 as? HTTPURLResponse)?.statusCode == 404
                SelfTest.report(ok, "S3 share round trip")
                return ok
            } catch {
                SelfTest.report(false, "S3: \(error.localizedDescription)")
                return false
            }
        }
        if let word = value(after: "--zoom-test") {
            let app = AppModel()
            app.sessionLoggingSuspended = true
            if case .display? = app.capture.setup.source {} else { _ = try? app.capture.selectDisplay("main") }
            app.capture.useScreen("self-test", true)
            await app.capture.updateScreenFeed()
            for _ in 0..<40 where app.capture.screen.receiver.latest == nil { try? await Task.sleep(for: .milliseconds(100)) }
            do {
                let found = try await app.capture.zoom(toText: word, hold: 0)
                try? await Task.sleep(for: .milliseconds(600))
                let z = app.capture.screenZoom
                print("found: \(found.prefix(40))  zoom: \(z.map { String(format: "x %.2f y %.2f w %.2f h %.2f", $0.minX, $0.minY, $0.width, $0.height) } ?? "none")")
                let spec = app.capture.compositeSpec
                app.capture.animateZoom(to: nil)
                try? await Task.sleep(for: .milliseconds(600))
                let ok = z != nil && spec.screenZoom == z && app.capture.screenZoom == nil
                SelfTest.report(ok, "zoom in and back out (composite spec follows)")
                app.capture.useScreen("self-test", false)
                return ok
            } catch {
                SelfTest.report(false, "zoom: \(error.localizedDescription)")
                return false
            }
        }
        if arguments.contains("--probe-dev") {
            // What the sandbox allows for developer features.
            for (path, args) in [("/usr/bin/git", ["--version"]), ("/opt/homebrew/bin/gh", ["--version"])] {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                let out = Pipe(); p.standardOutput = out; p.standardError = out
                do {
                    try p.run(); p.waitUntilExit()
                    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    print("exec \(path): status \(p.terminationStatus) \(text.prefix(120).replacingOccurrences(of: "\n", with: " "))")
                } catch {
                    print("exec \(path): \(error.localizedDescription)")
                }
            }
            print("AXIsProcessTrusted: \(AXIsProcessTrusted())")
            return true
        }
        if arguments.contains("--mcp-server") {
            // Snazzy Pro's own MCP server, exercised by the MCP client over HTTP.
            let app = AppModel()
            app.sessionLoggingSuspended = true
            app.mcp.startServer(port: 47999)
            defer { app.mcp.stopServer() }
            do {
                let client = MCPClient(url: URL(string: "http://127.0.0.1:47999/mcp")!, headers: ["Authorization": "Bearer \(app.mcp.serverToken)"])
                try await client.connect()
                let tools = try await client.listTools()
                print("era: \(await client.era.map { "\($0)" } ?? "?") server: \(await client.serverName ?? "?") tools: \(tools.count)")
                print("read-only: \(tools.filter(\.readOnly).map(\.name).joined(separator: ", "))")
                let state = try await client.callTool("get_project_state", arguments: [:])
                print("get_project_state: \(state.text.prefix(120))")
                let resource = try await client.readResource("snazzy://settings")
                let bad = MCPClient(url: URL(string: "http://127.0.0.1:47999/mcp")!, headers: ["Authorization": "Bearer wrong"])
                var refused = false
                do { try await bad.connect() } catch { refused = true }
                let ok = tools.count > 20 && !state.isError && resource.contains("models") && refused
                SelfTest.report(ok, "Snazzy Pro MCP server: \(tools.count) tools, wrong token refused=\(refused)")
                return ok
            } catch {
                SelfTest.report(false, "MCP server: \(error.localizedDescription)")
                return false
            }
        }
        if let url = value(after: "--mcp-url"), let prompt = value(after: "--chat") {
            // Chat with a temporary external MCP server connected (not saved).
            let app = AppModel()
            app.sessionLoggingSuspended = true
            let id = app.mcp.addTemporary(name: value(after: "--mcp-name") ?? "Docs", url: url)
            for _ in 0..<60 { if case .connected = app.mcp.status[id] { break }; try? await Task.sleep(for: .milliseconds(250)) }
            print("MCP: \(app.mcp.status[id]?.label ?? "?")")
            return await toolChat(prompt: prompt, model: value(after: "--model") ?? "gpt-oss:120b", provider: value(after: "--provider") ?? "ollama", app: app)
        }
        if arguments.contains("--builder-errors") {
            // A throwaway workspace with a page that throws: the report must carry the real message.
            let root = FileManager.default.temporaryDirectory.appending(path: "builder-test-\(UUID().uuidString.prefix(6))")
            defer { try? FileManager.default.removeItem(at: root) }
            let builder = BuilderController(workspace: Workspace(root: root))
            let window = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = builder.webView
            window.orderFrontRegardless()
            do {
                try builder.createProject(name: "errors", kind: .prototype, title: "Errors")
                let report = try await builder.writeFile(project: nil, path: "app.js",
                                                         content: "document.title = 'loaded';\nmissingFunction();\n")
                let errors = report["console_errors"]?.arrayValue?.compactMap(\.stringValue) ?? []
                let title = report["page"]?["title"]?.stringValue ?? ""
                print("errors: \(errors)  title: \(title)")
                let ok = errors.contains { $0.contains("missingFunction") && $0.contains("app.js") }
                SelfTest.report(ok, "builder reports readable script errors over \(ProjectSchemeHandler.scheme)://")
                return ok
            } catch {
                SelfTest.report(false, "builder errors: \(error.localizedDescription)")
                return false
            }
        }
        if let name = value(after: "--preset-roundtrip") {
            // Save current settings under `name`, load it back, compare, then delete it.
            let app = AppModel()
            app.sessionLoggingSuspended = true
            let before = (app.capture.setup, app.settings)
            do {
                try app.presets.save(name: name, notes: "self-test")
                let loaded = try app.presets.load(String(name.prefix(6)))
                let same = app.capture.setup == before.0 && app.settings == before.1 && loaded.name == name
                SelfTest.report(same, "preset roundtrip \(loaded.name): settings unchanged=\(same)")
                try app.presets.delete(name)
                SelfTest.report(!app.presets.presets.contains { $0.name == name }, "preset deleted")
                UserDefaults.standard.removeObject(forKey: "SnazzyPro.activePreset")
                return same
            } catch {
                SelfTest.report(false, "preset roundtrip: \(error.localizedDescription)")
                return false
            }
        }
        if let prompt = value(after: "--chat") {
            return await toolChat(prompt: prompt, model: value(after: "--model") ?? "gpt-oss:120b", provider: value(after: "--provider") ?? "ollama")
        }
        if let seconds = value(after: "--record").flatMap(Double.init) {
            return await recordTest(seconds: seconds, display: value(after: "--display"), camera: value(after: "--feed"), pauseAt: value(after: "--pause-at").flatMap(Double.init))
        }
        if arguments.contains("--composite") {
            return await compositeSnapshot(display: value(after: "--display"), camera: value(after: "--feed"), out: value(after: "--out") ?? "composite",
                                           background: value(after: "--background"))
        }
        if let name = value(after: "--builder-snapshot") {
            return await builderSnapshot(project: name, out: value(after: "--out") ?? "snapshot", slides: Int(value(after: "--slides") ?? "") ?? 1)
        }
        if arguments.contains("--devices") {
            return await devices(arguments: arguments, report: report) && ok
        }

        // Keychain round trip in the sandbox.
        let keychain = KeychainStore(service: "com.snazzy.pro.selftest")
        do {
            try keychain.setSecret("selftest-value", for: "probe")
            let read = try keychain.secret(for: "probe")
            try keychain.deleteSecret(for: "probe")
            let gone = try keychain.secret(for: "probe") == nil
            report("keychain", read == "selftest-value" && gone, "write/read/delete")
        } catch {
            report("keychain", false, error.localizedDescription)
        }

        let app = AppModel()
        app.sessionLoggingSuspended = true
        let registry = app.makeToolRegistry(for: app.activeSelection.provider)
        let prompt = "Call the get_project_state tool, then reply with only the value of build_phase."
        let phase = app.projectState()["build_phase"]?.intValue.map(String.init) ?? "?"

        // Ollama: list models, then a streamed chat with a tool call.
        do {
            let ollama = try OllamaProvider(baseURL: app.settings.ollamaBaseURL)
            let models = try await ollama.listModels()
            report("ollama.tags", !models.isEmpty, models.map(\.id).joined(separator: ", "))
            if let name = value(after: "--ollama-model") ?? models.first(where: { $0.supportsTools == true })?.id {
                let result = try await chat(ollama, model: name, registry: registry, prompt: prompt, effort: nil)
                report("ollama.chat(\(name))", result.calledTool && result.text.contains(phase), result.summary)
            }
        } catch {
            report("ollama", false, error.localizedDescription)
        }

        // Anthropic.
        let key = (try? keychain.secret(for: "anthropic")).flatMap { $0 }
            ?? (try? KeychainStore().secret(for: "anthropic")).flatMap { $0 }
            ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
        if let key, !key.isEmpty {
            do {
                let anthropic = try AnthropicProvider(apiKey: key, baseURL: app.settings.anthropicBaseURL)
                let name = value(after: "--anthropic-model") ?? "claude-opus-5-5"
                let result = try await chat(anthropic, model: name, registry: registry, prompt: prompt, effort: "low")
                report("anthropic.chat(\(name))", result.calledTool && result.text.contains(phase), result.summary)
            } catch {
                report("anthropic", false, error.localizedDescription)
            }
        } else {
            print("SKIP  anthropic: no key in Keychain or ANTHROPIC_API_KEY")
        }
        return ok
    }

    /// `--devices [--feed NAME] [--seconds N]`: list devices (waiting for an iOS
    /// device), then run a feed and report frames, size and stalls.
    static func devices(arguments: [String], report: (String, Bool, String) -> Void) async -> Bool {
        func value(after flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        let catalog = DeviceCatalog()
        await catalog.refresh()
        let start = Date()
        let ios = await catalog.waitForIOSDevice(matching: value(after: "--feed") ?? "", timeout: 40)
        print(String(format: "iOS device wait: %.1fs", Date().timeIntervalSince(start)))
        print("Microphones: " + catalog.microphones.map { $0.isDefault ? "\($0.name) [default]" : $0.name }.joined(separator: ", "))
        print("Cameras:     " + catalog.cameras.map { "\($0.name) (\($0.transport))" }.joined(separator: ", "))
        print("iOS devices: " + catalog.iosDevices.map(\.name).joined(separator: ", "))
        print("Displays:    " + catalog.displays.map { "\($0.name) \($0.width)x\($0.height)\($0.isMain ? " main" : "")" }.joined(separator: ", "))
        print("Windows:     \(catalog.screenRecordingAllowed ? "\(catalog.windows.count) listed" : "no screen-recording permission")")
        report("devices.microphones", !catalog.microphones.isEmpty, "\(catalog.microphones.count)")
        report("devices.ios", ios != nil, ios?.name ?? "none appeared within 40s")

        let query = value(after: "--feed")
        let target = query.flatMap { q in DeviceMatcher.match(q, in: catalog.iosDevices + catalog.cameras, id: \.id, name: \.name) } ?? ios
        guard let target else { return false }
        let seconds = Double(value(after: "--seconds") ?? "") ?? 6
        let feed = CameraFeed(device: target)
        feed.start()
        let begin = Date()
        while Date().timeIntervalSince(begin) < seconds + 20 {
            try? await Task.sleep(for: .milliseconds(250))
            if feed.state == .live, feed.receiver.snapshot.frames > 0 { break }
            if case .failed = feed.state { break }
        }
        let liveAt = Date().timeIntervalSince(begin)
        let framesBefore = feed.receiver.snapshot.frames
        try? await Task.sleep(for: .seconds(seconds))
        let stats = feed.receiver.snapshot
        let size = stats.size.map { "\(Int($0.width))x\(Int($0.height))" } ?? "?"
        let profile = DeviceProfile.defaults(for: target.kind)
        let content = stats.size.map { InsetGeometry.contentSize(raw: $0, profile: profile) }
        var rendered = "not rendered"
        if let frame = feed.receiver.latest {
            let image = FrameTransform.apply(frame.image, profile: profile)
            if let cg = CIContext().createCGImage(image, from: image.extent) {
                rendered = "inset image \(cg.width)x\(cg.height)"
                if let out = value(after: "--save") {
                    let url = URL(fileURLWithPath: out)
                    if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                        CGImageDestinationAddImage(dest, cg, nil)
                        CGImageDestinationFinalize(dest)
                        rendered += ", saved"
                    }
                }
            }
        }
        report("feed(\(target.name))", stats.frames > framesBefore || stats.frames > 0,
               String(format: "state=%@ live after %.1fs, frames=%d (%.1f fps), dropped=%d, raw=%@, content=%@, %@",
                      feed.state.description, liveAt, stats.frames, Double(stats.frames - framesBefore) / seconds,
                      stats.dropped, size, content.map { "\(Int($0.width))x\(Int($0.height))" } ?? "?", rendered))
        feed.stop()
        for entry in Diagnostics.shared.entries { print("  diag [\(entry.level.rawValue)] \(entry.message)") }
        return true
    }

    /// `--chat PROMPT [--provider ollama|anthropic] [--model NAME]`: run one
    /// turn with every app tool and print the tool calls.
    static func toolChat(prompt: String, model: String, provider: String, arguments: [String] = CommandLine.arguments, app existing: AppModel? = nil) async -> Bool {
        func value(after flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        await Task.detached { await MainActor.run { print("main actor on main thread: \(pthread_main_np() == 1)") } }.value
        let app = existing ?? AppModel()
        app.sessionLoggingSuspended = true
        // --dev-all: turn every developer feature on for this run, then restore.
        let savedDev = app.developer.settings
        if arguments.contains("--dev-all") {
            app.developer.settings.pullRequestDemosEnabled = true
            app.developer.settings.screenReadingEnabled = true
            app.developer.settings.zoomEnabled = true
        }
        defer { app.developer.settings = savedDev }
        await app.capture.catalog.refresh()
        do {
            let kind: ProviderKind = provider == "anthropic" ? .anthropic : provider == "apple" ? .appleOnDevice : .ollama
            let p = try app.makeProvider(kind)
            let runner = ConversationRunner(provider: p, registry: app.makeToolRegistry(for: kind), model: kind == .appleOnDevice ? ProviderKind.appleModelID : model,
                                            system: kind == .appleOnDevice ? ChatSession.compactSystemPrompt : ChatSession.systemPrompt, maxTokens: 8000,
                                            effort: provider == "anthropic" ? "low" : nil)
            for try await event in runner.run(history: [.user(prompt)]) {
                switch event {
                case .toolFinished(let call, let result):
                    print("TOOL \(call.name) \(call.arguments.compactString) -> \(result.isError ? "ERROR " : "")\(result.content.prefix(300))")
                case .assistantMessage(let m, _, _) where !m.text.isEmpty:
                    print("ASSISTANT: \(m.text)")
                case .needsUser(let m):
                    print("NEEDS USER: \(m)")
                default: break
                }
            }
            print("STATE \(app.capture.stateJSON().compactString)")
            if let hold = value(after: "--hold").flatMap(Double.init) {
                print("HOLD previews=\(app.capture.excludedWindowNumbers)")
                try? await Task.sleep(for: .seconds(hold))
            }
            app.capture.closePreview()
            return true
        } catch {
            print("FAIL chat: \(error.localizedDescription)")
            return false
        }
    }

    /// Opens a builder project off-screen, reports console errors and saves
    /// a PNG per slide (`<out>-<n>.png` in the app's temp folder).
    static func builderSnapshot(project: String, out: String, slides: Int) async -> Bool {
        let builder = BuilderController()
        let window = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: 1280, height: 720), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = builder.webView
        window.orderFrontRegardless()
        do {
            _ = try builder.requireProject(project)
            let report = try await builder.reloadAndReport()
            print("REPORT \(report.compactString.prefix(600))")
            for i in 0..<slides {
                _ = try await builder.showSlide(i)
                try await Task.sleep(for: .milliseconds(400))
                if let png = await builder.snapshot() {
                    let url = FileManager.default.temporaryDirectory.appending(path: "\(out)-\(i).png")
                    try png.write(to: url)
                    print("SNAPSHOT \(url.path)")
                }
            }
            return true
        } catch {
            print("FAIL \(error.localizedDescription)")
            return false
        }
    }

    /// Captures a display (default: main) with ScreenCaptureKit plus a camera
    /// inset, composites one frame and saves it as `<out>.png` in the app's temp folder.
    static func compositeSnapshot(display: String?, camera: String?, out: String, background: String? = nil) async -> Bool {
        let catalog = DeviceCatalog()
        await catalog.refresh()
        print("screen recording allowed: \(CGPreflightScreenCaptureAccess())")
        let target = display.flatMap { q in DeviceMatcher.match(q, in: catalog.displays, id: { String($0.id) }, name: \.name) }
            ?? catalog.displays.first(where: \.isMain)
        guard let target else { print("FAIL no display"); return false }
        let screen = ScreenFeed()
        await screen.start(.display(target.id))
        print("screen: \(screen.state.description) \(screen.frameSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? "")")

        var feed: CameraFeed?
        let device = camera.flatMap { q in DeviceMatcher.match(q, in: catalog.iosDevices + catalog.cameras, id: \.id, name: \.name) }
            ?? catalog.iosDevices.first
        if let device {
            feed = CameraFeed(device: device)
            feed?.start()
            if let background {
                let library = BackgroundLibrary()
                if let bg = library.resolve(background, strength: nil) {
                    feed?.receiver.effect.configure(bg, image: library.image(for: bg))
                    print("background: \(library.describe(bg))")
                }
            }
        }
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(250))
            if screen.receiver.frameCount > 0, feed == nil || feed?.receiver.latest != nil { break }
        }
        try? await Task.sleep(for: .seconds(background == nil ? 1 : 3))  // segmentation needs a moment
        var inset = InsetLayout()
        if background != nil { inset.size = 0.5 }  // big enough to judge the edges
        let spec = CompositeSpec(layout: inset, profile: device.map { DeviceProfile.defaults(for: $0.kind) } ?? .defaults(for: .camera))
        let image = Compositor.compose(screen: screen.receiver.latest?.image, camera: feed?.receiver.latestImage, spec: spec)
        let ok = screen.receiver.frameCount > 0
        report(ok, "composite: screen frames=\(screen.receiver.frameCount) camera=\(device?.name ?? "none") frames=\(feed?.receiver.snapshot.frames ?? 0)")
        if let cg = CIContext().createCGImage(image, from: image.extent) {
            // A full path (e.g. in ~/Movies) lets tools outside the sandbox read it.
            let url = out.hasPrefix("/") ? URL(fileURLWithPath: out) : FileManager.default.temporaryDirectory.appending(path: "\(out).png")
            if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, cg, nil)
                CGImageDestinationFinalize(dest)
                print("SNAPSHOT \(url.path)")
            }
        }
        feed?.stop()
        await screen.stop()
        return ok
    }

    /// Records the main display (or --display), the first iOS device (or
    /// --feed) and the default mic into a temp folder, then inspects the files.
    static func recordTest(seconds: Double, display: String?, camera: String?, pauseAt: Double?) async -> Bool {
        let catalog = DeviceCatalog()
        await catalog.refresh()
        guard let target = display.flatMap({ q in DeviceMatcher.match(q, in: catalog.displays, id: { String($0.id) }, name: \.name) })
            ?? catalog.displays.first(where: \.isMain) else { print("FAIL no display"); return false }
        let screen = ScreenFeed()
        await screen.start(.display(target.id))
        var feed: CameraFeed?
        if let device = camera.flatMap({ q in DeviceMatcher.match(q, in: catalog.iosDevices + catalog.cameras, id: \.id, name: \.name) }) ?? catalog.iosDevices.first {
            feed = CameraFeed(device: device)
            feed?.start()
            for _ in 0..<40 where feed?.receiver.latest == nil { try? await Task.sleep(for: .milliseconds(250)) }
        }
        let folder = FileManager.default.temporaryDirectory.appending(path: "record-test-\(UUID().uuidString.prefix(6))")
        let recorder = Recorder()
        let spec = CompositeSpec(layout: InsetLayout(), profile: feed.map { DeviceProfile.defaults(for: $0.device.kind) } ?? .defaults(for: .camera))
        do {
            try await recorder.start(screen: screen, camera: feed, micID: nil, spec: spec, countdown: 0, folder: folder)
        } catch {
            print("FAIL start: \(error.localizedDescription)")
            return false
        }
        if let pauseAt, pauseAt < seconds {
            try? await Task.sleep(for: .seconds(pauseAt))
            recorder.pause()
            try? await Task.sleep(for: .seconds(2))
            recorder.resume()
            try? await Task.sleep(for: .seconds(seconds - pauseAt))
        } else {
            try? await Task.sleep(for: .seconds(seconds))
        }
        guard let result = await recorder.stop() else { print("FAIL stop: \(recorder.state)"); return false }
        feed?.stop()
        await screen.stop()
        print(String(format: "recorded %.2fs, dropped %d, warning: %@", result.duration, result.droppedFrames, recorder.warning ?? "none"))
        var ok = abs(result.duration - seconds) < 0.5
        for url in [result.composite] + ((try? FileManager.default.contentsOfDirectory(at: result.rawFolder, includingPropertiesForKeys: nil)) ?? []).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if url.pathExtension == "json" {
                print("  \(url.lastPathComponent): \(String(data: (try? Data(contentsOf: url)) ?? Data(), encoding: .utf8)?.prefix(200) ?? "")")
                continue
            }
            let asset = AVURLAsset(url: url)
            let duration = (try? await asset.load(.duration))?.seconds ?? 0
            var parts: [String] = []
            for track in (try? await asset.load(.tracks)) ?? [] {
                let type = track.mediaType.rawValue
                let size = (try? await track.load(.naturalSize)) ?? .zero
                let rate = (try? await track.load(.nominalFrameRate)) ?? 0
                let range = (try? await track.load(.timeRange)) ?? .zero
                parts.append(String(format: "%@ %dx%d %.1ffps start %.3f dur %.2f", type, Int(size.width), Int(size.height), rate, range.start.seconds, range.duration.seconds))
            }
            let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0) / 1024
            print(String(format: "  %@ %.2fs %d KB: %@", url.lastPathComponent, duration, bytes, parts.joined(separator: " | ")))
            if url == result.composite { ok = ok && parts.count == 2 }
        }
        print("FILES \(folder.path)")
        report(ok, "recording")
        return ok
    }

    static func report(_ ok: Bool, _ detail: String) { print("\(ok ? "PASS" : "FAIL")  \(detail)") }

    struct ChatResult {
        var text = ""
        var calledTool = false
        var deltas = 0
        var usage = TokenUsage()
        var summary: String {
            "reply=\(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80).debugDescription) toolCalled=\(calledTool) "
                + "deltas=\(deltas) tokens=\(usage.inputTokens)/\(usage.outputTokens)"
        }
    }

    static func chat(
        _ provider: any ModelProvider, model: String, registry: ToolRegistry, prompt: String, effort: String?
    ) async throws -> ChatResult {
        let runner = ConversationRunner(
            provider: provider, registry: registry, model: model, system: ChatSession.systemPrompt,
            maxTokens: 4000, effort: effort)
        var result = ChatResult()
        var finalText = ""
        for try await event in runner.run(history: [.user(prompt)]) {
            switch event {
            case .textDelta: result.deltas += 1
            case .assistantMessage(let m, _, _): if !m.text.isEmpty { finalText = m.text }
            case .toolFinished(let call, let r): result.calledTool = result.calledTool || (call.name == "get_project_state" && !r.isError)
            case .usage(let u): result.usage = result.usage + u
            default: break
            }
        }
        result.text = finalText
        return result
    }
}
#endif

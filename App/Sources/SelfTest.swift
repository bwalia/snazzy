#if DEBUG
import Assistant
import CaptureEngine
import AppKit
import AVFoundation
import Builder
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
        let registry = app.makeToolRegistry()
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
    static func toolChat(prompt: String, model: String, provider: String, arguments: [String] = CommandLine.arguments) async -> Bool {
        func value(after flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        await Task.detached { await MainActor.run { print("main actor on main thread: \(pthread_main_np() == 1)") } }.value
        let app = AppModel()
        app.sessionLoggingSuspended = true
        await app.capture.catalog.refresh()
        do {
            let kind: ProviderKind = provider == "anthropic" ? .anthropic : provider == "apple" ? .appleOnDevice : .ollama
            let p = try app.makeProvider(kind)
            let runner = ConversationRunner(provider: p, registry: app.makeToolRegistry(), model: kind == .appleOnDevice ? ProviderKind.appleModelID : model,
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

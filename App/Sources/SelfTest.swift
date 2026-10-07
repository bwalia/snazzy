import Assistant
import CaptureEngine
import AppKit
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

        if let prompt = value(after: "--chat") {
            return await toolChat(prompt: prompt, model: value(after: "--model") ?? "gpt-oss:120b", provider: value(after: "--provider") ?? "ollama")
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
            let p: any ModelProvider = provider == "anthropic"
                ? try app.makeProvider(.anthropic) : try app.makeProvider(.ollama)
            let runner = ConversationRunner(provider: p, registry: app.makeToolRegistry(), model: model,
                                            system: ChatSession.systemPrompt, maxTokens: 8000,
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

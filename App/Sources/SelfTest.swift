import Assistant
import Foundation
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
        let registry = app.makeToolRegistry()
        let prompt = "Call the get_project_state tool, then reply with only the value of build_phase."

        // Ollama: list models, then a streamed chat with a tool call.
        do {
            let ollama = try OllamaProvider(baseURL: app.settings.ollamaBaseURL)
            let models = try await ollama.listModels()
            report("ollama.tags", !models.isEmpty, models.map(\.id).joined(separator: ", "))
            if let name = value(after: "--ollama-model") ?? models.first(where: { $0.supportsTools == true })?.id {
                let result = try await chat(ollama, model: name, registry: registry, prompt: prompt, effort: nil)
                report("ollama.chat(\(name))", result.calledTool && result.text.contains("1"), result.summary)
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
                report("anthropic.chat(\(name))", result.calledTool && result.text.contains("1"), result.summary)
            } catch {
                report("anthropic", false, error.localizedDescription)
            }
        } else {
            print("SKIP  anthropic: no key in Keychain or ANTHROPIC_API_KEY")
        }
        return ok
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

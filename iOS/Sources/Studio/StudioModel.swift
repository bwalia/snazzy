import Assistant
import Builder
import Foundation
import Observation
import SnazzyCore

/// The iPad/iPhone studio: chat with the assistant, which builds slide decks
/// and prototypes in a workspace on the device, shown in a live preview.
@MainActor @Observable
final class StudioModel {
    struct Item: Identifiable, Equatable {
        enum Kind: Equatable { case user, assistant, tool(String), note }
        let id = UUID()
        var kind: Kind
        var text: String
    }

    private(set) var items: [Item] = []
    private(set) var isRunning = false
    var draft = ""

    /// Which AI to use (saved).
    var provider: ProviderKind {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: "studio.provider") }
    }
    var models: [ProviderKind: String] {
        didSet { UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: models.map { ($0.key.rawValue, $0.value) }), forKey: "studio.models") }
    }
    var ollamaURL: String {
        didSet { UserDefaults.standard.set(ollamaURL, forKey: "studio.ollamaURL") }
    }
    private(set) var hasAnthropicKey = false

    let preview: StudioPreview
    let workspace: Workspace
    @ObservationIgnored private let secrets: any SecretStore = KeychainStore()
    @ObservationIgnored private var history: [ChatMessage] = []
    @ObservationIgnored private var task: Task<Void, Never>?

    static let defaultModels: [ProviderKind: String] = [
        .appleOnDevice: ProviderKind.appleModelID,
        .anthropic: "claude-opus-5-5",
        .ollama: "qwen3-coder:30b",
    ]

    init() {
        let d = UserDefaults.standard
        workspace = Workspace(root: Workspace.defaultRoot())
        preview = StudioPreview(workspace: workspace)
        let saved = ProviderKind(rawValue: d.string(forKey: "studio.provider") ?? "")
        provider = saved ?? (AppleOnDeviceProvider.isAvailable ? .appleOnDevice : .anthropic)
        let raw = d.dictionary(forKey: "studio.models") as? [String: String] ?? [:]
        models = Self.defaultModels.merging(Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in ProviderKind(rawValue: k).map { ($0, v) } })) { $1 }
        ollamaURL = d.string(forKey: "studio.ollamaURL") ?? "http://192.168.1.10:11434"
        hasAnthropicKey = ((try? secrets.secret(for: "anthropic")) ?? nil)?.isEmpty == false
        #if DEBUG
        // Tests: `simctl launch … -studioPrompt "Make a deck about…"`
        if let prompt = d.string(forKey: "studioPrompt") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                self.draft = prompt
                self.send()
            }
        }
        #endif
    }

    var model: String { models[provider] ?? Self.defaultModels[provider] ?? "" }

    /// Why the chosen AI can't be used right now.
    var unavailableReason: String? {
        switch provider {
        case .appleOnDevice: AppleOnDeviceProvider.unavailableReason
        case .anthropic: hasAnthropicKey ? nil : "Add your Anthropic API key in AI settings."
        case .ollama: ollamaURL.isEmpty ? "Set your Ollama address in AI settings." : nil
        }
    }

    func saveAnthropicKey(_ key: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.isEmpty { try? secrets.deleteSecret(for: "anthropic") } else { try? secrets.setSecret(k, for: "anthropic") }
        hasAnthropicKey = !k.isEmpty
    }

    // MARK: Chat

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        draft = ""
        if let reason = unavailableReason {
            items.append(Item(kind: .note, text: reason + " Without AI you can still make decks in the slide editor (Projects › New Deck), open sample decks and present."))
            return
        }
        items.append(Item(kind: .user, text: text))
        history.append(.user(text))
        let provider: any ModelProvider
        do {
            provider = try makeProvider()
        } catch {
            items.append(Item(kind: .note, text: error.localizedDescription))
            return
        }
        let runner = ConversationRunner(provider: provider, registry: StudioTools.registry(self), model: model,
                                        system: Self.systemPrompt, maxTokens: self.provider == .appleOnDevice ? 4_000 : 16_000)
        isRunning = true
        var current: UUID?
        task = Task {
            do {
                for try await event in runner.run(history: history) {
                    switch event {
                    case .textDelta(let t):
                        if let id = current, let i = items.firstIndex(where: { $0.id == id }) {
                            items[i].text += t
                        } else {
                            let item = Item(kind: .assistant, text: t)
                            current = item.id
                            items.append(item)
                        }
                    case .toolRunning(let call):
                        current = nil
                        items.append(Item(kind: .tool(call.name), text: Self.summary(call)))
                    case .assistantMessage(let message, _, _):
                        history.append(message)
                        // A tool call written as text: show the cleaned reply.
                        if let id = current, let i = items.firstIndex(where: { $0.id == id }), items[i].text.contains("<function=") || items[i].text.contains("<tool_call>") {
                            items[i].text = message.text
                        }
                        current = nil
                    case .toolResults(let message):
                        history.append(message)
                    case .needsUser(let text):
                        items.append(Item(kind: .note, text: text))
                    default:
                        break
                    }
                }
            } catch is CancellationError {
            } catch {
                items.append(Item(kind: .note, text: error.localizedDescription))
            }
            isRunning = false
        }
    }

    func stop() { task?.cancel() }

    func newConversation() {
        stop()
        history = []
        items = []
    }

    private func makeProvider() throws -> any ModelProvider {
        switch provider {
        case .anthropic: try AnthropicProvider(apiKey: (try secrets.secret(for: "anthropic")) ?? "")
        case .ollama: try OllamaProvider(baseURL: ollamaURL)
        case .appleOnDevice: try AppleOnDeviceProvider()
        }
    }

    static func summary(_ call: ToolCall) -> String {
        switch call.name {
        case "create_project": "Created project \(call.arguments["name"]?.stringValue ?? "")"
        case "write_file": "Wrote \(call.arguments["path"]?.stringValue ?? "file")"
        case "read_file": "Read \(call.arguments["path"]?.stringValue ?? "file")"
        case "open_sample_deck": "Opened sample \(call.arguments["id"]?.stringValue ?? "")"
        case "show_slide": "Showed slide \((call.arguments["index"]?.intValue ?? 0) + 1)"
        default: call.name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static let systemPrompt = """
        You are the assistant inside Snazzy Pro on iPad and iPhone. You help the user plan talks and build HTML slide decks and quick app prototypes, \
        which appear in the preview next to the chat. Change things only through your tools; never claim to have done what a tool didn't do. \
        For a presentation: create_project with kind "presentation", then write index.html with one <section class="slide"> per slide \
        (layouts: class "slide title", "slide layout-bullets", "layout-stats", "layout-columns", "layout-quote", "layout-steps"), \
        and speaker notes in <aside class="notes"> inside each slide. Keep the provided deck.css and deck.js. Then call check_preview and fix any errors. \
        Be brief in chat: say what you made and offer one next step.
        """
}

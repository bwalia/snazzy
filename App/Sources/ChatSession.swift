import AppKit
import Assistant
import Foundation
import Observation
import SnazzyCore

struct TranscriptItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case user
        case assistant
        case tool(name: String)
        case notice(isError: Bool)
    }

    enum ToolState: Equatable { case running, succeeded, failed }

    let id = UUID()
    var kind: Kind
    var text = ""
    var thinking = ""
    var detail = ""
    var isStreaming = false
    var toolState: ToolState = .running
    var model: String?
}

/// The chat: a display transcript plus the provider-neutral history the
/// assistant sees. History is append-only.
@MainActor @Observable
final class ChatSession {
    private(set) var transcript: [TranscriptItem] = []
    private(set) var history: [ChatMessage] = []
    private(set) var isRunning = false
    /// The provider of the request in flight (drives the cloud indicator).
    private(set) var activeProvider: ProviderKind?
    private(set) var sessionUsage = TokenUsage()
    private(set) var lastUsage: TokenUsage?

    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var currentAssistant: UUID?

    init(app: AppModel) { self.app = app }

    static let systemPrompt = """
        You are the assistant inside Snazzy Pro, a macOS app for making video presentations. \
        You help the user plan and write presentations, set up cameras, mics and screens, record, and export video. \
        You can only change the app through the tools you are given; never claim to have done something a tool did not do. \
        If a capability has no tool yet, say so plainly and explain what the user can do instead. \
        Keep replies short and practical; use Markdown lists for outlines.
        """

    /// Sends a message. Returns false (and posts a notice) if it can't be sent.
    @discardableResult
    func send(_ input: String) -> Bool {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return false }

        let selection = app.activeSelection
        if let reason = app.unavailableReason(selection.provider) {
            notice(reason, isError: true)
            return false
        }
        let provider: any ModelProvider
        do {
            provider = try app.makeProvider(selection.provider)
        } catch {
            notice(error.localizedDescription, isError: true)
            return false
        }

        history.append(.user(text))
        transcript.append(TranscriptItem(kind: .user, text: text))

        let runner = ConversationRunner(
            provider: provider, registry: app.makeToolRegistry(), model: selection.model,
            system: Self.systemPrompt, maxTokens: app.settings.maxOutputTokens,
            effort: selection.provider == .anthropic ? app.settings.anthropicEffort : nil,
            confirm: { call in await ChatSession.confirm(call) })

        isRunning = true
        activeProvider = selection.provider
        currentAssistant = nil
        let historySnapshot = history
        task = Task { [weak self] in
            do {
                for try await event in runner.run(history: historySnapshot) {
                    self?.handle(event, model: selection.model)
                }
            } catch is CancellationError {
                self?.notice("Stopped.", isError: false)
            } catch {
                if Task.isCancelled {
                    self?.notice("Stopped.", isError: false)
                } else {
                    self?.notice(error.localizedDescription, isError: true)
                }
            }
            self?.finishRun()
        }
        return true
    }

    func stop() {
        task?.cancel()
    }

    func clear() {
        guard !isRunning else { return }
        transcript.removeAll()
        history.removeAll()
        sessionUsage = TokenUsage()
        lastUsage = nil
    }

    private func handle(_ event: ConversationRunner.Event, model: String) {
        switch event {
        case .textDelta(let text):
            updateAssistant(model: model) { $0.text += text }
        case .thinkingDelta(let text):
            updateAssistant(model: model) { $0.thinking += text }
        case .toolCallStarted(let name):
            transcript.append(TranscriptItem(kind: .tool(name: name), text: "Calling \(name)…"))
        case .assistantMessage(let message, _, let servedBy):
            history.append(message)
            if let id = currentAssistant, let i = transcript.firstIndex(where: { $0.id == id }) {
                transcript[i].isStreaming = false
                if let servedBy { transcript[i].model = servedBy }
                if transcript[i].text.isEmpty && transcript[i].thinking.isEmpty { transcript.remove(at: i) }
            }
            currentAssistant = nil
        case .toolFinished(let call, let result):
            let index = transcript.lastIndex { item in
                if case .tool(let name) = item.kind { name == call.name && item.toolState == .running } else { false }
            }
            var item = index.map { transcript[$0] } ?? TranscriptItem(kind: .tool(name: call.name))
            item.text = call.name
            item.toolState = result.isError ? .failed : .succeeded
            item.detail = "Arguments: \(call.arguments.compactString)\nResult: \(result.content)"
            if let index { transcript[index] = item } else { transcript.append(item) }
        case .toolResults(let message):
            history.append(message)
        case .usage(let usage):
            sessionUsage = sessionUsage + usage
            lastUsage = usage
        case .needsUser(let message):
            notice(message, isError: false)
        }
    }

    private func updateAssistant(model: String, _ update: (inout TranscriptItem) -> Void) {
        if currentAssistant == nil {
            let item = TranscriptItem(kind: .assistant, isStreaming: true, model: model)
            currentAssistant = item.id
            transcript.append(item)
        }
        guard let i = transcript.lastIndex(where: { $0.id == currentAssistant }) else { return }
        update(&transcript[i])
    }

    private func finishRun() {
        // A cancelled turn can leave tool calls without results; answer them so
        // the history stays valid for the next request.
        if let last = history.last, last.role == .assistant, !last.toolCalls.isEmpty {
            let results = last.toolCalls.map {
                ContentPart.toolResult(ToolResult(callID: $0.id, name: $0.name, content: "Cancelled by the user.", isError: true))
            }
            history.append(ChatMessage(role: .tool, parts: results))
        }
        for i in transcript.indices where transcript[i].isStreaming { transcript[i].isStreaming = false }
        for i in transcript.indices where transcript[i].kind != .assistant && transcript[i].toolState == .running {
            if case .tool = transcript[i].kind { transcript[i].toolState = .failed }
        }
        isRunning = false
        activeProvider = nil
        currentAssistant = nil
        task = nil
    }

    private func notice(_ text: String, isError: Bool) {
        transcript.append(TranscriptItem(kind: .notice(isError: isError), text: text))
    }

    /// Destructive tools ask before running.
    private static func confirm(_ call: ToolCall) async -> Bool {
        await MainActor.run {
            let alert = NSAlert()
            alert.messageText = "Allow the assistant to run “\(call.name)”?"
            alert.informativeText = "This action can't be undone.\n\n\(call.arguments.compactString)"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn
        }
    }
}

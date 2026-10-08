import Foundation
import SnazzyCore

/// Claude via the Messages API (`POST /v1/messages`), streamed over SSE.
public struct AnthropicProvider: ModelProvider {
    public let kind = ProviderKind.anthropic
    public let baseURL: URL
    private let apiKey: String
    private let session: URLSession

    public init(apiKey: String, baseURL: String = "https://api.anthropic.com", session: URLSession = .shared) throws {
        guard !apiKey.isEmpty else { throw ProviderError.missingAPIKey(.anthropic) }
        guard let url = URL(string: baseURL), url.scheme != nil else { throw ProviderError.invalidBaseURL(baseURL) }
        self.apiKey = apiKey
        self.baseURL = url
        self.session = session
    }

    private func makeRequest(path: String, method: String, body: JSONValue? = nil, betas: [String] = []) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(AnthropicMapping.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if !betas.isEmpty { request.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta") }
        if let body { request.httpBody = try body.encoded(sortedKeys: false) }
        request.timeoutInterval = 600
        return request
    }

    public func listModels() async throws -> [ModelInfo] {
        let json = try await HTTP.data(
            try makeRequest(path: "v1/models", method: "GET"), session: session,
            errorMessage: AnthropicMapping.errorMessage)
        return (json["data"]?.arrayValue ?? []).compactMap { item in
            guard let id = item["id"]?.stringValue else { return nil }
            return ModelInfo(id: id, displayName: item["display_name"]?.stringValue, supportsTools: true)
        }
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try makeRequest(
                        path: "v1/messages", method: "POST",
                        body: AnthropicMapping.requestBody(request),
                        betas: AnthropicMapping.betas(for: request.model))
                    Log.provider.info("Anthropic request model=\(request.model, privacy: .public) messages=\(request.messages.count)")
                    let lines = try await HTTP.lines(urlRequest, session: session, errorMessage: AnthropicMapping.errorMessage)
                    var parser = AnthropicStreamParser()
                    for try await line in lines {
                        for event in try parser.consume(sseLine: line) { continuation.yield(event) }
                        if parser.isFinished { break }
                    }
                    continuation.yield(parser.completion())
                    continuation.finish()
                } catch {
                    Log.provider.error("Anthropic stream failed: \(error.localizedDescription, privacy: .public)")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Pure request/response mapping, kept separate so it can be unit tested.
public enum AnthropicMapping {
    public static let apiVersion = "2023-06-01"
    public static let fallbackBeta = "server-side-fallback-2026-07-01"
    public static let contextManagementBeta = "context-management-2025-06-27"

    /// Models that accept `fallbacks: "default"` on the Claude API.
    static func supportsDefaultFallbacks(_ model: String) -> Bool {
        ["claude-opus-5-5", "claude-opus-5", "claude-fable-5-1", "claude-sonnet-5-5"].contains(model)
    }

    public static func betas(for model: String) -> [String] {
        (supportsDefaultFallbacks(model) ? [fallbackBeta] : []) + [contextManagementBeta]
    }

    public static func requestBody(_ request: ModelRequest) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "max_tokens": .number(Double(request.maxTokens)),
            "stream": true,
            "messages": .array(messages(request.messages)),
            // Adaptive thinking with readable summaries, shown collapsed in the chat.
            "thinking": ["type": "adaptive", "display": "summarized"],
            // Cache everything up to the newest turn (tools, system, history); the
            // breakpoint moves forward by itself as the conversation grows.
            "cache_control": ["type": "ephemeral"],
            // Long builder chats: once the prompt is large, the API clears old tool calls
            // and results (file bodies included), keeping the latest few. Done server-side
            // because trimming history here would invalidate thinking blocks. Rare on
            // purpose, since each clearing pass rewrites the cache.
            "context_management": ["edits": [[
                "type": "clear_tool_uses_20250919",
                "trigger": ["type": "input_tokens", "value": 150_000],
                "keep": ["type": "tool_uses", "value": 6],
                "clear_at_least": ["type": "input_tokens", "value": 40_000],
                "clear_tool_inputs": true,
            ]]],
        ]
        if let system = request.system, !system.isEmpty { body["system"] = .string(system) }
        if let effort = request.effort { body["output_config"] = ["effort": .string(effort)] }
        if supportsDefaultFallbacks(request.model) { body["fallbacks"] = "default" }
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { tool in
                [
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "input_schema": tool.inputSchema,
                    "eager_input_streaming": true,
                ]
            })
        }
        return .object(body)
    }

    /// Maps the history to API messages. Tool results become user turns, and
    /// consecutive turns with the same API role are merged into one.
    static func messages(_ history: [ChatMessage]) -> [JSONValue] {
        var result: [(role: String, blocks: [JSONValue])] = []
        for message in history {
            let role = message.role == .assistant ? "assistant" : "user"
            let blocks = message.parts.compactMap(block)
            guard !blocks.isEmpty else { continue }
            if let last = result.last, last.role == role {
                result[result.count - 1].blocks += blocks
            } else {
                result.append((role, blocks))
            }
        }
        return result.map { ["role": .string($0.role), "content": .array($0.blocks)] }
    }

    static func block(_ part: ContentPart) -> JSONValue? {
        switch part {
        case .text(let text):
            return text.isEmpty ? nil : ["type": "text", "text": .string(text)]
        case .toolCall(let call):
            let input: JSONValue = call.arguments.objectValue != nil ? call.arguments : [:]
            return ["type": "tool_use", "id": .string(call.id), "name": .string(call.name), "input": input]
        case .toolResult(let result):
            return [
                "type": "tool_result", "tool_use_id": .string(result.callID),
                "content": .string(result.content), "is_error": .bool(result.isError),
            ]
        case .opaque(let provider, let block):
            return provider == .anthropic ? block : nil
        case .image(let mediaType, let data):
            return ["type": "image", "source": [
                "type": "base64", "media_type": .string(mediaType), "data": .string(data.base64EncodedString()),
            ]]
        }
    }

    static func errorMessage(_ json: JSONValue) -> String? {
        guard let error = json["error"] else { return nil }
        let type = error["type"]?.stringValue ?? "error"
        return "\(type): \(error["message"]?.stringValue ?? "unknown")"
    }
}

/// Accumulates Messages API SSE events into deltas and a final assistant message.
public struct AnthropicStreamParser {
    private struct Block {
        var start: [String: JSONValue]
        var text = ""
        var partialJSON = ""
        var thinking = ""
        var signature = ""
        var type: String { start["type"]?.stringValue ?? "" }
    }

    private var blocks: [Int: Block] = [:]
    private var order: [Int] = []
    private var usage = TokenUsage()
    private var stopReason: String?
    private var model: String?
    public private(set) var isFinished = false

    public init() {}

    /// Feed one line of the SSE stream. Only `data:` lines matter: every data
    /// payload carries its own `type`, so `event:` lines are redundant.
    public mutating func consume(sseLine line: String) throws -> [StreamEvent] {
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty else { return [] }
        let event: JSONValue
        do { event = try JSONValue.parse(payload) } catch {
            throw ProviderError.malformedResponse("bad SSE data: \(payload.prefix(200))")
        }
        return try consume(event: event)
    }

    public mutating func consume(event: JSONValue) throws -> [StreamEvent] {
        switch event["type"]?.stringValue {
        case "message_start":
            let message = event["message"]
            model = message?["model"]?.stringValue
            if let u = message?["usage"] { applyUsage(u) }
            return []
        case "content_block_start":
            guard let index = event["index"]?.intValue, let start = event["content_block"]?.objectValue else { return [] }
            blocks[index] = Block(start: start)
            order.append(index)
            if start["type"]?.stringValue == "tool_use" {
                return [.toolCallStarted(name: start["name"]?.stringValue ?? "tool")]
            }
            return []
        case "content_block_delta":
            guard let index = event["index"]?.intValue, let delta = event["delta"], blocks[index] != nil else { return [] }
            switch delta["type"]?.stringValue {
            case "text_delta":
                let text = delta["text"]?.stringValue ?? ""
                blocks[index]!.text += text
                return [.textDelta(text)]
            case "input_json_delta":
                let fragment = delta["partial_json"]?.stringValue ?? ""
                blocks[index]!.partialJSON += fragment
                guard !fragment.isEmpty else { return [] }
                let start = blocks[index]!.start
                return [.toolInputDelta(
                    callID: start["id"]?.stringValue ?? "", name: start["name"]?.stringValue ?? "", fragment: fragment)]
            case "thinking_delta":
                let text = delta["thinking"]?.stringValue ?? ""
                blocks[index]!.thinking += text
                return text.isEmpty ? [] : [.thinkingDelta(text)]
            case "signature_delta":
                blocks[index]!.signature += delta["signature"]?.stringValue ?? ""
                return []
            default:
                return []
            }
        case "message_delta":
            if let reason = event["delta"]?["stop_reason"]?.stringValue { stopReason = reason }
            if let u = event["usage"] {
                applyUsage(u)
                // Shows whether prompt caching works (reads should grow turn by turn).
                Log.provider.notice("Anthropic usage: input \(u["input_tokens"]?.intValue ?? 0), cache read \(u["cache_read_input_tokens"]?.intValue ?? 0), cache write \(u["cache_creation_input_tokens"]?.intValue ?? 0)")
            }
            if let edits = event["context_management"]?["applied_edits"], edits.arrayValue?.isEmpty == false {
                Log.provider.notice("Anthropic cleared old tool uses: \(edits.compactString, privacy: .public)")
            }
            return []
        case "message_stop":
            isFinished = true
            return []
        case "error":
            let error = event["error"]
            throw ProviderError.api(
                type: error?["type"]?.stringValue ?? "error",
                message: error?["message"]?.stringValue ?? "stream error")
        default:  // ping and future event types
            return []
        }
    }

    private mutating func applyUsage(_ u: JSONValue) {
        let input = (u["input_tokens"]?.intValue ?? 0) + (u["cache_creation_input_tokens"]?.intValue ?? 0)
            + (u["cache_read_input_tokens"]?.intValue ?? 0)
        if input > 0 { usage.inputTokens = input }
        if let output = u["output_tokens"]?.intValue { usage.outputTokens = output }
    }

    /// The assembled assistant message, in block order.
    public func completion() -> StreamEvent {
        var parts: [ContentPart] = []
        for index in order {
            guard let block = blocks[index] else { continue }
            switch block.type {
            case "text":
                parts.append(.text(block.text))
            case "tool_use":
                let raw = block.partialJSON.trimmingCharacters(in: .whitespacesAndNewlines)
                let args: JSONValue
                if raw.isEmpty {
                    args = block.start["input"] ?? [:]
                } else {
                    // Unparseable (e.g. truncated) input is kept as a string so
                    // schema validation rejects it and the model can retry.
                    args = (try? JSONValue.parse(raw)) ?? .string(raw)
                }
                parts.append(.toolCall(ToolCall(
                    id: block.start["id"]?.stringValue ?? UUID().uuidString,
                    name: block.start["name"]?.stringValue ?? "", arguments: args)))
            case "thinking":
                // Echoed back unchanged on the next request.
                parts.append(.opaque(provider: .anthropic, block: [
                    "type": "thinking", "thinking": .string(block.thinking), "signature": .string(block.signature),
                ]))
            default:
                // redacted_thinking, fallback markers and future block types.
                parts.append(.opaque(provider: .anthropic, block: .object(block.start)))
            }
        }
        return .completed(
            message: ChatMessage(role: .assistant, parts: parts),
            stopReason: StopReason(anthropic: stopReason), usage: usage, servedBy: model)
    }
}

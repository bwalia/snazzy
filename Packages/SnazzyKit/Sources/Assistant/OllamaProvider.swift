import Foundation
import SnazzyCore

/// Local models via Ollama's `/api/chat` (NDJSON streaming, tool calls).
public struct OllamaProvider: ModelProvider {
    public let kind = ProviderKind.ollama
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: String = "http://localhost:11434", session: URLSession = .shared) throws {
        guard let url = URL(string: baseURL), url.scheme != nil else { throw ProviderError.invalidBaseURL(baseURL) }
        self.baseURL = url
        self.session = session
    }

    public func listModels() async throws -> [ModelInfo] {
        var request = URLRequest(url: baseURL.appending(path: "api/tags"))
        request.timeoutInterval = 10
        let json = try await HTTP.data(request, session: session, errorMessage: OllamaMapping.errorMessage)
        return OllamaMapping.models(fromTags: json)
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var urlRequest = URLRequest(url: baseURL.appending(path: "api/chat"))
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
                    urlRequest.httpBody = try OllamaMapping.requestBody(request).encoded(sortedKeys: false)
                    // Large local models can take minutes to load.
                    urlRequest.timeoutInterval = 900
                    Log.provider.info("Ollama request model=\(request.model, privacy: .public) messages=\(request.messages.count)")
                    let lines = try await HTTP.lines(urlRequest, session: session, errorMessage: OllamaMapping.errorMessage)
                    var parser = OllamaStreamParser()
                    for try await line in lines {
                        for event in try parser.consume(line: line) { continuation.yield(event) }
                        if parser.isFinished { break }
                    }
                    continuation.yield(parser.completion())
                    continuation.finish()
                } catch {
                    Log.provider.error("Ollama stream failed: \(error.localizedDescription, privacy: .public)")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public enum OllamaMapping {
    /// Ollama's default context is small; tool schemas plus a conversation need more.
    public static let contextLength = 32_768

    public static func requestBody(_ request: ModelRequest) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "stream": true,
            "messages": .array(messages(request)),
            "options": ["num_ctx": .number(Double(contextLength))],
        ]
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": .string(tool.name),
                        "description": .string(tool.description),
                        "parameters": tool.inputSchema,
                    ],
                ]
            })
        }
        return .object(body)
    }

    static func messages(_ request: ModelRequest) -> [JSONValue] {
        var out: [JSONValue] = []
        if let system = request.system, !system.isEmpty {
            out.append(["role": "system", "content": .string(system)])
        }
        for message in request.messages {
            switch message.role {
            case .user:
                var m: [String: JSONValue] = ["role": "user", "content": .string(message.text)]
                let images = message.images
                if !images.isEmpty { m["images"] = .array(images.map { .string($0.data.base64EncodedString()) }) }
                out.append(.object(m))
            case .assistant:
                var m: [String: JSONValue] = ["role": "assistant", "content": .string(message.text)]
                let calls = message.toolCalls
                if !calls.isEmpty {
                    m["tool_calls"] = .array(calls.map { call in
                        ["function": ["name": .string(call.name), "arguments": call.arguments.objectValue != nil ? call.arguments : [:]]]
                    })
                }
                out.append(.object(m))
            case .tool:
                for part in message.parts {
                    if case .toolResult(let r) = part {
                        out.append(["role": "tool", "content": .string(r.content), "tool_name": .string(r.name)])
                    }
                }
            }
        }
        return out
    }

    static func models(fromTags json: JSONValue) -> [ModelInfo] {
        (json["models"]?.arrayValue ?? []).compactMap { item in
            guard let name = item["name"]?.stringValue else { return nil }
            let caps = item["capabilities"]?.arrayValue?.compactMap(\.stringValue)
            let size = item["details"]?["parameter_size"]?.stringValue
            return ModelInfo(
                id: name, displayName: size.map { "\(name) (\($0))" } ?? name,
                supportsTools: caps.map { $0.contains("tools") })
        }
    }

    static func errorMessage(_ json: JSONValue) -> String? {
        json["error"]?.stringValue
    }
}

public struct OllamaStreamParser {
    private var text = ""
    private var toolCalls: [ToolCall] = []
    private var usage = TokenUsage()
    private var doneReason: String?
    private var model: String?
    public private(set) var isFinished = false

    public init() {}

    public mutating func consume(line: String) throws -> [StreamEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let chunk: JSONValue
        do { chunk = try JSONValue.parse(trimmed) } catch {
            throw ProviderError.malformedResponse("bad NDJSON: \(trimmed.prefix(200))")
        }
        if let error = chunk["error"]?.stringValue { throw ProviderError.api(type: "ollama", message: error) }
        model = chunk["model"]?.stringValue ?? model

        var events: [StreamEvent] = []
        if let message = chunk["message"] {
            if let thinking = message["thinking"]?.stringValue, !thinking.isEmpty {
                events.append(.thinkingDelta(thinking))
            }
            if let content = message["content"]?.stringValue, !content.isEmpty {
                text += content
                events.append(.textDelta(content))
            }
            for call in message["tool_calls"]?.arrayValue ?? [] {
                guard let function = call["function"], let name = function["name"]?.stringValue else { continue }
                var args = function["arguments"] ?? [:]
                // Some models send arguments as a JSON string.
                if case .string(let s) = args, let parsed = try? JSONValue.parse(s) { args = parsed }
                let id = call["id"]?.stringValue ?? "call_\(UUID().uuidString.prefix(8).lowercased())"
                toolCalls.append(ToolCall(id: id, name: name, arguments: args))
                events.append(.toolCallStarted(name: name))
            }
        }
        if chunk["done"]?.boolValue == true {
            isFinished = true
            doneReason = chunk["done_reason"]?.stringValue
            usage = TokenUsage(
                inputTokens: chunk["prompt_eval_count"]?.intValue ?? 0,
                outputTokens: chunk["eval_count"]?.intValue ?? 0)
        }
        return events
    }

    public func completion() -> StreamEvent {
        var parts: [ContentPart] = []
        if !text.isEmpty { parts.append(.text(text)) }
        parts += toolCalls.map(ContentPart.toolCall)
        let stop: StopReason =
            if !toolCalls.isEmpty { .toolUse } else if doneReason == "length" { .maxTokens } else { .endTurn }
        return .completed(
            message: ChatMessage(role: .assistant, parts: parts), stopReason: stop, usage: usage, servedBy: model)
    }
}

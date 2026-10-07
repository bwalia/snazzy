import Foundation
import SnazzyCore

/// A tool the assistant can call. Handlers call the same actions the UI uses.
public struct RegisteredTool: Sendable {
    public var definition: ToolDefinition
    /// Destructive tools (deleting takes, overwriting exports) need UI confirmation.
    public var requiresConfirmation: Bool
    public var handler: @Sendable (JSONValue) async throws -> JSONValue

    public init(
        name: String, description: String, inputSchema: JSONValue, requiresConfirmation: Bool = false,
        handler: @escaping @Sendable (JSONValue) async throws -> JSONValue
    ) {
        self.definition = ToolDefinition(name: name, description: description, inputSchema: inputSchema)
        self.requiresConfirmation = requiresConfirmation
        self.handler = handler
    }
}

public struct ToolRegistry: Sendable {
    private var tools: [String: RegisteredTool] = [:]
    private var order: [String] = []

    public init(_ tools: [RegisteredTool] = []) {
        tools.forEach { register($0) }
    }

    public mutating func register(_ tool: RegisteredTool) {
        let name = tool.definition.name
        if tools[name] == nil { order.append(name) }
        tools[name] = tool
    }

    /// Definitions in registration order (stable, so prompt caching works).
    public var definitions: [ToolDefinition] { order.compactMap { tools[$0]?.definition } }

    public func tool(named name: String) -> RegisteredTool? { tools[name] }

    /// Returns validation errors; empty means the call can run.
    public func validate(_ call: ToolCall) -> [String] {
        guard let tool = tools[call.name] else {
            return ["Unknown tool '\(call.name)'. Available tools: \(order.joined(separator: ", "))"]
        }
        return SchemaValidator.validate(call.arguments, against: tool.definition.inputSchema)
    }

    /// Validates and runs a call. Errors are returned as error results, never thrown,
    /// so the model can see what went wrong.
    public func execute(_ call: ToolCall) async -> ToolResult {
        let errors = validate(call)
        guard errors.isEmpty, let tool = tools[call.name] else {
            return Self.invalidResult(call, errors: errors, schema: tools[call.name]?.definition.inputSchema)
        }
        do {
            let output = try await tool.handler(call.arguments)
            return ToolResult(callID: call.id, name: call.name, content: output.compactString)
        } catch {
            Log.assistant.error("Tool \(call.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return ToolResult(callID: call.id, name: call.name, content: "Error: \(error.localizedDescription)", isError: true)
        }
    }

    static func invalidResult(_ call: ToolCall, errors: [String], schema: JSONValue?) -> ToolResult {
        var message = "Invalid call to \(call.name): " + errors.joined(separator: "; ")
        if let schema { message += ". Expected arguments schema: \(schema.compactString). Fix the arguments and call again." }
        return ToolResult(callID: call.id, name: call.name, content: message, isError: true)
    }
}

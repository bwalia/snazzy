import AppKit
import Assistant
import CaptureEngine
import Foundation
import MCP
import Observation
import Security
import SnazzyCore

/// MCP in both directions:
/// - **Client:** connects to MCP servers (docs, drives, databases, RAG search)
///   and offers their tools and resources to the assistant.
/// - **Server:** exposes Snazzy Pro's own tools on 127.0.0.1 so AI agents
///   (Claude Code, Claude Desktop, Cursor…) can drive the app.
@MainActor @Observable
final class MCPManager {
    struct ServerConfig: Codable, Identifiable, Hashable {
        enum Approval: String, Codable, CaseIterable {
            /// Ask before tools that may change something (not marked read-only).
            case askUnlessReadOnly
            case alwaysAsk
            case neverAsk

            var label: String {
                switch self {
                case .askUnlessReadOnly: "Ask unless read-only"
                case .alwaysAsk: "Always ask"
                case .neverAsk: "Never ask"
                }
            }
        }

        var id = UUID()
        var name: String
        var url: String
        /// Names of headers whose values are stored in the Keychain.
        var headerNames: [String] = []
        var enabled = true
        var approval: Approval = .askUnlessReadOnly
    }

    enum Status: Equatable {
        case off
        case connecting
        case connected(tools: Int, resources: Int, era: String, serverName: String?)
        case failed(String)

        var label: String {
            switch self {
            case .off: "Off"
            case .connecting: "Connecting…"
            case .connected(let t, let r, let era, _): "Connected · \(t) tools\(r > 0 ? " · \(r) resources" : "") · \(era)"
            case .failed(let m): m
            }
        }
    }

    private(set) var servers: [ServerConfig] = []
    private(set) var status: [UUID: Status] = [:]
    private(set) var tools: [UUID: [MCPTool]] = [:]
    private(set) var resources: [UUID: [MCPResource]] = [:]

    // Snazzy Pro as an MCP server
    private(set) var serverRunning = false
    private(set) var serverError: String?
    private(set) var lastAgentCall: String?
    var serverEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "SnazzyPro.mcpServerEnabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "SnazzyPro.mcpServerEnabled")
            newValue ? startServer() : stopServer()
        }
    }
    var serverPort: UInt16 {
        get { UInt16(UserDefaults.standard.integer(forKey: "SnazzyPro.mcpServerPort")).nonZero ?? 47823 }
        set { UserDefaults.standard.set(Int(newValue), forKey: "SnazzyPro.mcpServerPort") }
    }

    @ObservationIgnored private var clients: [UUID: MCPClient] = [:]
    @ObservationIgnored private var httpServer: MCPHTTPServer?
    @ObservationIgnored private let secrets: any SecretStore
    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private static let storeKey = "SnazzyPro.mcpServers.v1"

    init(app: AppModel, secrets: any SecretStore) {
        self.app = app
        self.secrets = secrets
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
           let saved = try? JSONDecoder().decode([ServerConfig].self, from: data) {
            servers = saved
        }
    }

    /// Connects enabled servers and starts the local server if it was on.
    func start() {
        for config in servers where config.enabled { connect(config.id) }
        if serverEnabled { startServer() }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(servers) { UserDefaults.standard.set(data, forKey: Self.storeKey) }
    }

    // MARK: Client: managing servers

    /// Adds a server. `headers` values go to the Keychain, never to settings files.
    func add(name: String, url: String, headers: [String: String], approval: ServerConfig.Approval) throws {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: trimmed), let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme), u.host() != nil else {
            throw CaptureActionError(message: "Use the server's http(s) MCP URL, e.g. https://example.com/mcp.")
        }
        if scheme == "http", !["localhost", "127.0.0.1", "::1"].contains(u.host()?.lowercased() ?? "") {
            throw CaptureActionError(message: "Remote MCP servers must use https.")
        }
        var config = ServerConfig(name: name.isEmpty ? (u.host() ?? "MCP server") : name, url: trimmed, approval: approval)
        for (key, value) in headers where !key.isEmpty && !value.isEmpty {
            try secrets.setSecret(value, for: secretAccount(config.id, key))
            config.headerNames.append(key)
        }
        servers.append(config)
        save()
        connect(config.id)
    }

    /// Connects a server for this run only (not saved). Used by self-tests.
    func addTemporary(name: String, url: String) -> UUID {
        let config = ServerConfig(name: name, url: url, approval: .neverAsk)
        servers.append(config)
        connect(config.id)
        return config.id
    }

    func remove(_ id: UUID) {
        guard let config = servers.first(where: { $0.id == id }) else { return }
        disconnect(id)
        for name in config.headerNames { try? secrets.deleteSecret(for: secretAccount(id, name)) }
        servers.removeAll { $0.id == id }
        status[id] = nil
        save()
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let i = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[i].enabled = enabled
        save()
        enabled ? connect(id) : disconnect(id)
    }

    func setApproval(_ id: UUID, _ approval: ServerConfig.Approval) {
        guard let i = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[i].approval = approval
        save()
    }

    private func secretAccount(_ id: UUID, _ header: String) -> String { "mcp.\(id.uuidString).\(header)" }

    func connect(_ id: UUID) {
        guard let config = servers.first(where: { $0.id == id }), let url = URL(string: config.url) else { return }
        var headers: [String: String] = [:]
        for name in config.headerNames {
            if let value = (try? secrets.secret(for: secretAccount(id, name))) ?? nil { headers[name] = value }
        }
        let client = MCPClient(url: url, headers: headers)
        clients[id] = client
        status[id] = .connecting
        Task {
            do {
                try await client.connect()
                let list = try await client.listTools()
                let res = (try? await client.listResources()) ?? []
                let era: String = switch await client.era {
                case .modern(let v)?: "MCP \(v)"
                case .legacy(let v)?: "MCP \(v) (legacy)"
                case nil: "MCP"
                }
                tools[id] = list
                resources[id] = res
                status[id] = .connected(tools: list.count, resources: res.count, era: era, serverName: await client.serverName)
                app.capture.diagnostics.log("MCP \(config.name): \(list.count) tools, \(res.count) resources", category: "mcp")
            } catch {
                tools[id] = []
                status[id] = .failed(error.localizedDescription)
                app.capture.diagnostics.log("MCP \(config.name) failed: \(error.localizedDescription)", category: "mcp", level: .warning)
            }
        }
    }

    func disconnect(_ id: UUID) {
        if let client = clients.removeValue(forKey: id) { Task { await client.close() } }
        tools[id] = []
        resources[id] = []
        status[id] = .off
    }

    // MARK: Client: tools for the assistant

    /// Tool name for the model: `mcp__<server>__<tool>`, at most 64 safe characters.
    static func toolName(server: String, tool: String) -> String {
        func clean(_ s: String) -> String {
            String(s.lowercased().map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" })
        }
        let full = "mcp__\(clean(server).prefix(20))__\(clean(tool))"
        return String(full.prefix(64))
    }

    /// The connected servers' tools, plus resource tools, as assistant tools.
    func registeredTools() -> [RegisteredTool] {
        var out: [RegisteredTool] = []
        for config in servers where config.enabled {
            guard let client = clients[config.id], case .connected = status[config.id] else { continue }
            for tool in tools[config.id] ?? [] {
                let ask: Bool = switch config.approval {
                case .alwaysAsk: true
                case .neverAsk: false
                case .askUnlessReadOnly: !tool.readOnly
                }
                let desc = "[\(config.name) via MCP] " + (tool.title.map { "\($0): " } ?? "") + tool.description
                let schema: JSONValue = tool.inputSchema["type"] == "object" ? tool.inputSchema : ["type": "object", "properties": [:]]
                let serverName = config.name
                let toolName = tool.name
                out.append(RegisteredTool(name: Self.toolName(server: config.name, tool: tool.name),
                                          description: String(desc.prefix(1000)), inputSchema: Self.permissive(schema),
                                          requiresConfirmation: ask, external: "the MCP server “\(serverName)”") { @Sendable args in
                    let result = try await client.callTool(toolName, arguments: args)
                    if result.isError { throw CaptureActionError(message: String(result.text.prefix(Self.maxResultCharacters))) }
                    return .string(Self.capped(result.text))
                })
            }
        }
        out.append(contentsOf: genericTools())
        return out
    }

    /// What one MCP result may add to the chat (a server can return megabytes).
    nonisolated static let maxResultCharacters = 60_000

    nonisolated static func capped(_ text: String) -> String {
        guard text.count > maxResultCharacters else { return text }
        return String(text.prefix(maxResultCharacters)) + "\n… [cut: \(text.count - maxResultCharacters) more characters]"
    }

    /// Our validator rejects unknown properties only when a schema says so;
    /// MCP schemas are passed through unchanged otherwise.
    static func permissive(_ schema: JSONValue) -> JSONValue { schema }

    private func genericTools() -> [RegisteredTool] {
        let manager = self
        return [
            RegisteredTool(
                name: "mcp_list_servers",
                description: "List the connected MCP servers (external data sources such as documents, drives, databases or RAG search), their tools and resources.",
                inputSchema: ["type": "object", "properties": [:], "additionalProperties": false],
                external: "the connected MCP servers"
            ) { @Sendable _ in await manager.serversJSON() },
            RegisteredTool(
                name: "mcp_read_resource",
                description: "Read a resource (a document or data item) from a connected MCP server by its URI. Use mcp_list_servers to see available resources.",
                inputSchema: ["type": "object", "properties": [
                    "server": ["type": "string", "description": "Server name"],
                    "uri": ["type": "string", "minLength": 1],
                ], "required": ["server", "uri"], "additionalProperties": false],
                external: "a connected MCP server"
            ) { @Sendable args in
                let text = try await manager.readResource(server: args["server"]?.stringValue ?? "", uri: args["uri"]?.stringValue ?? "")
                return .string(Self.capped(text))
            },
        ]
    }

    func readResource(server: String, uri: String) async throws -> String {
        guard let config = DeviceMatcher.match(server, in: servers, id: { $0.id.uuidString }, name: \.name),
              let client = clients[config.id] else {
            throw CaptureActionError(message: "No connected MCP server called “\(server)”.")
        }
        let text = try await client.readResource(uri)
        return "Resource \(uri) from the MCP server “\(config.name)”:\n\(text)"
    }

    func serversJSON() -> JSONValue {
        .array(servers.map { config in
            [
                "name": .string(config.name),
                "status": .string(status[config.id]?.label ?? "Off"),
                "tools": .array((tools[config.id] ?? []).prefix(60).map {
                    .string(Self.toolName(server: config.name, tool: $0.name))
                }),
                "resources": .array((resources[config.id] ?? []).prefix(40).map {
                    ["uri": .string($0.uri), "name": .string($0.name)] as JSONValue
                }),
            ]
        })
    }

    // MARK: Server: Snazzy Pro for other agents

    /// The token agents use, made once and kept. If the Keychain can't be read (an
    /// error, not "no token yet"), this is "" rather than a new token: replacing it
    /// would lock out every agent already set up. The server won't start with "".
    var serverToken: String {
        do {
            if let token = try secrets.secret(for: "mcp.server.token"), !token.isEmpty { return token }
            let token = Self.randomToken()
            try secrets.setSecret(token, for: "mcp.server.token")
            return token
        } catch {
            return ""
        }
    }

    func regenerateToken() {
        do {
            try secrets.setSecret(Self.randomToken(), for: "mcp.server.token")
        } catch {
            serverError = "Couldn't save a new token in the Keychain: \(error.localizedDescription)"
            return
        }
        if serverRunning { stopServer(); startServer() }
    }

    static func randomToken() -> String {
        // The system's secure random generator.
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    var serverEndpoint: String { "http://127.0.0.1:\(serverPort)/mcp" }

    func startServer(port overridePort: UInt16? = nil) {
        stopServer()
        let backend = SnazzyMCPBackend(app: app)
        let core = MCPServerCore(name: "Snazzy Pro", version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
                                 instructions: Self.serverInstructions, backend: backend)
        let token = serverToken
        guard !token.isEmpty else {
            serverRunning = false
            serverError = "Couldn't read the server's token from the Keychain. Allow Snazzy Pro to use it, then turn the server on again."
            return
        }
        let server = MCPHTTPServer(port: overridePort ?? serverPort, token: token, core: core)
        server.onFailed = { [weak self] message in
            Task { @MainActor in
                self?.serverRunning = false
                self?.serverError = message
            }
        }
        do {
            try server.start()
            httpServer = server
            serverRunning = true
            serverError = nil
            app.capture.diagnostics.log("MCP server on \(serverEndpoint)", category: "mcp")
        } catch {
            serverRunning = false
            serverError = error.localizedDescription
        }
    }

    func stopServer() {
        httpServer?.stop()
        httpServer = nil
        serverRunning = false
    }

    func noteAgentCall(_ tool: String) {
        lastAgentCall = "\(tool) at \(Date().formatted(date: .omitted, time: .standard))"
        app.capture.diagnostics.log("Agent called \(tool) over MCP", category: "mcp")
        app.chat.logSession("mcp_agent_call", ["tool": .string(tool)])
    }

    static let serverInstructions = """
        Snazzy Pro is a Mac app for making and recording video presentations. Use these tools to plan and build \
        HTML slide decks and prototypes (create_project, write_file, check_preview), set up the microphone, screen \
        and camera inset (list_devices, select_mic, select_capture_source, select_inset_device, set_inset, \
        set_background), and record (start_recording, stop_recording). Call get_project_state first. Actions that \
        can't be undone ask the person at the Mac for confirmation.
        """

    // MARK: Setup snippets for agents

    func claudeCodeCommand() -> String {
        "claude mcp add --transport http snazzy-pro \(serverEndpoint) --header \"Authorization: Bearer \(serverToken)\""
    }

    func claudeDesktopConfig() -> String {
        """
        {
          "mcpServers": {
            "snazzy-pro": {
              "command": "npx",
              "args": ["-y", "mcp-remote", "\(serverEndpoint)", "--header", "Authorization: Bearer \(serverToken)"]
            }
          }
        }
        """
    }

    func genericJSONConfig() -> String {
        """
        {
          "mcpServers": {
            "snazzy-pro": {
              "type": "http",
              "url": "\(serverEndpoint)",
              "headers": { "Authorization": "Bearer \(serverToken)" }
            }
          }
        }
        """
    }
}

private extension UInt16 {
    var nonZero: UInt16? { self == 0 ? nil : self }
}

/// Exposes the assistant's own tools (the same actions as the UI) over MCP.
struct SnazzyMCPBackend: MCPServerBackend {
    let app: AppModel

    @MainActor private func registry() -> ToolRegistry {
        // Only Snazzy Pro's own tools: never re-export tools from other MCP servers.
        AssistantTools.registry(app: app, includeMCP: false, offMac: "an AI agent connected over MCP")
    }

    func tools() async -> [MCPTool] {
        await MainActor.run {
            let reg = registry()
            return reg.definitions.map { def in
                let readOnly = ["get_", "list_", "check_", "read_"].contains { def.name.hasPrefix($0) }
                let destructive = reg.tool(named: def.name)?.requiresConfirmation ?? false
                return MCPTool(name: def.name, description: def.description, inputSchema: def.inputSchema,
                               readOnly: readOnly, destructive: destructive)
            }
        }
    }

    @MainActor
    private static func askAgentApproval(name: String, arguments: JSONValue) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "An AI agent wants to run “\(name)” in Snazzy Pro"
        alert.informativeText = "This came from an app connected over MCP. It can't be undone.\n\n\(arguments.compactString.prefix(400))"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        NSApp.activate()
        return await Confirm.ask(alert)
    }

    func callTool(name: String, arguments: JSONValue) async -> MCPToolResult {
        let (reg, needsConfirm) = await MainActor.run { () -> (ToolRegistry, Bool) in
            app.mcp.noteAgentCall(name)
            let r = registry()
            return (r, r.tool(named: name)?.requiresConfirmation ?? false)
        }
        let call = ToolCall(id: "mcp_\(UUID().uuidString.prefix(8))", name: name, arguments: arguments)
        if needsConfirm {
            let ok = await Self.askAgentApproval(name: name, arguments: arguments)
            if !ok { return MCPToolResult(text: "The person at the Mac declined this action.", isError: true) }
        }
        let result = await reg.execute(call)
        return MCPToolResult(text: result.content, isError: result.isError)
    }

    func resources() async -> [MCPResource] {
        [
            MCPResource(uri: "snazzy://project-state", name: "Project state", description: "Models, devices, capture setup, builder project and recording status", mimeType: "application/json"),
            MCPResource(uri: "snazzy://settings", name: "Settings", description: "All settings (no secrets)", mimeType: "application/json"),
        ]
    }

    func readResource(uri: String) async -> (text: String, mimeType: String)? {
        await MainActor.run {
            switch uri {
            case "snazzy://project-state": (app.projectState().compactString, "application/json")
            case "snazzy://settings": (app.settingsJSON().compactString, "application/json")
            default: nil
            }
        }
    }
}

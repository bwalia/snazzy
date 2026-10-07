import AppKit
import MCP
import SnazzyCore
import SwiftUI

/// Settings › MCP: data sources Snazzy Pro connects to, and Snazzy Pro as a
/// server for AI agents.
struct MCPSettings: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false

    var body: some View {
        let mcp = model.mcp!
        Form {
            Section {
                if mcp.servers.isEmpty {
                    Text("No servers yet. Add an MCP server to let the assistant search your documents, notes, drives, databases or a RAG index while it plans and builds.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(mcp.servers) { server in
                    ServerRow(server: server)
                }
                Button("Add Server…") { adding = true }
            } header: {
                Text("Data sources (MCP servers)")
            } footer: {
                Text("Uses the Streamable HTTP transport (modern 2026-07-28 and legacy versions). For a local \"stdio\" server, run it behind a bridge such as `npx supergateway --stdio \"…\" --outputTransport streamableHttp` and add its http://localhost URL. Tool results are treated as information, never as instructions.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            AgentServerSection()
        }
        .formStyle(.grouped)
        .sheet(isPresented: $adding) { AddServerSheet() }
    }
}

private struct ServerRow: View {
    @Environment(AppModel.self) private var model
    let server: MCPManager.ServerConfig

    var body: some View {
        let mcp = model.mcp!
        let status = mcp.status[server.id] ?? .off
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(color(status)).frame(width: 8, height: 8)
                Text(server.name).font(.callout.weight(.semibold))
                Spacer()
                Toggle("", isOn: Binding(get: { server.enabled }, set: { mcp.setEnabled(server.id, $0) })).labelsHidden()
            }
            Text(server.url).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            Text(status.label).font(.caption).foregroundStyle(status == .off ? Color.secondary : color(status)).lineLimit(2)
            HStack {
                Picker("Approval", selection: Binding(get: { server.approval }, set: { mcp.setApproval(server.id, $0) })) {
                    ForEach(MCPManager.ServerConfig.Approval.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .fixedSize()
                Spacer()
                Button("Reconnect") { mcp.connect(server.id) }.disabled(!server.enabled)
                Button("Remove", role: .destructive) { mcp.remove(server.id) }
            }
            .controlSize(.small)
            if let tools = mcp.tools[server.id], !tools.isEmpty {
                DisclosureGroup("\(tools.count) tools") {
                    ForEach(tools, id: \.name) { tool in
                        HStack(alignment: .firstTextBaseline) {
                            Text(tool.name).font(.caption.monospaced())
                            if tool.readOnly { Text("read-only").font(.caption2).foregroundStyle(.green) }
                            Text(tool.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    private func color(_ s: MCPManager.Status) -> Color {
        switch s {
        case .connected: .green
        case .connecting: .orange
        case .failed: .red
        case .off: .gray
        }
    }
}

private struct AddServerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var headerName = "Authorization"
    @State private var headerValue = ""
    @State private var approval = MCPManager.ServerConfig.Approval.askUnlessReadOnly
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add an MCP server").font(.title3.weight(.semibold))
            Form {
                TextField("Name", text: $name, prompt: Text("e.g. Team docs"))
                TextField("URL", text: $url, prompt: Text("https://example.com/mcp"))
                Section("Authentication (optional)") {
                    TextField("Header", text: $headerName)
                    SecureField("Value", text: $headerValue, prompt: Text("Bearer …  (stored in the Keychain)"))
                }
                Picker("Before running tools", selection: $approval) {
                    ForEach(MCPManager.ServerConfig.Approval.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
            .formStyle(.grouped)
            HStack {
                Text("Try without a key: Context7 (https://mcp.context7.com/mcp) or DeepWiki (https://mcp.deepwiki.com/mcp).")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    do {
                        try model.mcp.add(name: name, url: url, headers: headerValue.isEmpty ? [:] : [headerName: headerValue], approval: approval)
                        dismiss()
                    } catch let e { error = e.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(url.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

/// Snazzy Pro as an MCP server for AI agents.
private struct AgentServerSection: View {
    @Environment(AppModel.self) private var model
    @State private var showToken = false
    @State private var copied: String?

    var body: some View {
        let mcp = model.mcp!
        Section {
            Toggle("Let AI agents use Snazzy Pro", isOn: Binding(get: { mcp.serverEnabled }, set: { mcp.serverEnabled = $0 }))
            if mcp.serverEnabled {
                LabeledContent("Status") {
                    if mcp.serverRunning {
                        Label("Running on \(mcp.serverEndpoint)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Label(mcp.serverError ?? "Not running", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    }
                }
                LabeledContent("Token") {
                    HStack {
                        Text(showToken ? mcp.serverToken : String(repeating: "•", count: 16)).font(.caption.monospaced()).textSelection(.enabled)
                        Button(showToken ? "Hide" : "Show") { showToken.toggle() }
                        Button("New Token") { mcp.regenerateToken() }
                    }
                    .controlSize(.small)
                }
                if let last = mcp.lastAgentCall {
                    LabeledContent("Last agent call", value: last)
                }
                snippet("Claude Code", mcp.claudeCodeCommand())
                snippet("Claude Desktop (claude_desktop_config.json, uses mcp-remote)", mcp.claudeDesktopConfig())
                snippet("Cursor, VS Code and other MCP clients", mcp.genericJSONConfig())
            }
        } header: {
            Text("Snazzy Pro as an MCP server")
        } footer: {
            Text("Agents get the same actions as the assistant: build decks and prototypes, set up devices and backgrounds, record. Only apps on this Mac with the token can connect (127.0.0.1 only). Actions that can't be undone ask you first.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func snippet(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption.weight(.semibold))
                Spacer()
                Button(copied == title ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = title
                }
                .controlSize(.small)
            }
            Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .lineLimit(12).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
        }
    }
}

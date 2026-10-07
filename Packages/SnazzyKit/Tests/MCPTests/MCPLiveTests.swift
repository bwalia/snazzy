import Foundation
import Testing
@testable import MCP
@testable import SnazzyCore

/// Talks to real public MCP servers. Opt in with SNAZZY_MCP_LIVE=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SNAZZY_MCP_LIVE"] == "1"))
struct MCPLiveTests {
    @Test(arguments: ["https://mcp.deepwiki.com/mcp", "https://mcp.context7.com/mcp"])
    func publicServer(_ address: String) async throws {
        let client = MCPClient(url: URL(string: address)!)
        try await client.connect()
        let tools = try await client.listTools()
        print("LIVE \(address): era=\(await client.era.map { "\($0)" } ?? "?") server=\(await client.serverName ?? "?") tools=\(tools.map(\.name))")
        #expect(!tools.isEmpty)
        if let first = tools.first(where: { $0.name == "read_wiki_structure" }) {
            let r = try await client.callTool(first.name, arguments: ["repoName": "modelcontextprotocol/swift-sdk"])
            print("LIVE call \(first.name): isError=\(r.isError) \(r.text.prefix(160).replacingOccurrences(of: "\n", with: " "))")
            #expect(!r.text.isEmpty)
        }
        if let resolve = tools.first(where: { $0.name == "resolve-library-id" }) {
            let r = try await client.callTool(resolve.name, arguments: ["libraryName": "swiftui", "query": "swiftui"])
            print("LIVE call \(resolve.name): isError=\(r.isError) \(r.text.prefix(160).replacingOccurrences(of: "\n", with: " "))")
        }
    }
}

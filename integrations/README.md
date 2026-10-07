# Using Snazzy Pro from AI agents (MCP)

Snazzy Pro runs an MCP server on your Mac (Streamable HTTP, 127.0.0.1 only,
bearer token). Turn it on in **Settings › MCP › Let AI agents use Snazzy Pro**;
that screen shows your token and ready-to-copy setup for each client.

| Client | Setup |
|---|---|
| **Claude Code** (plugin) | `/plugin marketplace add bwalia/snazzy` then `/plugin install snazzy-pro@snazzy-pro`, and set `SNAZZY_MCP_TOKEN` in your shell. |
| **Claude Code** (direct) | `claude mcp add --transport http snazzy-pro http://127.0.0.1:47823/mcp --header "Authorization: Bearer <token>"` |
| **Claude Desktop** | Add to `claude_desktop_config.json`: `{"mcpServers":{"snazzy-pro":{"command":"npx","args":["-y","mcp-remote","http://127.0.0.1:47823/mcp","--header","Authorization: Bearer <token>"]}}}` |
| **Cursor, VS Code, others** | An HTTP MCP server at `http://127.0.0.1:47823/mcp` with header `Authorization: Bearer <token>`. |

The other direction (Snazzy Pro using your data through MCP servers) is set up in
the same Settings tab under **Data sources**.

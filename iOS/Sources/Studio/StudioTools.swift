import Assistant
import Builder
import Foundation
import SnazzyCore

/// The tools the assistant uses on iPad/iPhone: build decks and prototypes in
/// the device's workspace and drive the preview.
@MainActor
enum StudioTools {
    static func registry(_ studio: StudioModel) -> ToolRegistry {
        let preview = studio.preview
        let ws = studio.workspace
        func object(_ props: [String: JSONValue], required: [String]) -> JSONValue {
            ["type": "object", "properties": .object(props), "required": .array(required.map { .string($0) })]
        }
        return ToolRegistry([
            RegisteredTool(
                name: "create_project",
                description: "Create (or reopen) a project with working starter files and open it in the preview. kind \"presentation\" = 16:9 HTML slide deck (index.html with <section class=\"slide\">, deck.css, deck.js); kind \"prototype\" = an app prototype.",
                inputSchema: object([
                    "name": ["type": "string", "minLength": 1],
                    "kind": ["type": "string", "enum": ["presentation", "prototype"]],
                    "title": ["type": "string"],
                ], required: ["name", "kind"])
            ) { @Sendable args in
                try await MainActor.run {
                    let kind = ProjectKind(rawValue: args["kind"]?.stringValue ?? "") ?? .presentation
                    let p = try ws.createProject(name: args["name"]?.stringValue ?? "project", kind: kind, title: args["title"]?.stringValue)
                    preview.open(p.name)
                    return ["project": .string(p.name), "files": .array(ws.files(project: p.name).map { .string($0) })] as JSONValue
                }
            },
            RegisteredTool(
                name: "write_file",
                description: "Create or replace a file in the open project with its COMPLETE content. The preview reloads.",
                inputSchema: object([
                    "path": ["type": "string", "minLength": 1],
                    "content": ["type": "string"],
                    "project": ["type": "string"],
                ], required: ["path", "content"])
            ) { @Sendable args in
                let name = try await MainActor.run { try projectName(args, preview) }
                try ws.write(project: name, path: args["path"]?.stringValue ?? "", content: args["content"]?.stringValue ?? "")
                await MainActor.run { if preview.current?.name != name { preview.open(name) } else { preview.reload() } }
                return ["wrote": .string(args["path"]?.stringValue ?? "")]
            },
            RegisteredTool(
                name: "read_file",
                description: "Read a file from the open project.",
                inputSchema: object(["path": ["type": "string"], "project": ["type": "string"]], required: ["path"])
            ) { @Sendable args in
                let name = try await MainActor.run { try projectName(args, preview) }
                return ["content": .string(try ws.read(project: name, path: args["path"]?.stringValue ?? ""))]
            },
            RegisteredTool(
                name: "list_files",
                description: "List the open project's files.",
                inputSchema: object(["project": ["type": "string"]], required: [])
            ) { @Sendable args in
                let name = try await MainActor.run { try projectName(args, preview) }
                return ["files": .array(ws.files(project: name).map { .string($0) })]
            },
            RegisteredTool(
                name: "check_preview",
                description: "Report the preview: title, number of slides, current slide and console errors. Call after writing files and fix any errors.",
                inputSchema: object([:], required: [])
            ) { @Sendable _ in await preview.report() },
            RegisteredTool(
                name: "show_slide",
                description: "Go to a slide of the open deck (0-based).",
                inputSchema: object(["index": ["type": "integer", "minimum": 0]], required: ["index"])
            ) { @Sendable args in
                await MainActor.run { preview.goToSlide(args["index"]?.intValue ?? 0) }
                return await preview.report()
            },
            RegisteredTool(
                name: "open_sample_deck",
                description: "Open an example deck to start from. Samples: " + SampleDeck.all.map { "\($0.id) (\($0.sector.rawValue))" }.joined(separator: "; "),
                inputSchema: object(["id": ["type": "string", "enum": .array(SampleDeck.all.map { .string($0.id) })]], required: ["id"])
            ) { @Sendable args in
                try await MainActor.run {
                    guard let s = SampleDeck.all.first(where: { $0.id == args["id"]?.stringValue }) else { throw WorkspaceError("Unknown sample") }
                    let p = try ws.createSample(s)
                    preview.open(p.name)
                    return ["project": .string(p.name)] as JSONValue
                }
            },
        ])
    }

    /// The project a tool call names, or the open one.
    static func projectName(_ args: JSONValue, _ preview: StudioPreview) throws -> String {
        if let p = args["project"]?.stringValue, !p.isEmpty { return Workspace.slug(p) }
        guard let p = preview.current?.name else { throw WorkspaceError("No project is open. Create one first.") }
        return p
    }
}

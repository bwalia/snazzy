import Foundation
import Testing
@testable import Builder

@Suite struct PartialJSONTests {
    @Test func readsIncompleteValues() {
        #expect(PartialJSON.stringValue(forKey: "content", in: #"{"project":"x","path":"index.html","content":"<h1>Hi"#) == "<h1>Hi")
        #expect(PartialJSON.stringValue(forKey: "content", in: #"{"path":"a","con"#) == nil)
        #expect(PartialJSON.stringValue(forKey: "content", in: #"{"content": "#) == nil)
        #expect(PartialJSON.stringValue(forKey: "path", in: #"{"path":"js/app.js","content":"x"}"#) == "js/app.js")
    }

    @Test func decodesEscapes() {
        let text = #"{"content":"line1\nline2\t\"q\" \\ é 😀 end"}"#
        #expect(PartialJSON.stringValue(forKey: "content", in: text) == "line1\nline2\t\"q\" \\ é 😀 end")
        // An escape split across stream fragments is held back until complete.
        #expect(PartialJSON.stringValue(forKey: "content", in: #"{"content":"a\"#) == "a")
        #expect(PartialJSON.stringValue(forKey: "content", in: #"{"content":"a\u00"#) == "a")
    }

    @Test func ignoresNestedAndValueStrings() {
        let text = #"{"meta":{"content":"nested"},"title":"content","content":"top"}"#
        #expect(PartialJSON.stringValue(forKey: "content", in: text) == "top")
    }
}

@Suite struct WorkspaceTests {
    func temp() -> Workspace {
        Workspace(root: FileManager.default.temporaryDirectory.appending(path: "snazzy-ws-\(UUID().uuidString)"))
    }

    @Test func createWriteReadList() throws {
        let ws = temp()
        defer { try? FileManager.default.removeItem(at: ws.root) }
        let project = try ws.createProject(name: "Q3 DevOps Results!", kind: .presentation)
        #expect(project.name == "q3-devops-results")
        #expect(ws.files(project: project.name) == ["deck.css", "deck.js", "index.html"])
        #expect(try ws.read(project: project.name, path: "index.html").contains("Q3 DevOps Results!"))
        try ws.write(project: project.name, path: "img/notes.txt", content: "hi")
        #expect(try ws.read(project: project.name, path: "img/notes.txt") == "hi")
        #expect(ws.listProjects().map(\.name) == ["q3-devops-results"])
        // Creating again returns the existing project untouched.
        #expect(try ws.createProject(name: "q3 devops results", kind: .prototype).kind == .presentation)
        try ws.delete(project: project.name, path: "img/notes.txt")
        #expect(!ws.files(project: project.name).contains("img/notes.txt"))
    }

    @Test func rejectsPathsOutsideTheProject() throws {
        let ws = temp()
        defer { try? FileManager.default.removeItem(at: ws.root) }
        try ws.createProject(name: "demo", kind: .prototype)
        for bad in ["../other/index.html", "/etc/passwd", "~/x", "a/../../b", "", ".snazzy-project.json"] {
            #expect(throws: WorkspaceError.self) { try ws.write(project: "demo", path: bad, content: "x") }
        }
        #expect(try ws.resolve(project: "demo", path: "a/../b.txt").lastPathComponent == "b.txt")
    }

    @Test func slugs() {
        #expect(Workspace.slug("  Hello, World  ") == "hello-world")
        #expect(Workspace.slug("!!!") == "project")
    }
}

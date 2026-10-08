import Foundation
import Testing
@testable import Builder
import SnazzyCore

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
        // A symlink inside the project can't lead out of it.
        let outside = ws.root.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: ws.projectURL("demo").appending(path: "link"), withDestinationURL: outside)
        #expect(throws: WorkspaceError.self) { try ws.write(project: "demo", path: "link/x.txt", content: "x") }
        #expect(!FileManager.default.fileExists(atPath: outside.appending(path: "x.txt").path))
    }

    @Test func slugs() {
        #expect(Workspace.slug("  Hello, World  ") == "hello-world")
        #expect(Workspace.slug("!!!") == "project")
        // ASCII, so it works as the project's URL host.
        #expect(Workspace.slug("Café Q3 日本") == "cafe-q3-ri-ben")
    }
}

@Suite struct SampleDeckTests {
    @Test func everySectorHasAWellFormedSample() throws {
        let ids = SampleDeck.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(Set(SampleDeck.all.map(\.sector)) == Set(SampleDeck.Sector.allCases))
        for deck in SampleDeck.all {
            #expect(deck.slides.count >= 4, "\(deck.id)")
            #expect(deck.slides.first?.layout == .title, "\(deck.id)")
            #expect(!deck.prompt.isEmpty && !deck.setup.isEmpty, "\(deck.id)")
            for s in deck.slides where s.layout == .stats { #expect(s.items.count % 2 == 0, "\(deck.id): \(s.heading)") }
            let html = deck.html()
            #expect(html.components(separatedBy: "<section class=\"slide").count - 1 == deck.slides.count)
        }
    }

    @Test func escapesText() {
        let html = SampleDeck.render(.init(.bullets, "A & <b>", ["\"x\""]))
        #expect(html.contains("A &amp; &lt;b&gt;") && html.contains("&quot;x&quot;"))
    }

    @Test func createsProjectAndReplacesEarlierCopy() throws {
        let ws = Workspace(root: FileManager.default.temporaryDirectory.appending(path: "snazzy-ws-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: ws.root) }
        let sample = SampleDeck.all[0]
        let p = try ws.createSample(sample)
        try ws.write(project: p.name, path: "index.html", content: "edited")
        let again = try ws.createSample(sample)
        #expect(again.kind == .presentation)
        #expect(ws.files(project: again.name) == ["deck.css", "deck.js", "index.html"])
        #expect(try ws.read(project: again.name, path: "index.html").contains(sample.title))
    }
}

@Suite struct SnazzyShareTests {
    func temp() -> Workspace {
        Workspace(root: FileManager.default.temporaryDirectory.appending(path: "snazzy-ws-\(UUID().uuidString)"))
    }

    func presetWithImage(_ id: String) -> SettingsPreset {
        var setup = CaptureSetup()
        setup.profiles["cam-1"] = DeviceProfile(crop: InsetCrop(), background: .image(id: id))
        setup.profiles["cam-2"] = DeviceProfile(crop: InsetCrop(), background: .blur(strength: 0.5))
        return SettingsPreset(name: "Lesson setup", capture: setup, app: nil)
    }

    @Test func roundTripsProjectPresetsAndImages() throws {
        let ws = temp()
        defer { try? FileManager.default.removeItem(at: ws.root) }
        let deck = try ws.createSample(SampleDeck.all[0])
        let bytes = Data([0, 1, 2, 255])
        let dir = ws.projectURL(deck.name).appending(path: "img")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try bytes.write(to: dir.appending(path: "logo.png"))
        try Data("x".utf8).write(to: ws.projectURL(deck.name).appending(path: ".DS_Store"))

        let shared = try ws.shareProject(deck.name)
        #expect(shared.files.map(\.path) == ["deck.css", "deck.js", "img/logo.png", "index.html"])
        let share = SnazzyShare(title: "Lesson", note: "For Monday", project: shared,
                                presets: [presetWithImage("abc123")],
                                backgrounds: [.init(id: "abc123", name: "Classroom", data: Data([9, 9]))])
        let data = try share.encoded()
        #expect(data.prefix(8) == Data("SNZSHR01".utf8))
        let back = try SnazzyShare.decode(data)
        #expect(back.title == "Lesson" && back.note == "For Monday")
        #expect(back.project == share.project && back.backgrounds == share.backgrounds)
        #expect(back.presets.first?.capture?.profiles["cam-1"]?.background == .image(id: "abc123"))
        #expect(back.contentsSummary.count == 3)

        // Import into a workspace that already has a project with that name.
        let imported = try ws.importProject(back.project!)
        #expect(imported.name == deck.name + "-2" && imported.kind == .presentation)
        #expect(try Data(contentsOf: ws.projectURL(imported.name).appending(path: "img/logo.png")) == bytes)
        #expect(try ws.read(project: imported.name, path: "index.html") == ws.read(project: deck.name, path: "index.html"))

        // Someone else's project starts offline (no internet for its pages); yours never is.
        #expect(ws.project(imported.name)?.shared == true)
        #expect(ws.project(deck.name)?.shared == nil)
        try ws.setShared(imported.name, false)
        #expect(ws.project(imported.name)?.shared == nil)
    }

    @Test func findsAndRemapsBackgroundImages() {
        let preset = presetWithImage("old1")
        #expect(SnazzyShare.imageIDs(in: preset) == ["old1"])
        let remapped = SnazzyShare.remapImages(in: preset, ["old1": "new9"])
        #expect(remapped.capture?.profiles["cam-1"]?.background == .image(id: "new9"))
        #expect(remapped.capture?.profiles["cam-2"]?.background == .blur(strength: 0.5))
        #expect(remapped.name == preset.name)
    }

    @Test func rejectsUnsafeOrForeignFiles() throws {
        for bad in ["../x", "/etc/passwd", "a/../../b", "~/x", ".hidden", "a/.git/config", "a\\b", "", "a//b", "a/./b", ".snazzy-project.json"] {
            #expect(!SnazzyShare.isSafeRelativePath(bad), "\(bad)")
        }
        #expect(SnazzyShare.isSafeRelativePath("img/photo 1.png"))

        #expect(throws: WorkspaceError.self) { try SnazzyShare.decode(Data("hello".utf8)) }
        let evil = SnazzyShare(title: "x", project: .init(name: "p", kind: .prototype, files: [.init(path: "../../escape.txt", data: Data())]))
        #expect(throws: WorkspaceError.self) { try SnazzyShare.decode(try evil.encoded()) }
        // Damaged data after a valid header.
        #expect(throws: WorkspaceError.self) { try SnazzyShare.decode(Data("SNZSHR01".utf8) + Data(repeating: 7, count: 100)) }
    }

    @Test func capsDecompressedSize() throws {
        // 50 MB of zeros compresses to ~50 KB; a small limit must stop it.
        let bomb = try (Data(count: 50_000_000) as NSData).compressed(using: .zlib) as Data
        #expect(bomb.count < 1_000_000)
        #expect(throws: WorkspaceError.self) { try SnazzyShare.inflate(bomb, limit: 1_000_000) }
        #expect(try SnazzyShare.inflate(bomb, limit: 60_000_000).count == 50_000_000)
    }
}

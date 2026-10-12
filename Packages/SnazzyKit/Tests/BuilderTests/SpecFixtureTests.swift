import Foundation
import Testing
@testable import Builder
import SnazzyCore

/// Fixtures for the shared formats in `docs/specs/`, generated from this code so
/// the Windows/Linux app (Rust, `desktop/`) can test against exactly what the Mac
/// writes. `SNAZZY_WRITE_FIXTURES=1 swift test --filter SpecFixture` rewrites
/// them; otherwise the committed fixtures must still match.
enum SpecFixtures {
    static let directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // BuilderTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // SnazzyKit
        .deletingLastPathComponent()  // Packages
        .deletingLastPathComponent()  // repo
        .appending(path: "docs/specs/fixtures", directoryHint: .isDirectory)

    static var writing: Bool { ProcessInfo.processInfo.environment["SNAZZY_WRITE_FIXTURES"] == "1" }

    /// Writes (SNAZZY_WRITE_FIXTURES=1) or checks a fixture byte for byte.
    static func check(_ name: String, _ data: Data, sourceLocation: SourceLocation = #_sourceLocation) {
        let url = directory.appending(path: name)
        if writing {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            #expect(throws: Never.self, sourceLocation: sourceLocation) { try data.write(to: url) }
            return
        }
        let committed = try? Data(contentsOf: url)
        #expect(committed == data, "docs/specs/fixtures/\(name) is out of date: run SNAZZY_WRITE_FIXTURES=1 swift test", sourceLocation: sourceLocation)
    }

    static func check(_ name: String, text: String, sourceLocation: SourceLocation = #_sourceLocation) {
        check(name, Data(text.utf8), sourceLocation: sourceLocation)
    }

    /// Case files: readable, deterministic JSON.
    static func check<T: Encodable>(_ name: String, cases: T, sourceLocation: SourceLocation = #_sourceLocation) {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        let data = (try? e.encode(cases)) ?? Data()
        check(name, data + Data("\n".utf8), sourceLocation: sourceLocation)
    }

    static func read(_ name: String) -> Data? { try? Data(contentsOf: directory.appending(path: name)) }

    /// 2026-01-02T03:04:05Z: every date in the fixtures.
    static let date = Date(timeIntervalSince1970: 1_767_323_045)

    static func tempWorkspace() -> Workspace {
        Workspace(root: FileManager.default.temporaryDirectory.appending(path: "snazzy-spec-\(UUID().uuidString)"))
    }
}

@Suite(.serialized) struct SpecFixtureTests {
    // MARK: Samples, templates, deck pages

    struct SampleOut: Codable, Equatable {
        var id, sector, title, useCase, audience, prompt, accent, projectName: String
        var minutes: Int
        var setup: [String]
        var slides: [SampleDeck.Slide]
    }

    @Test func samples() throws {
        let out = SampleDeck.all.map {
            SampleOut(id: $0.id, sector: $0.sector.rawValue, title: $0.title, useCase: $0.useCase, audience: $0.audience,
                      prompt: $0.prompt, accent: $0.accent, projectName: $0.projectName, minutes: $0.minutes, setup: $0.setup, slides: $0.slides)
        }
        SpecFixtures.check("samples.json", cases: out)
        if !SpecFixtures.writing, let data = SpecFixtures.read("samples.json") {
            #expect(try JSONDecoder().decode([SampleOut].self, from: data) == out)
        }
        for id in ["lesson-photosynthesis", "board-results", "build-ship-ai"] {
            let sample = try #require(SampleDeck.all.first { $0.id == id })
            SpecFixtures.check("deck-\(id).html", text: sample.html())
        }
    }

    static let templateTitle = "Q3 <Results> & \"more\""

    @Test func templates() {
        for (path, content) in Templates.files(for: .presentation, title: Self.templateTitle) {
            SpecFixtures.check(path == "index.html" ? "template-presentation-index.html" : path, text: content)
        }
        for (path, content) in Templates.files(for: .prototype, title: Self.templateTitle) {
            SpecFixtures.check("template-prototype-\(path)", text: content)
        }
        SpecFixtures.check("templates.json", cases: [
            "title": Self.templateTitle,
            "presentation": Templates.files(for: .presentation, title: Self.templateTitle).map(\.0).joined(separator: ","),
            "prototype": Templates.files(for: .prototype, title: Self.templateTitle).map(\.0).joined(separator: ","),
        ])
    }

    /// An outline that uses every layout and the edge cases of each.
    static let outline = DeckOutline(title: "Q3 review: A/B tests & <more>", accent: "#D946EF", slides: [
        .init(.title, "Q3 review", ["Café results, 2026"], notes: "Hello & welcome."),
        .init(.title, "No subtitle"),
        .init(.bullets, "What we'll cover", ["Wins", "Misses", "Next steps"], notes: "Keep it \"short\"."),
        .init(.bullets, "Empty list"),
        .init(.stats, "Numbers", ["42%", "growth", "3×", "faster", "odd one out"]),
        .init(.stats, "One number", ["7"]),
        .init(.columns, "Before / after", ["Before", "Slow", "Manual", "After", "Fast"]),
        .init(.columns, "One column", ["Only"]),
        .init(.columns, "No columns"),
        .init(.quote, "Ship small, ship often", ["Ada, CTO"]),
        .init(.quote, "Anonymous"),
        .init(.steps, "How", ["Plan", "Build", "Record"], notes: "Line one\nline two"),
        .init(.closing, "Thank you", ["Questions?"]),
    ])

    @Test func deckOutline() throws {
        let ws = SpecFixtures.tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }
        let project = try ws.createProject(name: "deck", kind: .presentation)
        try Self.outline.save(to: ws, project: project.name)
        SpecFixtures.check("deck.json", text: try ws.read(project: project.name, path: DeckOutline.fileName))
        SpecFixtures.check("deck-outline.html", text: Self.outline.html())
        #expect(try ws.read(project: project.name, path: "index.html") == Self.outline.html())
        SpecFixtures.check("deck-starter.json", cases: DeckOutline.starter(title: "New deck"))
        if !SpecFixtures.writing, let data = SpecFixtures.read("deck.json") {
            #expect(try JSONDecoder().decode(DeckOutline.self, from: data) == Self.outline)
        }
    }

    // MARK: Projects and workspace

    @Test func projectFiles() throws {
        let full = BuilderProject(name: "q3-review", kind: .presentation, created: SpecFixtures.date, shared: true,
                                  category: "Finance", tags: ["Board", "Q3"], origin: "github:bwalia/snazzy/decks/q3-review")
        let old = BuilderProject(name: "old-prototype", kind: .prototype, created: SpecFixtures.date)
        SpecFixtures.check("project.json", try JSONEncoder.iso.encode(full))
        SpecFixtures.check("project-old.json", try JSONEncoder.iso.encode(old))
        if !SpecFixtures.writing {
            #expect(try JSONDecoder.iso.decode(BuilderProject.self, from: SpecFixtures.read("project.json") ?? Data()) == full)
            #expect(try JSONDecoder.iso.decode(BuilderProject.self, from: SpecFixtures.read("project-old.json") ?? Data()) == old)
        }
    }

    struct DetailsCase: Codable {
        var category: String?
        var tags: [String]
        var origin: String?
        var resultCategory: String?
        var resultTags: [String]?
        var resultOrigin: String?
    }

    struct ResolveCase: Codable {
        var path: String
        var resolved: String?
        var error: String?
    }

    @Test func workspaceRules() throws {
        let slugs = ["Q3 DevOps Results!", "Café déjà vu", "  --Hello__World--  ", "Ünïcödé Straße", "", "!!!", "ÆØÅ æøå", "Ça va? Œuvre",
                     "Crème brûlée & piña colada", "naïve façade", String(repeating: "abcdefghij", count: 7), "日本", "Привет мир", "a/b\\c.d", "Tab\tNew\nLine", "x1 2y"]
        let cleanTags = [["  Q3 ", "#Board", "q3", "", "  ", "board", "Sales#Team"], [], ["#", "A", "a", "B"]]
        let ws = SpecFixtures.tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }
        let p = try ws.createProject(name: "proj", kind: .presentation)
        var details: [DetailsCase] = []
        let longTag = String(repeating: "t", count: 50)
        for (category, tags, origin) in [("  Finance  ", ["Board", "board", "#Q3"], "github:o/r/d"), ("", [], nil), (String(repeating: "c", count: 70), [longTag] + (1...25).map { "tag\($0)" }, nil),
                                         (nil, ["  "], nil)] as [(String?, [String], String?)] {
            let r = try ws.setDetails(p.name, category: category, tags: tags, origin: origin)
            details.append(DetailsCase(category: category, tags: tags, origin: origin, resultCategory: r.category, resultTags: r.tags, resultOrigin: r.origin))
        }
        // Symlinks are refused even when they point inside.
        try FileManager.default.createDirectory(at: ws.projectURL(p.name).appending(path: "real"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: ws.projectURL(p.name).appending(path: "link"), withDestinationURL: ws.projectURL(p.name).appending(path: "real"))
        let paths = ["index.html", "js/app.js", "  css/a.css  ", "/etc/passwd", "~/x", "", "   ", "../x", "a/../../x", "a/../b.html", "./c.html", ".snazzy-project.json",
                     "sub/.snazzy-x", ".hidden", "link/file.txt", "link", "real/file.txt", "a//b", "..", "."]
        let dir = ws.projectURL(p.name).standardizedFileURL.path + "/"
        let resolve = paths.map { path -> ResolveCase in
            do {
                let url = try ws.resolve(project: p.name, path: path)
                return ResolveCase(path: path, resolved: String(url.path.dropFirst(dir.count)))
            } catch {
                return ResolveCase(path: path, error: (error as? WorkspaceError)?.message ?? "\(error)")
            }
        }
        var writeLimit: [String: String] = [:]
        writeLimit["2000000"] = (try? ws.write(project: p.name, path: "big.txt", content: String(repeating: "a", count: 2_000_000))) == nil ? "error" : "ok"
        do { try ws.write(project: p.name, path: "big.txt", content: String(repeating: "a", count: 2_000_001)); writeLimit["2000001"] = "ok" } catch {
            writeLimit["2000001"] = (error as? WorkspaceError)?.message ?? "\(error)"
        }
        struct Out: Codable {
            var maxFileBytes: Int
            var slug: [[String]]
            var cleanTags: [[[String]]]
            var setDetails: [DetailsCase]
            var resolve: [ResolveCase]
            var writeLimit: [String: String]
        }
        SpecFixtures.check("workspace-cases.json", cases: Out(
            maxFileBytes: Workspace.maxFileBytes,
            slug: slugs.map { [$0, Workspace.slug($0)] },
            cleanTags: cleanTags.map { [$0, BuilderProject.cleanTags($0)] },
            setDetails: details, resolve: resolve, writeLimit: writeLimit))
    }

    // MARK: .snazzy

    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0xFF, 0xFE, 0x00, 0x7F])

    static func share() -> SnazzyShare {
        var capture = CaptureSetup(insetDevice: InsetDeviceSelection(uniqueID: "cam-1", name: "Studio camera", kind: .camera),
                                   layout: InsetLayout(corner: .bottomLeft, size: 0.3))
        capture.profiles["cam-1"] = DeviceProfile(crop: InsetCrop(zoom: 0.9), background: .image(id: "bg-1"))
        let preset = SettingsPreset(name: "Lesson setup", notes: "Camera bottom-left", capture: capture, app: .default, date: SpecFixtures.date)
        let project = SnazzyShare.Project(name: "q3-review", kind: .presentation, files: [
            .init(path: "index.html", data: Data("<!doctype html><title>Q3 / review</title>\n".utf8)),
            .init(path: "img/logo.png", data: png),
        ])
        return SnazzyShare(title: "Q3 review", note: "Here's the deck for Monday", project: project, presets: [preset],
                           backgrounds: [.init(id: "bg-1", name: "Studio wall", data: Data([1, 2, 3, 250, 251, 252]))], created: SpecFixtures.date)
    }

    /// The JSON inside a .snazzy file, exactly as `encoded()` writes it.
    static func shareJSON(_ share: SnazzyShare) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(share)
    }

    static func pack(_ json: Data) throws -> Data {
        SnazzyShare.magic + (try (json as NSData).compressed(using: .zlib) as Data)
    }

    struct ShareCase: Codable {
        var name: String
        var file: String  // base64 of the whole file
        var error: String?
    }

    @Test func shareFiles() throws {
        let share = Self.share()
        let encoded = try share.encoded()
        let json = try Self.shareJSON(share)
        #expect(try SnazzyShare.inflate(encoded.dropFirst(8), limit: SnazzyShare.maxExpandedBytes) == json)
        SpecFixtures.check("share-basic.snazzy", encoded)
        SpecFixtures.check("share-basic.json", json)
        let empty = SnazzyShare(title: "Nothing", project: nil, created: SpecFixtures.date)
        SpecFixtures.check("share-empty.snazzy", try empty.encoded())
        SpecFixtures.check("share-empty.json", try Self.shareJSON(empty))
        if !SpecFixtures.writing {
            #expect(try SnazzyShare.decode(SpecFixtures.read("share-basic.snazzy") ?? Data()) == share)
            #expect(try SnazzyShare.decode(SpecFixtures.read("share-empty.snazzy") ?? Data()) == empty)
            // Written by the Rust code (desktop/crates/snazzy-core); the Mac must open it.
            if let rust = SpecFixtures.read("share-from-rust.snazzy") {
                #expect(try SnazzyShare.decode(rust) == share)
            }
        }

        // Files that must be refused, and why.
        func variant(_ edit: (inout [String: Any]) -> Void) throws -> Data {
            var object = try JSONSerialization.jsonObject(with: json) as! [String: Any]
            edit(&object)
            return try Self.pack(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
        }
        func files(_ paths: [String]) -> (inout [String: Any]) -> Void {
            { o in
                var p = o["project"] as! [String: Any]
                p["files"] = paths.map { ["path": $0, "data": "aGk="] }
                o["project"] = p
            }
        }
        var cases: [(String, Data)] = [
            ("valid", encoded),
            ("bad magic", Data("SNZSHR02".utf8) + encoded.dropFirst(8)),
            ("not deflate", SnazzyShare.magic + Data("not compressed at all".utf8)),
            ("newer version", try variant { $0["version"] = 2 }),
            ("other format", try variant { $0["format"] = "something-else" }),
            ("missing title", try variant { $0.removeValue(forKey: "title") }),
            ("unknown field ignored", try variant { $0["future"] = ["x": 1] }),
            ("parent path", try variant(files(["../evil.html"]))),
            ("absolute path", try variant(files(["/etc/passwd"]))),
            ("hidden file", try variant(files([".htaccess"]))),
            ("hidden folder", try variant(files(["a/.git/config"]))),
            ("backslash", try variant(files(["a\\b.html"]))),
            ("control char", try variant(files(["a\u{7}.html"]))),
            ("empty component", try variant(files(["a//b.html"]))),
            ("trailing slash", try variant(files(["a/"]))),
            ("tilde", try variant(files(["~/x"]))),
            ("duplicate ignoring case", try variant(files(["A.html", "a.html"]))),
            ("too many backgrounds", try variant { o in o["backgrounds"] = (0...SnazzyShare.maxImages).map { ["id": "b\($0)", "name": "n", "data": ""] } }),
        ]
        cases.append(("long path", try variant(files([String(repeating: "a", count: 512)]))))
        cases.append(("path under 512", try variant(files([String(repeating: "a", count: 511)]))))
        let out = cases.map { name, data -> ShareCase in
            do { _ = try SnazzyShare.decode(data); return ShareCase(name: name, file: data.base64EncodedString()) } catch {
                return ShareCase(name: name, file: data.base64EncodedString(), error: (error as? WorkspaceError)?.message ?? "\(error)")
            }
        }
        let preset = share.presets[0]
        struct Out: Codable {
            var limits: [String: Int]
            var cases: [ShareCase]
            var safePaths: [String: Bool]
            var imageIDs: [String]
        }
        let paths = ["index.html", "img/a.png", "a b/c.html", "café.html", "../x", "a/../b", "./a", ".a", "a/.b", "/a", "~a", "a\\b", "", "a//b", "a/", "a\u{0}b", "a\u{85}b", "a\u{7F}b"]
        SpecFixtures.check("share-cases.json", cases: Out(
            limits: ["maxCompressedBytes": SnazzyShare.maxCompressedBytes, "maxExpandedBytes": SnazzyShare.maxExpandedBytes, "maxFiles": SnazzyShare.maxFiles,
                     "maxFileBytes": SnazzyShare.maxFileBytes, "maxImages": SnazzyShare.maxImages, "maxPresets": SnazzyShare.maxPresets, "version": 1],
            cases: out,
            safePaths: Dictionary(uniqueKeysWithValues: paths.map { ($0, SnazzyShare.isSafeRelativePath($0)) }),
            imageIDs: SnazzyShare.imageIDs(in: preset).sorted()))
    }

    // MARK: Search

    struct DeckIn: Codable {
        var project: String?
        var sample: String?
        var title: String
        var category: String?
        var tags: [String]
        var slides: [SlideIO]

        var deck: DeckSearch.Deck {
            DeckSearch.Deck(source: project.map(DeckSearch.Deck.Source.project) ?? .sample(sample ?? ""), title: title, category: category, tags: tags,
                            slides: slides.map { DeckSearch.Slide(heading: $0.heading, text: $0.text, notes: $0.notes) })
        }
    }

    struct SlideIO: Codable, Equatable {
        var heading: String
        var text: String
        var notes: String
        init(_ s: DeckSearch.Slide) { heading = s.heading; text = s.text; notes = s.notes }
        init(heading: String, text: String, notes: String) { self.heading = heading; self.text = text; self.notes = notes }
    }

    struct HitOut: Codable {
        var project: String?
        var sample: String?
        var deckTitle: String
        var slide: Int
        var heading: String
        var field: String
        var snippet: String
        var score: Int
    }

    struct QueryCase: Codable {
        var query: String
        var limit: Int?
        var hits: [HitOut]
    }

    struct HTMLCase: Codable {
        var name: String
        var html: String
        var title: String?
        var slides: [SlideIO]
    }

    static func hits(_ query: String, _ decks: [DeckSearch.Deck], limit: Int = 200) -> [HitOut] {
        DeckSearch.search(query, in: decks, limit: limit).map { h in
            var project: String?, sample: String?
            switch h.deck {
            case .project(let p): project = p
            case .sample(let s): sample = s
            }
            return HitOut(project: project, sample: sample, deckTitle: h.deckTitle, slide: h.slide, heading: h.heading, field: h.field.rawValue,
                          snippet: h.snippet, score: h.score)
        }
    }

    @Test func search() throws {
        let long = "Our platform team rebuilt the deploy pipeline this quarter so every service ships from main within twenty minutes of a merge, " +
            "with automatic rollbacks, canary checks and a dashboard showing the error budget for each team at a glance, plus café-style status pages."
        var decks: [DeckIn] = [
            DeckIn(project: "q3-review", title: "Q3 review", category: "Finance", tags: ["Board", "Quarterly"], slides: [
                SlideIO(heading: "Q3 revenue", text: "Revenue up 12% · Costs flat", notes: "Mention the café partnership."),
                SlideIO(heading: "", text: "A slide without a heading", notes: ""),
                SlideIO(heading: "Platform", text: long, notes: "Deploy pipeline details."),
                SlideIO(heading: "Naïve forecasts", text: "Résumé of FULLWIDTH ＡＢＣ text", notes: "Crème brûlée for everyone"),
            ]),
            DeckIn(project: "team-intro", title: "Team intro", tags: [], slides: [
                SlideIO(heading: "Who we are", text: "Engineers · Designers", notes: "Revenue is not our job."),
                SlideIO(heading: "Deploy pipeline", text: "From merge to production", notes: ""),
            ]),
        ]
        decks += SampleDeck.all.map { s in
            DeckIn(sample: s.id, title: s.title, category: s.sector.rawValue, tags: ["Sample"],
                   slides: s.slides.map { SlideIO(DeckSearch.slide(from: $0)) })
        }
        let all = decks.map(\.deck)
        let queries = ["revenue", "Revenue Q3", "q3 revenue", "deploy pipeline", "pipeline deploy", "cafe", "CAFÉ", "naive", "resume abc", "creme brulee",
                       "board", "finance", "sample oxygen", "photosynthesis", "oxygen", "plankton", "slide", "heading", "zzz", "", "   ", "team", "rollbacks",
                       "error budget", "dashboard", "glance", "ＡＢＣ", "safety", "the", "a", "router reset", "menu", "release"]
        var cases = queries.map { QueryCase(query: $0, hits: Self.hits($0, all)) }
        cases.append(QueryCase(query: "the", limit: 3, hits: Self.hits("the", all, limit: 3)))

        let htmlCases: [(String, String)] = [
            ("basic", """
            <html><head><title>My &amp; deck</title><style>.slide { color: red }</style></head><body>
            <section class="slide title"><h1>Hello <em>world</em></h1><p class="subtitle">Sub</p><aside class="notes">Say hi &mdash; then go.</aside></section>
            <section class='slide'><h2>List</h2><ul><li>One</li><li>Two &lt;b&gt;</li></ul><aside class="notes speaker">A</aside><aside class="notes">B</aside></section>
            <section class="slideshow"><h2>Not a slide</h2></section>
            <SECTION CLASS="Slide layout-quote"><blockquote>Quote</blockquote><p class="by">— Ada</p></SECTION>
            <section class="slide"><div class="cols"><div><h3>Left</h3><ul><li>a</li></ul></div><div><h3>Right</h3><ul><li>b</li></ul></div></div></section>
            <script>document.write('<section class="slide"><h2>From script</h2></section>')</script>
            </body></html>
            """),
            ("entities", #"<section class="slide"><h2>&#65;&#x42;&#x1F600; &#12ab; &#xD800; &rarr; &hellip; &middot; &nbsp;x&apos;&#39;&quot;&ndash;&amp;lt;</h2><p>a<br>b<br/>c</p></section>"#),
            ("separators", #"<section class="slide"><ul><li>·</li><li>x</li></ul><h4>y</h4><table><tr><td>1</td><th>2</th></tr></table></section>"#),
            ("no slides", "<html><title></title><body><p>Nothing</p></body></html>"),
            ("heading prefix", #"<section class="slide"><h2>Plan</h2><p>Plan ahead</p></section>"#),
            ("nested script style", "<section class=\"slide\"><h2>A</h2><STYLE>h2{}</STYLE><script type=\"x\">if (a < b) {}</script>text</section>"),
            ("multiline", "<section\n  class=\"slide\"\n  data-x=\"1\">\n<h1>\n  Multi\n  line\n</h1>\n<aside class=\"notes\">\n n1\n</aside>\n</section>"),
        ]
        var html = htmlCases.map { HTMLCase(name: $0.0, html: $0.1, title: DeckSearch.title(fromHTML: $0.1), slides: DeckSearch.slides(fromHTML: $0.1).map(SlideIO.init)) }
        for id in ["lesson-photosynthesis", "board-results", "build-ship-ai"] {
            let s = try #require(SampleDeck.all.first { $0.id == id })
            html.append(HTMLCase(name: "deck-\(id).html", html: "", title: DeckSearch.title(fromHTML: s.html()), slides: DeckSearch.slides(fromHTML: s.html()).map(SlideIO.init)))
        }
        html.append(HTMLCase(name: "deck-outline.html", html: "", title: DeckSearch.title(fromHTML: Self.outline.html()),
                             slides: DeckSearch.slides(fromHTML: Self.outline.html()).map(SlideIO.init)))

        let snippetWords = [["deploy"], ["glance"], ["pages"], ["zzz"], ["our"], ["cafe"]]
        struct SnippetCase: Codable { var text: String; var words: [String]; var width: Int; var snippet: String }
        var snippets = snippetWords.map { SnippetCase(text: long, words: $0, width: 140, snippet: DeckSearch.snippet(long, around: $0)) }
        snippets.append(SnippetCase(text: long, words: ["rollbacks"], width: 40, snippet: DeckSearch.snippet(long, around: ["rollbacks"], width: 40)))
        snippets.append(SnippetCase(text: "  short text  ", words: ["short"], width: 140, snippet: DeckSearch.snippet("  short text  ", around: ["short"])))

        let folds = ["Café", "CRÈME BRÛLÉE", "naïve", "Ångström", "ÆØÅ", "Straße", "ＡＢＣ１２３", "Ça", "Œuvre", "Łódź", "ǅ", "ﬁ", "İstanbul", "Ελληνικά", "ﾃｽﾄ"]
        struct Out: Codable {
            var decks: [DeckIn]
            var queries: [QueryCase]
            var html: [HTMLCase]
            var snippets: [SnippetCase]
            var fold: [[String]]
            var plain: [[String]]
        }
        let plains = ["<p>a</p><p>b</p>", "<ul><li>x</li><li>y</li></ul>", "  lots   of\n\tspace ", "<b>bold</b>text", "&amp;lt;", "· · a · · b ·", "<h3>L</h3>z"]
        SpecFixtures.check("search-cases.json", cases: Out(decks: decks, queries: cases, html: html, snippets: snippets,
                                                          fold: folds.map { [$0, DeckSearch.fold($0)] },
                                                          plain: plains.map { [$0, DeckSearch.plain($0)] }))
    }

    // MARK: Deck repos

    struct RepoOut: Codable {
        var owner, repo, path, name, id, webURL, repoAPI, treeAPI, rawURL: String
        var branch: String?
    }

    struct DecksCase: Codable {
        var name: String
        var repo: DeckRepo
        var branch: String
        var tree: [DeckRepoCatalogue.TreeEntry]
        var catalogue: DeckRepoCatalogue.Catalogue?
        var decks: [RemoteDeck]
        var origins: [String]
        var webURLs: [String]
    }

    @Test func deckRepos() throws {
        let inputs = ["bwalia/snazzy", "bwalia/snazzy/decks", "  github.com/bwalia/snazzy  ", "https://github.com/bwalia/snazzy/tree/main/decks",
                      "http://www.github.com/bwalia/snazzy.git", "https://github.com/o/r/blob/feature/x/index.html", "https://github.com/o/r/tree/HEAD",
                      "https://github.com/o/r?tab=readme#top", "GitHub.com/o/r", "o", "", "o/..", "o/.", "o/r/../x", "bad_owner/r", "o/r/a b", "o/r.js",
                      "o/r/tree", "o/r/tree/main", "o/r/tree/../x", "-o-/r_x.y", String(repeating: "a", count: 40) + "/r", String(repeating: "a", count: 39) + "/r",
                      "o/" + String(repeating: "r", count: 101), "ö/r", "o/r//deep///path/", "https://github.com/o/r/tree/v1.0/a/b?x=1"]
        let parsed: [[String: RepoOut?]] = inputs.map { input in
            [input: DeckRepo.parse(input).map { r in
                RepoOut(owner: r.owner, repo: r.repo, path: r.path, name: r.name, id: r.id, webURL: r.webURL.absoluteString, repoAPI: r.repoAPI.absoluteString,
                        treeAPI: r.treeAPI(branch: "feature/a b").absoluteString, rawURL: r.rawURL(branch: "main", path: "decks/my deck/index.html").absoluteString,
                        branch: r.branch)
            }]
        }

        func blob(_ path: String, _ size: Int? = 100) -> DeckRepoCatalogue.TreeEntry { .init(path: path, type: "blob", size: size) }
        let official = DeckRepo.official
        let officialTree: [DeckRepoCatalogue.TreeEntry] = [
            blob("README.md"), blob("index.html"), .init(path: "decks", type: "tree"),
            blob("decks/README.md"), blob("decks/snazzy-decks.json"),
            blob("decks/build-ship-ai/index.html", 5000), blob("decks/build-ship-ai/deck.css"), blob("decks/build-ship-ai/deck.js"),
            blob("decks/build-ship-ai/deck.json"), blob("decks/build-ship-ai/img/hero.png", 200_000), blob("decks/build-ship-ai/.DS_Store"),
            blob("decks/build-ship-ai/notes.exe"), blob("decks/build-ship-ai/huge.mp4", 3_000_000),
            blob("decks/build-ship-ai/inner/index.html"),
            blob("decks/education/photosynthesis/index.html"), blob("decks/education/photosynthesis/deck.css", nil),
            blob("decks/q3_results/index.html"), blob("decks/q3_results/Deck.CSS"),
            blob("decks/a/b/c/index.html"), blob("decks/a/b/c/d/index.html"),
            blob("decks/.hidden/index.html"), blob("decks/x/.git/index.html"),
            blob("decks/zebra/index.html"), blob("decks/Apple/index.html"),
            blob("other/index.html"),
        ]
        let catalogue = DeckRepoCatalogue.Catalogue(title: "Snazzy decks", decks: [
            .init(path: "zebra", title: "Zebra first", description: "Listed first", category: "Animals", tags: ["#Wild", "wild", " Stripes "], author: "Zoo"),
            .init(path: "/build-ship-ai/ ", title: "Build & Ship AI", tags: ["AI"]),
            .init(path: "zebra", title: "Duplicate entry ignored"),
            .init(path: "missing", title: "Not in the tree"),
        ])
        let tooMany = (0...DeckRepoCatalogue.maxFilesPerDeck).map { blob("big/f\($0).js") } + [blob("big/index.html"), blob("ok/index.html")]
        let tooBig = [blob("heavy/index.html")] + (0..<21).map { blob("heavy/v\($0).mp4", 1_999_999) }
        let decksCases: [(String, DeckRepo, [DeckRepoCatalogue.TreeEntry], DeckRepoCatalogue.Catalogue?)] = [
            ("official", official, officialTree, catalogue),
            ("official without catalogue", official, officialTree, nil),
            ("repo is one deck", DeckRepo(owner: "o", repo: "my-talk"), [blob("index.html"), blob("deck.css"), blob("img/a.png")], nil),
            ("top page plus decks", DeckRepo(owner: "o", repo: "r"), [blob("index.html"), blob("one/index.html"), blob("two/index.html")], nil),
            ("too many files", DeckRepo(owner: "o", repo: "r"), tooMany, nil),
            ("too big", DeckRepo(owner: "o", repo: "r"), tooBig + [blob("small/index.html")], nil),
            ("subfolder repo path", DeckRepo(owner: "o", repo: "r", branch: "dev", path: "/talks/"), [blob("talks/2026/keynote/index.html"), blob("talks/2026/keynote/deck.js"), blob("talksx/index.html")], nil),
        ]
        let decksOut = decksCases.map { name, repo, tree, cat in
            let d = DeckRepoCatalogue.decks(in: repo, branch: "main", tree: tree, catalogue: cat)
            return DecksCase(name: name, repo: repo, branch: "main", tree: tree, catalogue: cat, decks: d, origins: d.map(\.origin), webURLs: d.map(\.webURL.absoluteString))
        }
        struct Out: Codable {
            var official: DeckRepo
            var catalogueFile: String
            var limits: [String: Int]
            var allowedExtensions: [String]
            var parse: [[String: RepoOut?]]
            var decks: [DecksCase]
            var prettify: [[String]]
        }
        SpecFixtures.check("deck-repo-cases.json", cases: Out(
            official: official, catalogueFile: DeckRepo.catalogueFile,
            limits: ["maxFilesPerDeck": DeckRepoCatalogue.maxFilesPerDeck, "maxFileBytes": DeckRepoCatalogue.maxFileBytes,
                     "maxDeckBytes": DeckRepoCatalogue.maxDeckBytes, "maxDepth": DeckRepoCatalogue.maxDepth],
            allowedExtensions: DeckRepoCatalogue.allowedExtensions.sorted(),
            parse: parsed, decks: decksOut,
            prettify: ["build-ship-ai", "q3_results", "already Fine", "", "-", "élan-vital", "a--b"].map { [$0, DeckRepoCatalogue.prettify($0)] }))
    }

    // MARK: Settings and presets

    @Test func settings() throws {
        let sorted = JSONEncoder()
        sorted.outputFormatting = [.sortedKeys]
        func encode(_ s: AppSettings) throws -> JSONValue { try JSONValue.parse(sorted.encode(s)) }
        let partials: [String] = [
            "{}",
            #"{"planning":{"provider":"ollama","model":"llama3.3"},"wakeWord":"Computer","futureField":true}"#,
            #"{"chatTextSize":99,"speechRate":0}"#,
            #"{"chatTextSize":3,"speechRate":2,"cloudConsent":["anthropic"],"maxOutputTokens":1000}"#,
            #"{"activeTask":"quickCommands","quickCommands":{"provider":"appleOnDevice","model":"apple-on-device"},"ollamaBaseURL":"http://studio.local:11434"}"#,
        ]
        let invalid = [#"{"activeTask":"dancing"}"#, #"{"planning":{"provider":"openai","model":"x"}}"#, #"{"voiceAutoSend":"yes"}"#, "[]"]
        struct Out: Codable {
            var `default`: JSONValue
            var partial: [[JSONValue]]
            var invalid: [String]
            var runsOnThisMac: [[String]]
        }
        var runs: [[String]] = []
        for url in ["http://localhost:11434", "http://127.0.0.1:11434", "http://[::1]:11434", "http://LOCALHOST", "http://studio.local:11434", "not a url", ""] {
            var s = AppSettings.default
            s.ollamaBaseURL = url
            runs.append([url, s.runsOnThisMac(.ollama) ? "true" : "false", s.recipientName(.ollama)])
        }
        let out = Out(default: try encode(.default),
                      partial: try partials.map { [.string($0), try encode(JSONDecoder().decode(AppSettings.self, from: Data($0.utf8)))] },
                      invalid: invalid.filter { (try? JSONDecoder().decode(AppSettings.self, from: Data($0.utf8))) == nil },
                      runsOnThisMac: runs)
        #expect(out.invalid == invalid)
        SpecFixtures.check("settings.json", cases: out)
        // A preset file as PresetStore saves it.
        let preset = Self.share().presets[0]
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        SpecFixtures.check("preset.json", try e.encode(preset))
        SpecFixtures.check("preset-cases.json", cases: ["Lesson setup", "Q3 deck, iPad bottom-right", "  ", "Ünïcode Name!", String(repeating: "x", count: 90)]
            .map { [$0, PresetStore.fileName($0)] })
    }
}

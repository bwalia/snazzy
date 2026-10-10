import Foundation
import Testing
@testable import Builder

@Suite struct DeckSearchTests {
    let page = """
    <html><head><title>Q3 Café Review</title><style>.slide { color: red }</style></head><body>
    <section class="slide title"><h1>Q3 Café Review</h1><p class="subtitle">Revenue &amp; costs</p>
      <aside class="notes">Thank the finance team.</aside></section>
    <section class="slide layout-bullets"><h2>Spend caps</h2><ul><li>Hard monthly cap</li><li>Kill switch</li></ul></section>
    <section class="slide layout-quote"><blockquote>Ship the loop</blockquote><p class="by">— Résumé of week five</p>
      <aside class="notes">Pause here and mention the &lt;kill switch&gt; drill.</aside></section>
    <script>const s = "<section class='slide'><h2>Not a slide</h2></section>";</script>
    </body></html>
    """

    @Test func readsSlidesHeadingsTextAndNotesFromHTML() {
        let slides = DeckSearch.slides(fromHTML: page)
        #expect(slides.count == 3)
        #expect(slides[0] == .init(heading: "Q3 Café Review", text: "Revenue & costs", notes: "Thank the finance team."))
        #expect(slides[1].heading == "Spend caps")
        #expect(slides[1].text == "Hard monthly cap Kill switch")
        #expect(slides[2].heading == "Ship the loop")
        #expect(slides[2].notes == "Pause here and mention the <kill switch> drill.")
        #expect(DeckSearch.title(fromHTML: page) == "Q3 Café Review")
    }

    @Test func findsEveryWordIgnoringCaseAndAccentsBestFirst() {
        let deck = DeckSearch.Deck(source: .project("q3"), title: "Q3", slides: DeckSearch.slides(fromHTML: page))
        let hits = DeckSearch.search("KILL switch", in: [deck])
        // In the bullet text of slide 1 beats the notes of slide 2.
        #expect(hits.map(\.slide) == [1, 2])
        #expect(hits[0].field == .text)
        #expect(hits[1].field == .notes)
        #expect(DeckSearch.search("cafe", in: [deck]).map(\.slide) == [0])
        #expect(DeckSearch.search("resume", in: [deck]).map(\.slide) == [2])
        #expect(DeckSearch.search("kill banana", in: [deck]).isEmpty)
        #expect(DeckSearch.search("   ", in: [deck]).isEmpty)
    }

    @Test func headingMatchesRankAboveNotes() {
        let a = DeckSearch.Deck(source: .project("a"), title: "A", slides: [.init(heading: "Intro", text: "", notes: "budget talk")])
        let b = DeckSearch.Deck(source: .project("b"), title: "B", slides: [.init(heading: "Budget", text: "", notes: "")])
        #expect(DeckSearch.search("budget", in: [a, b]).map(\.deck) == [.project("b"), .project("a")])
    }

    @Test func tagsAndCategoryNarrowTheSearch() {
        let s = DeckSearch.Slide(heading: "Pricing", text: "Three plans", notes: "")
        let a = DeckSearch.Deck(source: .project("a"), title: "A", category: "Sales", tags: ["Q4", "Pilot"], slides: [s])
        let b = DeckSearch.Deck(source: .project("b"), title: "B", category: "Education", slides: [s])
        #expect(DeckSearch.search("pricing pilot", in: [a, b]).map(\.deck) == [.project("a")])
        #expect(DeckSearch.search("pricing education", in: [a, b]).map(\.deck) == [.project("b")])
    }

    @Test func snippetsCentreOnTheMatch() {
        let long = String(repeating: "filler words here ", count: 20) + "the spend cap stops runaway bills " + String(repeating: "more text ", count: 20)
        let s = DeckSearch.snippet(long, around: ["spend"])
        #expect(s.contains("spend cap"))
        #expect(s.hasPrefix("…") && s.hasSuffix("…"))
        #expect(s.count <= 160)
        #expect(DeckSearch.snippet("short", around: ["x"]) == "short")
    }

    @Test func workspaceDecksIncludeProjectsAndUnopenedSamples() throws {
        let ws = Workspace(root: FileManager.default.temporaryDirectory.appending(path: "decksearch-\(UUID())"))
        defer { try? FileManager.default.removeItem(at: ws.root) }
        try ws.createProject(name: "talk", kind: .presentation, title: "My talk")
        try ws.write(project: "talk", path: "index.html", content: page)
        try ws.setDetails("talk", category: " Finance ", tags: ["q3", "Q3", " #board ", ""])
        try ws.createProject(name: "proto", kind: .prototype)
        let sample = SampleDeck.all[0]
        try ws.createSample(SampleDeck.all[1])

        let decks = DeckSearch.decks(in: ws)
        let talk = try #require(decks.first { $0.source == .project("talk") })
        #expect(talk.title == "Q3 Café Review")
        #expect(talk.category == "Finance")
        #expect(talk.tags == ["q3", "board"])
        #expect(!decks.contains { $0.source == .project("proto") })
        #expect(decks.contains { $0.source == .sample(sample.id) && $0.category == sample.sector.rawValue })
        // An opened sample is a project, with its sector as the category, not listed twice.
        #expect(!decks.contains { $0.source == .sample(SampleDeck.all[1].id) })
        #expect(decks.first { $0.source == .project(SampleDeck.all[1].projectName) }?.category == SampleDeck.all[1].sector.rawValue)
    }

    @Test func oldProjectFilesStillLoad() throws {
        let json = #"{"name":"old","kind":"presentation","created":"2026-01-01T00:00:00Z"}"#
        let p = try JSONDecoder.iso.decode(BuilderProject.self, from: Data(json.utf8))
        #expect(p.category == nil && p.tags == nil && p.origin == nil)
    }
}

@Suite struct DeckRepoTests {
    @Test func parsesWhatPeoplePaste() {
        #expect(DeckRepo.parse("bwalia/snazzy") == DeckRepo(owner: "bwalia", repo: "snazzy"))
        #expect(DeckRepo.parse("bwalia/snazzy/decks") == DeckRepo(owner: "bwalia", repo: "snazzy", path: "decks"))
        #expect(DeckRepo.parse(" https://github.com/acme/talks.git ") == DeckRepo(owner: "acme", repo: "talks"))
        #expect(DeckRepo.parse("github.com/acme/talks/tree/dev/2026/q3?tab=readme") == DeckRepo(owner: "acme", repo: "talks", branch: "dev", path: "2026/q3"))
        #expect(DeckRepo.parse("https://github.com/acme/talks/tree/HEAD") == DeckRepo(owner: "acme", repo: "talks"))
        for bad in ["", "acme", "acme/", "../x", "acme/ta lks", "acme/talks/../../etc", "https://evil.com/a/b?x", "acme/talks/tree/../x"] {
            #expect(DeckRepo.parse(bad) == nil, "\(bad)")
        }
    }

    @Test func buildsGitHubURLs() {
        let r = DeckRepo(owner: "acme", repo: "talks", path: "decks")
        #expect(r.treeAPI(branch: "main").absoluteString == "https://api.github.com/repos/acme/talks/git/trees/main?recursive=1")
        #expect(r.rawURL(branch: "main", path: "decks/my deck/index.html").absoluteString
                == "https://raw.githubusercontent.com/acme/talks/main/decks/my%20deck/index.html")
        #expect(r.name == "acme/talks/decks")
    }

    let tree: [DeckRepoCatalogue.TreeEntry] = [
        .init(path: "README.md", type: "blob", size: 10),
        .init(path: "index.html", type: "blob", size: 10),
        .init(path: "decks", type: "tree"),
        .init(path: "decks/snazzy-decks.json", type: "blob", size: 100),
        .init(path: "decks/build-ship-ai/index.html", type: "blob", size: 5000),
        .init(path: "decks/build-ship-ai/deck.css", type: "blob", size: 2000),
        .init(path: "decks/build-ship-ai/deck.js", type: "blob", size: 900),
        .init(path: "decks/build-ship-ai/img/logo.png", type: "blob", size: 9000),
        .init(path: "decks/build-ship-ai/run.sh", type: "blob", size: 10),
        .init(path: "decks/build-ship-ai/.secret.html", type: "blob", size: 10),
        .init(path: "decks/build-ship-ai/huge.mp4", type: "blob", size: 90_000_000),
        .init(path: "decks/education/photosynthesis/index.html", type: "blob", size: 3000),
        .init(path: "decks/education/photosynthesis/deck.json", type: "blob", size: 300),
        .init(path: "decks/no-index/deck.css", type: "blob", size: 300),
    ]

    @Test func findsDeckFoldersWithSafeFilesAndCatalogueDetails() {
        let catalogue = DeckRepoCatalogue.Catalogue(decks: [
            .init(path: "build-ship-ai/", title: "Build & Ship AI", description: "Course map", category: "Developers", tags: ["AI", "Course", "ai"]),
        ])
        let decks = DeckRepoCatalogue.decks(in: .official, branch: "main", tree: tree, catalogue: catalogue)
        #expect(decks.map(\.title) == ["Build & Ship AI", "Photosynthesis"])
        let bsa = decks[0]
        #expect(bsa.folder == "decks/build-ship-ai")
        #expect(bsa.files == ["deck.css", "deck.js", "img/logo.png", "index.html"])
        #expect(bsa.category == "Developers" && bsa.tags == ["AI", "Course"])
        #expect(bsa.origin == "github:bwalia/snazzy/decks/build-ship-ai")
        // No catalogue entry: title from the folder, category from the parent folder.
        #expect(decks[1].category == "Education")
        #expect(decks[1].files == ["deck.json", "index.html"])
    }

    @Test func aRepoThatIsOneDeck() {
        let one: [DeckRepoCatalogue.TreeEntry] = [.init(path: "index.html", type: "blob", size: 10), .init(path: "deck.css", type: "blob", size: 10)]
        let decks = DeckRepoCatalogue.decks(in: DeckRepo(owner: "acme", repo: "q3-review"), branch: "main", tree: one, catalogue: nil)
        #expect(decks.count == 1)
        #expect(decks[0].title == "Q3 review" && decks[0].folder == "" && decks[0].files == ["deck.css", "index.html"])
    }

    @Test func parsesTreeAndCatalogueJSON() throws {
        let json = #"{"sha":"x","tree":[{"path":"a/index.html","type":"blob","size":12,"mode":"100644"}],"truncated":false}"#
        let (entries, truncated) = try DeckRepoCatalogue.parseTree(Data(json.utf8))
        #expect(entries == [.init(path: "a/index.html", type: "blob", size: 12)] && !truncated)
        let cat = DeckRepoCatalogue.parseCatalogue(Data(#"{"decks":[{"path":"a","tags":["x"]}]}"#.utf8))
        #expect(cat?.decks.first?.tags == ["x"])
        #expect(DeckRepoCatalogue.parseCatalogue(Data("nope".utf8)) == nil)
    }

    @Test func importsAsASharedProject() throws {
        let ws = Workspace(root: FileManager.default.temporaryDirectory.appending(path: "deckrepo-\(UUID())"))
        defer { try? FileManager.default.removeItem(at: ws.root) }
        let deck = DeckRepoCatalogue.decks(in: .official, branch: "main", tree: tree, catalogue: nil)[0]
        let project = DeckRepoCatalogue.project(for: deck, files: [("index.html", Data("<section class=\"slide\"><h1>Hi</h1></section>".utf8))])
        let p = try ws.importProject(project)
        #expect(p.name == "build-ship-ai" && p.shared == true)
        let detailed = try ws.setDetails(p.name, category: "Developers", tags: ["GitHub"], origin: deck.origin)
        #expect(ws.project(p.name) == detailed)
        #expect(ws.project(p.name)?.origin == "github:bwalia/snazzy/decks/build-ship-ai")
    }
}

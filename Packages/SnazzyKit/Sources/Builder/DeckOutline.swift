import Foundation

/// A deck as an outline (title, colour, slides with layouts and notes), so it
/// can be made and edited without AI in the slide editor. Saved as deck.json
/// next to the generated index.html.
public struct DeckOutline: Codable, Sendable, Equatable {
    public static let fileName = "deck.json"

    public var title: String
    public var accent: String
    public var slides: [SampleDeck.Slide]

    public init(title: String, accent: String = "#6C5CFF", slides: [SampleDeck.Slide]) {
        self.title = title
        self.accent = accent
        self.slides = slides
    }

    /// A new deck to start from.
    public static func starter(title: String) -> DeckOutline {
        DeckOutline(title: title, slides: [
            .init(.title, title, ["Subtitle"], notes: "Introduce yourself and the topic."),
            .init(.bullets, "What we'll cover", ["First point", "Second point", "Third point"]),
            .init(.closing, "Thank you", ["Questions?"]),
        ])
    }

    /// Accent colours offered in the editor (from the sample decks and the brand).
    public static let accents = ["#6C5CFF", "#D946EF", "#FF6A55", "#FFB020", "#34D399", "#38BDF8", "#0F766E", "#3B82F6"]

    public func html() -> String { SampleDeck.deckHTML(title: title, accent: accent, slides: slides) }

    /// Writes deck.json and (normally) index.html, keeping deck.css and deck.js.
    public func save(to workspace: Workspace, project: String, writeHTML: Bool = true) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = String(decoding: try enc.encode(self), as: UTF8.self)
        try workspace.write(project: project, path: Self.fileName, content: json + "\n")
        if writeHTML { try workspace.write(project: project, path: "index.html", content: html()) }
        // Decks made by AI may lack the house style files; add them if missing.
        let files = Set(workspace.files(project: project))
        for (path, content) in Templates.files(for: .presentation, title: title) where path != "index.html" && !files.contains(path) {
            try workspace.write(project: project, path: path, content: content)
        }
    }

    public static func load(from workspace: Workspace, project: String) -> DeckOutline? {
        guard let text = try? workspace.read(project: project, path: fileName) else { return nil }
        return try? JSONDecoder().decode(DeckOutline.self, from: Data(text.utf8))
    }

    /// Creates a new presentation project from an outline.
    @discardableResult
    public static func create(_ outline: DeckOutline, in workspace: Workspace) throws -> BuilderProject {
        var name = Workspace.slug(outline.title)
        if name.isEmpty { name = "deck" }
        var n = 2
        let base = name
        while workspace.listProjects().contains(where: { $0.name == name }) { name = "\(base)-\(n)"; n += 1 }
        let project = try workspace.createProject(name: name, kind: .presentation, title: outline.title)
        try outline.save(to: workspace, project: project.name)
        return project
    }
}

extension SampleDeck.Slide.Layout {
    /// Names for the editor.
    public var displayName: String {
        switch self {
        case .title: "Title"
        case .bullets: "Bullet points"
        case .stats: "Big numbers"
        case .columns: "Two columns"
        case .quote: "Quote"
        case .steps: "Numbered steps"
        case .closing: "Closing"
        }
    }

    /// How the editor's lines map to the layout.
    public var itemsHint: String {
        switch self {
        case .title, .closing: "Subtitle (one line)"
        case .bullets: "One bullet per line"
        case .steps: "One step per line"
        case .stats: "Pairs of lines: number, then what it means"
        case .columns: "Left label, its points, then right label and its points (split in half)"
        case .quote: "Who said it (one line)"
        }
    }
}

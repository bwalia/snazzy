import Foundation

/// A GitHub repository (or a folder in one) holding slide decks people can add
/// to Snazzy Pro. Each deck is a folder with an `index.html` (and usually
/// deck.css, deck.js, deck.json and images). An optional `snazzy-decks.json` in
/// the repo folder gives titles, categories, tags and descriptions.
public struct DeckRepo: Codable, Hashable, Sendable, Identifiable {
    public var owner: String
    public var repo: String
    /// Nil means the repository's default branch.
    public var branch: String?
    /// Folder inside the repository ("" for the top).
    public var path: String

    public init(owner: String, repo: String, branch: String? = nil, path: String = "") {
        self.owner = owner
        self.repo = repo
        self.branch = branch
        self.path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    public var id: String { name + (branch.map { "@\($0)" } ?? "") }
    /// "owner/repo" or "owner/repo/folder".
    public var name: String { "\(owner)/\(repo)" + (path.isEmpty ? "" : "/\(path)") }
    public var webURL: URL {
        var s = "https://github.com/\(owner)/\(repo)"
        if branch != nil || !path.isEmpty { s += "/tree/\(branch ?? "HEAD")" + (path.isEmpty ? "" : "/\(path)") }
        return URL(string: s) ?? URL(string: "https://github.com")!
    }

    /// Snazzy Pro's own deck collection.
    public static let official = DeckRepo(owner: "bwalia", repo: "snazzy", path: "decks")
    public static let catalogueFile = "snazzy-decks.json"

    /// Reads what people paste: "owner/repo", "owner/repo/folder",
    /// "github.com/owner/repo", or a browser link like
    /// "https://github.com/owner/repo/tree/main/decks".
    public static func parse(_ text: String) -> DeckRepo? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://", "www."] where s.lowercased().hasPrefix(prefix) { s.removeFirst(prefix.count) }
        if s.lowercased().hasPrefix("github.com/") { s.removeFirst("github.com/".count) }
        if s.hasSuffix(".git") { s.removeLast(4) }
        s = s.components(separatedBy: CharacterSet(charactersIn: "?#")).first ?? s
        let parts = s.split(separator: "/").map(String.init)
        // GitHub user and organisation names are letters, digits and dashes only.
        guard parts.count >= 2, valid(parts[1]), parts[0].count <= 39,
              parts[0].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        let repo = parts[1]
        if parts.count >= 4, parts[2] == "tree" || parts[2] == "blob" {
            let branch = parts[3]
            guard validPath(branch) else { return nil }
            let rest = parts.dropFirst(4).joined(separator: "/")
            guard rest.isEmpty || validPath(rest) else { return nil }
            return DeckRepo(owner: parts[0], repo: repo, branch: branch == "HEAD" ? nil : branch, path: rest)
        }
        let rest = parts.dropFirst(2).joined(separator: "/")
        guard rest.isEmpty || validPath(rest) else { return nil }
        return DeckRepo(owner: parts[0], repo: repo, path: rest)
    }

    private static func valid(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 100 && s != "." && s != ".." && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }

    private static func validPath(_ s: String) -> Bool {
        s.split(separator: "/").allSatisfy { valid(String($0)) }
    }

    // MARK: URLs

    func encoded(_ path: String) -> String {
        path.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
    }

    /// GitHub API: the repository (for its default branch).
    public var repoAPI: URL { URL(string: "https://api.github.com/repos/\(owner)/\(repo)")! }

    /// GitHub API: every file in the branch.
    public func treeAPI(branch: String) -> URL {
        URL(string: "https://api.github.com/repos/\(owner)/\(repo)/git/trees/\(encoded(branch))?recursive=1")!
    }

    /// A file's raw contents. `path` is relative to the repository top.
    public func rawURL(branch: String, path: String) -> URL {
        URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/\(encoded(branch))/\(encoded(path))")!
    }
}

/// A deck found in a repo, ready to add.
public struct RemoteDeck: Codable, Hashable, Sendable, Identifiable {
    public var repo: DeckRepo
    public var branch: String
    /// The deck's folder, relative to the repository top.
    public var folder: String
    public var title: String
    public var description: String
    public var category: String?
    public var tags: [String]
    public var author: String?
    /// Files to download, relative to `folder`.
    public var files: [String]
    public var bytes: Int

    public var id: String { "\(repo.owner)/\(repo.repo)/\(folder)" }
    /// Stored on the project, so the library knows it's already added.
    public var origin: String { "github:\(repo.owner)/\(repo.repo)/\(folder)" }
    public var webURL: URL {
        URL(string: "https://github.com/\(repo.owner)/\(repo.repo)/tree/\(repo.encoded(branch))/\(repo.encoded(folder))") ?? repo.webURL
    }
}

public enum DeckRepoCatalogue {
    /// What `snazzy-decks.json` may say about each deck. Everything is optional.
    public struct Catalogue: Codable, Sendable, Equatable {
        public struct Entry: Codable, Sendable, Equatable {
            public var path: String
            public var title: String?
            public var description: String?
            public var category: String?
            public var tags: [String]?
            public var author: String?

            public init(path: String, title: String? = nil, description: String? = nil, category: String? = nil, tags: [String]? = nil, author: String? = nil) {
                self.path = path
                self.title = title
                self.description = description
                self.category = category
                self.tags = tags
                self.author = author
            }
        }

        public var title: String?
        public var decks: [Entry]

        public init(title: String? = nil, decks: [Entry]) {
            self.title = title
            self.decks = decks
        }
    }

    /// One file in a GitHub tree listing.
    public struct TreeEntry: Codable, Sendable, Equatable {
        public var path: String
        public var type: String
        public var size: Int?

        public init(path: String, type: String, size: Int? = nil) {
            self.path = path
            self.type = type
            self.size = size
        }
    }

    // Limits for a deck from someone else: web files only, nothing huge.
    public static let allowedExtensions: Set<String> = ["html", "htm", "css", "js", "json", "svg", "png", "jpg", "jpeg", "gif", "webp", "avif",
                                                         "woff", "woff2", "ttf", "otf", "md", "txt", "vtt", "mp3", "m4a", "mp4", "webm"]
    public static let maxFilesPerDeck = 80
    public static let maxFileBytes = Workspace.maxFileBytes
    public static let maxDeckBytes = 40_000_000
    /// Decks deeper than this under the repo folder aren't looked for.
    public static let maxDepth = 3

    /// The GitHub tree API response's entries (and whether GitHub cut the list short).
    public static func parseTree(_ data: Data) throws -> (entries: [TreeEntry], truncated: Bool) {
        struct Response: Decodable { var tree: [TreeEntry]; var truncated: Bool? }
        let r = try JSONDecoder().decode(Response.self, from: data)
        return (r.tree, r.truncated ?? false)
    }

    public static func parseCatalogue(_ data: Data) -> Catalogue? {
        try? JSONDecoder().decode(Catalogue.self, from: data)
    }

    /// The decks in a repo folder: every folder (up to `maxDepth` down) with an
    /// index.html, described by the catalogue where it has an entry. Catalogue
    /// order first, then the rest by name.
    public static func decks(in repo: DeckRepo, branch: String, tree: [TreeEntry], catalogue: Catalogue?) -> [RemoteDeck] {
        let base = repo.path.isEmpty ? "" : repo.path + "/"
        let blobs = tree.filter { $0.type == "blob" && $0.path.hasPrefix(base) }
        // Folders holding an index.html, relative to the repo folder.
        var folders: [String] = []
        for b in blobs {
            let rel = String(b.path.dropFirst(base.count))
            guard rel.hasSuffix("/index.html") || rel == "index.html" else { continue }
            let folder = rel == "index.html" ? "" : String(rel.dropLast("/index.html".count))
            let depth = folder.isEmpty ? 0 : folder.split(separator: "/").count
            guard depth <= maxDepth, !folder.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { continue }
            folders.append(folder)
        }
        // A deck folder never contains another deck: skip folders inside one already found.
        let sorted = folders.sorted { $0.count < $1.count }
        var deckFolders: [String] = []
        for f in sorted where !deckFolders.contains(where: { $0.isEmpty ? !f.isEmpty : f.hasPrefix($0 + "/") }) {
            deckFolders.append(f)
        }
        // With decks in subfolders, a top-level index.html is the repo's own page, not a deck.
        if deckFolders.count > 1 { deckFolders.removeAll { $0.isEmpty } }

        let entries = Dictionary((catalogue?.decks ?? []).map { (clean($0.path), $0) }, uniquingKeysWith: { a, _ in a })
        var decks: [RemoteDeck] = []
        for folder in deckFolders {
            let full = base + folder
            let prefix = folder.isEmpty ? base : full + "/"
            let files = blobs.filter { $0.path.hasPrefix(prefix) }.compactMap { b -> (String, Int)? in
                let rel = String(b.path.dropFirst(prefix.count))
                guard SnazzyShare.isSafeRelativePath(rel), !rel.split(separator: "/").contains(where: { $0.hasPrefix(".") }),
                      allowedExtensions.contains((rel as NSString).pathExtension.lowercased()),
                      (b.size ?? 0) <= maxFileBytes else { return nil }
                return (rel, b.size ?? 0)
            }
            guard files.contains(where: { $0.0 == "index.html" }), files.count <= maxFilesPerDeck else { continue }
            let bytes = files.reduce(0) { $0 + $1.1 }
            guard bytes <= maxDeckBytes else { continue }
            let entry = entries[folder]
            let parts = folder.split(separator: "/").map(String.init)
            let title = entry?.title ?? (parts.last.map(prettify) ?? prettify(repo.repo))
            // Folder layout "education/photosynthesis" gives the category "Education".
            let category = entry?.category ?? (parts.count >= 2 ? prettify(parts[parts.count - 2]) : nil)
            decks.append(RemoteDeck(repo: repo, branch: branch, folder: full.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                                    title: title, description: entry?.description ?? "", category: category,
                                    tags: BuilderProject.cleanTags(entry?.tags ?? []), author: entry?.author,
                                    files: files.map(\.0).sorted(), bytes: bytes))
        }
        let order = Dictionary((catalogue?.decks ?? []).enumerated().map { (clean($0.element.path), $0.offset) }, uniquingKeysWith: { a, _ in a })
        return decks.sorted { a, b in
            let ra = order[relative(a.folder, to: base)] ?? Int.max, rb = order[relative(b.folder, to: base)] ?? Int.max
            return ra != rb ? ra < rb : a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    /// A downloaded deck as a project to import (imported decks are treated as shared: no internet until allowed).
    public static func project(for deck: RemoteDeck, files: [(String, Data)]) -> SnazzyShare.Project {
        let name = deck.folder.split(separator: "/").last.map(String.init) ?? deck.title
        return .init(name: name, kind: .presentation, files: files.map { .init(path: $0.0, data: $0.1) })
    }

    static func clean(_ path: String) -> String { path.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) }

    static func relative(_ folder: String, to base: String) -> String {
        base.isEmpty ? folder : String(folder.dropFirst(min(folder.count, base.count)))
    }

    /// "build-ship-ai" → "Build ship ai"; "q3_results" → "Q3 results".
    static func prettify(_ s: String) -> String {
        let words = s.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            .split(separator: " ").map(String.init)
        guard let first = words.first else { return s }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
    }
}

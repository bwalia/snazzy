import Builder
import Foundation
import SnazzyCore

/// Deck repos on GitHub: Snazzy Pro's own collection plus any repo the user adds.
/// Lists the decks in each and adds the chosen ones to the library. Only public
/// files are downloaded; nothing about the user is sent. Added decks are treated
/// like shared files: no internet access until the user allows it.
@MainActor @Observable
final class DeckRepoController {
    enum LoadState: Equatable {
        case idle, loading
        case loaded([RemoteDeck])
        case failed(String)
    }

    private(set) var repos: [DeckRepo]
    private(set) var states: [DeckRepo: LoadState] = [:]
    /// Decks being downloaded (by id), with how many files are done.
    private(set) var adding: [String: (done: Int, total: Int)] = [:]

    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private let session: URLSession
    private static let storeKey = "SnazzyPro.deckRepos.v1"

    init(app: AppModel) {
        self.app = app
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.httpAdditionalHeaders = ["User-Agent": "SnazzyPro"]
        session = URLSession(configuration: config)
        let saved = (UserDefaults.standard.data(forKey: Self.storeKey))
            .flatMap { try? JSONDecoder().decode([DeckRepo].self, from: $0) } ?? []
        repos = [DeckRepo.official] + saved.filter { $0 != DeckRepo.official }
    }

    func state(_ repo: DeckRepo) -> LoadState { states[repo] ?? .idle }

    /// Adds a repo from what the user typed ("owner/repo" or a GitHub link) and loads it.
    @discardableResult
    func addRepo(_ text: String) throws -> DeckRepo {
        guard let repo = DeckRepo.parse(text) else {
            throw WorkspaceError("That doesn't look like a GitHub repo. Use owner/repo, or paste a github.com link.")
        }
        if !repos.contains(repo) {
            repos.append(repo)
            save()
        }
        Task { await load(repo) }
        return repo
    }

    func removeRepo(_ repo: DeckRepo) {
        guard repo != .official else { return }
        repos.removeAll { $0 == repo }
        states[repo] = nil
        save()
    }

    private func save() {
        let custom = repos.filter { $0 != .official }
        UserDefaults.standard.set(try? JSONEncoder().encode(custom), forKey: Self.storeKey)
    }

    // MARK: Listing

    /// Reads the repo's file list and catalogue from GitHub.
    @discardableResult
    func load(_ repo: DeckRepo, force: Bool = false) async -> [RemoteDeck] {
        if !force, case .loaded(let decks) = state(repo) { return decks }
        states[repo] = .loading
        do {
            var branch = repo.branch
            if branch == nil {
                let (data, _) = try await get(repo.repoAPI)
                branch = (try? JSONValue.parse(data))?["default_branch"]?.stringValue ?? "main"
            }
            let b = branch ?? "main"
            let (treeData, _) = try await get(repo.treeAPI(branch: b))
            let (entries, truncated) = try DeckRepoCatalogue.parseTree(treeData)
            let cataloguePath = (repo.path.isEmpty ? "" : repo.path + "/") + DeckRepo.catalogueFile
            var catalogue: DeckRepoCatalogue.Catalogue?
            if entries.contains(where: { $0.path == cataloguePath }) {
                catalogue = (try? await get(repo.rawURL(branch: b, path: cataloguePath))).flatMap { DeckRepoCatalogue.parseCatalogue($0.0) }
            }
            let decks = DeckRepoCatalogue.decks(in: repo, branch: b, tree: entries, catalogue: catalogue)
            if decks.isEmpty {
                let hint = truncated ? " The repo is very large; point to its decks folder, like owner/repo/decks." : ""
                states[repo] = .failed("No decks found in \(repo.name). A deck is a folder with an index.html.\(hint)")
            } else {
                states[repo] = .loaded(decks)
            }
            return decks
        } catch {
            states[repo] = .failed(error.localizedDescription)
            return []
        }
    }

    // MARK: Adding

    /// The project already added from this deck, if any.
    func addedProject(_ deck: RemoteDeck) -> BuilderProject? {
        app.builder.projects.first { $0.origin == deck.origin }
    }

    /// Downloads a deck, adds it to the library with its category and tags, and opens it.
    @discardableResult
    func add(_ deck: RemoteDeck, open: Bool = true) async throws -> BuilderProject {
        if let existing = addedProject(deck) {
            if open { app.builder.open(existing.name) }
            return existing
        }
        guard adding[deck.id] == nil else { throw WorkspaceError("“\(deck.title)” is already being added.") }
        adding[deck.id] = (0, deck.files.count)
        defer { adding[deck.id] = nil }
        var files: [(String, Data)] = []
        var total = 0
        for path in deck.files {
            let full = deck.folder.isEmpty ? path : deck.folder + "/" + path
            let (data, _) = try await get(deck.repo.rawURL(branch: deck.branch, path: full))
            total += data.count
            guard data.count <= DeckRepoCatalogue.maxFileBytes, total <= DeckRepoCatalogue.maxDeckBytes else {
                throw WorkspaceError("“\(deck.title)” is too big to add.")
            }
            files.append((path, data))
            adding[deck.id] = (files.count, deck.files.count)
        }
        let builder = app.builder
        let imported = try builder.workspace.importProject(DeckRepoCatalogue.project(for: deck, files: files))
        var tags = deck.tags
        if deck.repo != .official { tags.append(deck.repo.owner) }
        let project = try builder.workspace.setDetails(imported.name, category: deck.category, tags: tags, origin: deck.origin)
        builder.refreshProjects()
        builder.step(.info, "Added “\(deck.title)” from \(deck.repo.name)")
        Log.app.info("Added deck \(deck.origin, privacy: .public) as \(project.name, privacy: .public)")
        if open { builder.open(project.name, announce: false) }
        return project
    }

    // MARK: Network

    private func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        if url.host() == "api.github.com" {
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WorkspaceError("No answer from GitHub.") }
        switch http.statusCode {
        case 200..<300: return (data, http)
        case 404: throw WorkspaceError("Not found on GitHub. Check the name, and that the repo is public.")
        case 403, 429:
            throw WorkspaceError("GitHub's limit for browsing without an account was reached. Try again in an hour.")
        default: throw WorkspaceError("GitHub answered \(http.statusCode).")
        }
    }
}

import Builder
import SwiftUI

/// Get Decks: browse deck repos on GitHub (Snazzy Pro's own first, then any the
/// user adds) and add a deck to My Decks with one click.
struct DeckReposView: View {
    @Environment(AppModel.self) private var model
    @State private var newRepo = ""
    @State private var filter = ""
    @State private var error: String?

    private var selected: DeckRepo { model.deckRepos.selected }

    var body: some View {
        let repos: DeckRepoController = model.deckRepos
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Get decks from GitHub").font(.headline)
                Text("Pick a deck repo, or add anyone's by pasting owner/repo or a GitHub link. Added decks go to My Decks and open without internet access until you allow it.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Picker("Repo", selection: Binding(get: { repos.selected }, set: { repos.selected = $0 })) {
                        ForEach(repos.repos) { r in
                            Text(r == .official ? "Snazzy Pro decks" : r.name).tag(r)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260)
                    TextField("owner/repo or GitHub link", text: $newRepo)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addRepo)
                    Button("Add Repo", action: addRepo).disabled(newRepo.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(12)
            Divider()
            repoHeader
            content
        }
        .task(id: selected) { await repos.load(selected) }
        .alert("Couldn't add that", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private var repoHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox").foregroundStyle(.secondary)
            Link(selected.name, destination: selected.webURL).font(.callout)
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
                TextField("Filter", text: $filter).textFieldStyle(.plain).frame(width: 140)
            }
            Button { Task { await model.deckRepos.load(selected, force: true) } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Reload the list from GitHub")
            if selected != .official {
                Button {
                    model.deckRepos.removeRepo(selected)
                } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless).help("Remove this repo from the list (decks you added stay)")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    @ViewBuilder private var content: some View {
        switch model.deckRepos.state(selected) {
        case .idle, .loading:
            ProgressView("Reading \(selected.name)…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't list the decks", systemImage: "exclamationmark.triangle")
            } description: { Text(message) } actions: {
                Button("Try Again") { Task { await model.deckRepos.load(selected, force: true) } }
            }
        case .loaded(let decks):
            let shown = filtered(decks)
            if shown.isEmpty {
                ContentUnavailableView.search(text: filter)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
                        ForEach(shown) { deck in RemoteDeckCard(deck: deck) }
                    }
                    .padding(12)
                }
            }
        }
    }

    private func filtered(_ decks: [RemoteDeck]) -> [RemoteDeck] {
        let words = filter.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return decks }
        return decks.filter { d in
            let text = ([d.title, d.description, d.category ?? "", d.author ?? "", d.folder] + d.tags).joined(separator: " ")
            return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    private func addRepo() {
        do {
            try model.deckRepos.addRepo(newRepo)
            newRepo = ""
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct RemoteDeckCard: View {
    @Environment(AppModel.self) private var model
    let deck: RemoteDeck
    @State private var error: String?

    var body: some View {
        let repos: DeckRepoController = model.deckRepos
        let added = repos.addedProject(deck)
        let progress = repos.adding[deck.id]
        VStack(alignment: .leading, spacing: 8) {
            if let category = deck.category {
                Text(category.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(Color.accentColor)
            }
            Text(deck.title).font(.headline)
            if !deck.description.isEmpty { Text(deck.description).font(.callout).lineLimit(3) }
            if !deck.tags.isEmpty {
                HStack(spacing: 4) { ForEach(deck.tags, id: \.self) { Text("#\($0)").font(.caption2).foregroundStyle(.secondary) } }
            }
            Text([deck.author.map { "by \($0)" }, "\(deck.files.count) files", SnazzyShare.formatBytes(deck.bytes)].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if let progress {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))).frame(width: 120)
                    Text("Adding…").font(.caption).foregroundStyle(.secondary)
                } else if let added {
                    Button("Open") {
                        model.builder.open(added.name)
                        model.slidesMode = .present
                    }
                    .buttonStyle(.borderedProminent)
                    Label("In My Decks", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Add to My Decks") { add() }.buttonStyle(.borderedProminent)
                }
                Spacer()
                Link(destination: deck.webURL) { Image(systemName: "arrow.up.right.square") }
                    .help("See the deck's files on GitHub")
            }
            .controlSize(.small)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private func add() {
        error = nil
        Task {
            do {
                try await model.deckRepos.add(deck)
                model.slidesMode = .present
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

import Builder
import SwiftUI

/// My Decks: every deck by name, grouped by category, filtered by tag, and a
/// search across all slide titles, text and speaker notes (samples included).
struct DeckLibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var decks: [DeckSearch.Deck] = []
    @State private var query = ""
    @State private var tag: String?
    @State private var sort: Sort = .name
    @State private var editing: DeckSearch.Deck?
    @State private var error: String?
    @FocusState private var searchFocused: Bool

    enum Sort: String, CaseIterable { case name = "Name", recent = "Recent" }

    /// Your own decks (projects); samples only show up in search results.
    private var myDecks: [DeckSearch.Deck] {
        decks.filter { if case .project = $0.source { true } else { false } }
            .filter { tag == nil || $0.tags.contains { $0.caseInsensitiveCompare(tag!) == .orderedSame } }
    }

    private var allTags: [String] {
        var seen = Set<String>()
        return decks.filter { if case .project = $0.source { true } else { false } }
            .flatMap(\.tags).filter { seen.insert($0.lowercased()).inserted }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                library
            } else {
                results
            }
        }
        .task(id: "\(model.builder.libraryVersion)-\(model.builder.reloadCount)") { await reloadDecks() }
        .onChange(of: model.deckSearchRequest, initial: true) { _, n in
            guard n > 0 else { return }
            if let q = model.pendingDeckQuery { query = q; model.pendingDeckQuery = nil }
            searchFocused = true
        }
        .sheet(item: $editing) { deck in
            DeckDetailsSheet(deck: deck, categories: Array(Set(decks.compactMap(\.category))).sorted(), allTags: allTags) { category, tags in
                guard case .project(let name) = deck.source else { return }
                do { try model.builder.setDetails(project: name, category: category, tags: tags) } catch { self.error = error.localizedDescription }
            }
        }
        .alert("Couldn't open the deck", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func reloadDecks() async {
        let ws = model.builder.workspace
        decks = await Task.detached(priority: .userInitiated) { DeckSearch.decks(in: ws) }.value
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search all slides, notes, categories and tags", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { if let first = DeckSearch.search(query, in: decks, limit: 1).first { open(first) } }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Clear the search")
                }
            }
            .padding(7)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            if query.isEmpty {
                HStack {
                    if !allTags.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                TagChip(title: "All", selected: tag == nil) { tag = nil }
                                ForEach(allTags, id: \.self) { t in TagChip(title: "#\(t)", selected: tag == t) { tag = tag == t ? nil : t } }
                            }
                        }
                    }
                    Spacer()
                    Picker("Sort", selection: $sort) { ForEach(Sort.allCases, id: \.self) { Text($0.rawValue) } }
                        .pickerStyle(.menu).labelsHidden().fixedSize()
                        .help("Sort decks by name or by when they were made")
                }
            }
        }
        .padding(12)
    }

    // MARK: Library

    private var groups: [(String, [DeckSearch.Deck])] {
        let byCategory = Dictionary(grouping: myDecks, by: \.categoryName)
        let names = byCategory.keys.sorted { a, b in
            if a == DeckSearch.Deck.uncategorised { return false }
            if b == DeckSearch.Deck.uncategorised { return true }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
        return names.map { name in
            let list = byCategory[name] ?? []
            let sorted = sort == .name
                ? list.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                : list.sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
            return (name, sorted)
        }
    }

    @ViewBuilder private var library: some View {
        if myDecks.isEmpty {
            ContentUnavailableView {
                Label(tag == nil ? "No decks yet" : "No decks tagged #\(tag!)", systemImage: "rectangle.stack")
            } description: {
                Text("Ask the assistant for a deck, open a sample, or get one from GitHub. Search above also looks through the samples.")
            } actions: {
                Button("Get Decks from GitHub") { model.slidesMode = .github }
                Button("Browse Samples") { model.slidesMode = .samples }
            }
        } else {
            List {
                ForEach(groups, id: \.0) { category, list in
                    Section {
                        ForEach(list) { deck in
                            DeckRow(deck: deck, isOpen: isOpen(deck), open: { open(deck, slide: 0) }, edit: { editing = deck })
                        }
                    } header: {
                        Text("\(category) · \(list.count)")
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    // MARK: Results

    @ViewBuilder private var results: some View {
        let hits = DeckSearch.search(query, in: decks)
        if hits.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            // Grouped by deck, decks in order of their best slide.
            let order = hits.reduce(into: [DeckSearch.Deck.Source]()) { if !$0.contains($1.deck) { $0.append($1.deck) } }
            List {
                Text("\(hits.count) slide\(hits.count == 1 ? "" : "s") in \(order.count) deck\(order.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(order, id: \.self) { source in
                    let deckHits = hits.filter { $0.deck == source }
                    let deck = decks.first { $0.source == source }
                    Section {
                        ForEach(deckHits) { hit in
                            Button { open(hit) } label: { HitRow(hit: hit, words: words) }
                                .buttonStyle(.plain)
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Text(deckHits[0].deckTitle)
                            if let deck { Text(deck.categoryName).foregroundStyle(.secondary) }
                            if case .sample = source { Text("Sample").font(.caption2).padding(.horizontal, 5).background(.quaternary, in: Capsule()) }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    // MARK: Opening

    private func isOpen(_ deck: DeckSearch.Deck) -> Bool {
        if case .project(let name) = deck.source { return model.builder.current?.name == name }
        return false
    }

    private func open(_ hit: DeckSearch.Hit) {
        guard let deck = decks.first(where: { $0.source == hit.deck }) else { return }
        open(deck, slide: hit.slide)
    }

    private func open(_ deck: DeckSearch.Deck, slide: Int) {
        do {
            switch deck.source {
            case .project(let name):
                model.builder.open(name, slide: slide)
            case .sample(let id):
                guard let sample = SampleDeck.all.first(where: { $0.id == id }) else { return }
                let p = try model.builder.openSample(sample)
                model.builder.open(p.name, slide: slide)
            }
            model.slidesMode = .present
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct DeckRow: View {
    let deck: DeckSearch.Deck
    let isOpen: Bool
    let open: () -> Void
    let edit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isOpen ? "play.rectangle.fill" : "rectangle.on.rectangle")
                .foregroundStyle(isOpen ? Color.accentColor : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(deck.title).font(.body.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(deck.slides.count) slide\(deck.slides.count == 1 ? "" : "s")")
                    if let first = deck.slides.dropFirst().first?.heading, !first.isEmpty { Text("· \(first)").lineLimit(1) }
                }
                .font(.caption).foregroundStyle(.secondary)
                if !deck.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(deck.tags, id: \.self) { Text("#\($0)").font(.caption2).foregroundStyle(Color.accentColor) }
                    }
                }
            }
            Spacer()
            Button("Open", action: open).controlSize(.small)
            Menu {
                Button("Category & Tags…", action: edit)
                Button("Open", action: open)
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Organise this deck")
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: open)
        .contextMenu {
            Button("Open", action: open)
            Button("Category & Tags…", action: edit)
        }
    }
}

private struct HitRow: View {
    let hit: DeckSearch.Hit
    let words: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("\(hit.slide + 1)").font(.caption.monospacedDigit().weight(.semibold))
                    .frame(minWidth: 22).padding(.vertical, 1)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                Text(highlighted(hit.heading)).font(.body.weight(.medium)).lineLimit(1)
                if hit.field == .notes {
                    Label("Notes", systemImage: "note.text").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if !hit.snippet.isEmpty {
                Text(highlighted(hit.snippet)).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .help("Open slide \(hit.slide + 1) of \(hit.deckTitle)")
    }

    /// The text with the search words in bold, ignoring case and accents.
    private func highlighted(_ text: String) -> AttributedString {
        var s = AttributedString(text)
        for w in words where !w.isEmpty {
            var from = s.startIndex
            while from < s.endIndex, let r = s[from...].range(of: w, options: [.caseInsensitive, .diacriticInsensitive]) {
                s[r].inlinePresentationIntent = .stronglyEmphasized
                s[r].foregroundColor = .primary
                from = r.upperBound
            }
        }
        return s
    }
}

private struct TagChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.caption)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(selected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1), in: Capsule())
                .foregroundStyle(selected ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
    }
}

/// Category and tags for one deck.
private struct DeckDetailsSheet: View {
    let deck: DeckSearch.Deck
    let categories: [String]
    let allTags: [String]
    let save: (String?, [String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var category = ""
    @State private var tagsText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Organise “\(deck.title)”").font(.headline)
            Form {
                HStack {
                    TextField("Category", text: $category, prompt: Text("e.g. Courses, Sales, Board"))
                    if !categories.isEmpty {
                        Menu("Pick") { ForEach(categories, id: \.self) { c in Button(c) { category = c } } }
                            .fixedSize()
                    }
                }
                TextField("Tags", text: $tagsText, prompt: Text("Comma-separated, e.g. AI, Q4, client"))
                if !allTags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(allTags.filter { !currentTags.map { $0.lowercased() }.contains($0.lowercased()) }, id: \.self) { t in
                                TagChip(title: "+ \(t)", selected: false) { tagsText = (currentTags + [t]).joined(separator: ", ") }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    save(category, currentTags)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            category = deck.category ?? ""
            tagsText = deck.tags.joined(separator: ", ")
        }
    }

    private var currentTags: [String] {
        BuilderProject.cleanTags(tagsText.split(separator: ",").map(String.init))
    }
}

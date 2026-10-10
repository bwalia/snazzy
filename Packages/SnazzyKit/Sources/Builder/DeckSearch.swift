import Foundation

/// Finds slides by their title, text or speaker notes, across every deck in the
/// workspace and the sample decks not opened yet. Pure and fast enough to run on
/// every keystroke for a few hundred slides.
public enum DeckSearch {
    public struct Slide: Sendable, Equatable {
        public var heading: String
        public var text: String
        public var notes: String

        public init(heading: String, text: String, notes: String) {
            self.heading = heading
            self.text = text
            self.notes = notes
        }
    }

    public struct Deck: Sendable, Equatable, Identifiable {
        public enum Source: Sendable, Equatable, Hashable {
            /// A Builder project (opened sample decks are projects too).
            case project(String)
            /// A sample deck that hasn't been opened yet.
            case sample(String)
        }

        public var source: Source
        public var title: String
        public var category: String?
        public var tags: [String]
        public var slides: [Slide]
        /// Newest first in the library when names are equal; samples have none.
        public var created: Date?
        public var id: Source { source }

        public init(source: Source, title: String, category: String? = nil, tags: [String] = [], slides: [Slide], created: Date? = nil) {
            self.source = source
            self.title = title
            self.category = category
            self.tags = tags
            self.slides = slides
            self.created = created
        }

        /// The category shown in the library when none was set.
        public static let uncategorised = "Uncategorised"
        public var categoryName: String { category ?? Self.uncategorised }
    }

    public struct Hit: Sendable, Equatable, Identifiable {
        public enum Field: String, Sendable { case heading, text, notes }

        public var deck: Deck.Source
        public var deckTitle: String
        /// 0-based, as `show_slide` and deck.js use it.
        public var slide: Int
        public var heading: String
        /// Where the best match is, and the text around it.
        public var field: Field
        public var snippet: String
        public var score: Int
        public var id: String { "\(deck)#\(slide)" }
    }

    // MARK: Loading

    /// Every presentation in the workspace, plus the samples that haven't been opened.
    public static func decks(in workspace: Workspace, samples: [SampleDeck] = SampleDeck.all) -> [Deck] {
        let projects = workspace.listProjects()
        var decks = projects.filter { $0.kind == .presentation }.compactMap { deck(project: $0.name, in: workspace) }
        let opened = Set(projects.map(\.name))
        decks += samples.filter { !opened.contains($0.projectName) }.map { sample in
            Deck(source: .sample(sample.id), title: sample.title, category: sample.sector.rawValue, tags: ["Sample"],
                 slides: sample.slides.map(slide(from:)))
        }
        return decks
    }

    /// A project's slides: from deck.json when the slide editor made it, otherwise from index.html.
    public static func deck(project: String, in workspace: Workspace) -> Deck? {
        guard var deck = slidesOnly(project: project, in: workspace) else { return nil }
        let meta = workspace.project(project)
        // Samples opened before decks had categories: their sector.
        deck.category = meta?.category ?? SampleDeck.all.first { $0.projectName == project }?.sector.rawValue
        deck.tags = meta?.tags ?? []
        deck.created = meta?.created
        return deck
    }

    private static func slidesOnly(project: String, in workspace: Workspace) -> Deck? {
        if let outline = DeckOutline.load(from: workspace, project: project) {
            // index.html may have been edited by the assistant since; trust it when it has slides.
            if let html = try? workspace.read(project: project, path: "index.html") {
                let slides = slides(fromHTML: html)
                if !slides.isEmpty { return Deck(source: .project(project), title: title(fromHTML: html) ?? outline.title, slides: slides) }
            }
            return Deck(source: .project(project), title: outline.title, slides: outline.slides.map(slide(from:)))
        }
        guard let html = try? workspace.read(project: project, path: "index.html") else { return nil }
        let slides = slides(fromHTML: html)
        guard !slides.isEmpty else { return nil }
        return Deck(source: .project(project), title: title(fromHTML: html) ?? project, slides: slides)
    }

    static func slide(from s: SampleDeck.Slide) -> Slide {
        Slide(heading: s.heading, text: s.items.joined(separator: " · "), notes: s.notes)
    }

    /// The `<section class="slide">` elements of a deck page, with their notes kept apart.
    public static func slides(fromHTML html: String) -> [Slide] {
        let page = html.replacingOccurrences(of: #"(?is)<(script|style)\b.*?</\1>"#, with: " ", options: .regularExpression)
        let sections = matches(#"(?is)<section\b[^>]*class\s*=\s*["'][^"']*\bslide\b[^"']*["'][^>]*>(.*?)</section>"#, in: page)
        return sections.map { body in
            let notes = matches(#"(?is)<aside\b[^>]*class\s*=\s*["'][^"']*\bnotes\b[^"']*["'][^>]*>(.*?)</aside>"#, in: body)
            let content = body.replacingOccurrences(of: #"(?is)<aside\b[^>]*class\s*=\s*["'][^"']*\bnotes\b[^"']*["'][^>]*>.*?</aside>"#,
                                                    with: " ", options: .regularExpression)
            let heading = matches(#"(?is)<(?:h1|h2|blockquote)\b[^>]*>(.*?)</(?:h1|h2|blockquote)>"#, in: content).first.map(plain) ?? ""
            var text = plain(content)
            if !heading.isEmpty, text.hasPrefix(heading) { text = String(text.dropFirst(heading.count)).trimmingCharacters(in: .whitespaces) }
            return Slide(heading: heading, text: text, notes: notes.map(plain).joined(separator: " "))
        }
    }

    static func title(fromHTML html: String) -> String? {
        matches(#"(?is)<title\b[^>]*>(.*?)</title>"#, in: html).first.map(plain).flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: Searching

    /// Slides containing every word of the query (ignoring case and accents), best first.
    public static func search(_ query: String, in decks: [Deck], limit: Int = 200) -> [Hit] {
        let words = fold(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return [] }
        let phrase = words.joined(separator: " ")
        var hits: [Hit] = []
        for deck in decks {
            for (i, s) in deck.slides.enumerated() {
                let h = fold(s.heading), t = fold(s.text), n = fold(s.notes)
                var score = 0
                var all = true
                for w in words {
                    if h.contains(w) { score += startsWord(w, in: h) ? 12 : 8 }
                    else if t.contains(w) { score += startsWord(w, in: t) ? 6 : 4 }
                    else if n.contains(w) { score += startsWord(w, in: n) ? 3 : 2 }
                    else if deck.tags.contains(where: { fold($0).contains(w) }) || fold(deck.category ?? "").contains(w) { score += 1 }
                    else if fold(deck.title).contains(w) { score += 1 }
                    else { all = false; break }
                }
                guard all else { continue }
                if words.count > 1 {
                    if h.contains(phrase) { score += 20 } else if t.contains(phrase) || n.contains(phrase) { score += 10 }
                }
                // Where to show the match: the first field holding the first word that isn't only in the deck title.
                let field: Hit.Field
                let source: String
                if words.contains(where: { h.contains($0) }) && !words.contains(where: { !h.contains($0) && (t.contains($0) || n.contains($0)) }) {
                    field = .heading; source = s.text.isEmpty ? s.heading : s.text
                } else if words.contains(where: { t.contains($0) }) {
                    field = .text; source = s.text
                } else if words.contains(where: { n.contains($0) }) {
                    field = .notes; source = s.notes
                } else {
                    field = .heading; source = s.text
                }
                hits.append(Hit(deck: deck.source, deckTitle: deck.title, slide: i, heading: s.heading.isEmpty ? "Slide \(i + 1)" : s.heading,
                                field: field, snippet: snippet(source, around: words), score: score))
            }
        }
        // Best first; ties keep deck and slide order.
        return Array(hits.enumerated().sorted { a, b in
            a.element.score != b.element.score ? a.element.score > b.element.score : a.offset < b.offset
        }.map(\.element).prefix(limit))
    }

    /// About `width` characters of `text` around the first matching word, on word boundaries.
    public static func snippet(_ text: String, around words: [String], width: Int = 140) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > width else { return clean }
        let folded = fold(clean)
        // Folding keeps the length for nearly all text; fall back to the start if it doesn't.
        let hit = folded.count == clean.count
            ? words.compactMap { folded.range(of: $0).map { folded.distance(from: folded.startIndex, to: $0.lowerBound) } }.min() ?? 0
            : 0
        var start = max(0, hit - width / 3)
        let chars = Array(clean)
        while start > 0, !chars[start - 1].isWhitespace { start -= 1 }
        var end = min(chars.count, start + width)
        while end < chars.count, !chars[end].isWhitespace { end += 1 }
        let body = String(chars[start..<end]).trimmingCharacters(in: .whitespaces)
        return (start > 0 ? "…" : "") + body + (end < chars.count ? "…" : "")
    }

    // MARK: Helpers

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    private static func startsWord(_ w: String, in s: String) -> Bool {
        var from = s.startIndex
        while let r = s.range(of: w, range: from..<s.endIndex) {
            if r.lowerBound == s.startIndex || !s[s.index(before: r.lowerBound)].isLetter { return true }
            from = s.index(after: r.lowerBound)
        }
        return false
    }

    private static func matches(_ pattern: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap {
            $0.numberOfRanges > 1 && $0.range(at: 1).location != NSNotFound ? ns.substring(with: $0.range(at: 1)) : nil
        }
    }

    /// Visible text of an HTML fragment: tags removed, entities decoded, spaces collapsed.
    static func plain(_ html: String) -> String {
        // List items and column headings read as "a · b · c"; other blocks just get a space.
        var s = html.replacingOccurrences(of: #"(?i)</(li|h3|h4)>"#, with: " · ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)<br\s*/?>|</(p|div|h\d|td|th|b|span)>"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, char) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
                               ("&mdash;", "—"), ("&ndash;", "–"), ("&hellip;", "…"), ("&rarr;", "→"), ("&middot;", "·"), ("&amp;", "&")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        if let re = try? NSRegularExpression(pattern: #"&#(x?)([0-9a-fA-F]+);"#) {
            let ns = s as NSString
            var out = ""
            var last = 0
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let hex = ns.substring(with: m.range(at: 1)) == "x"
                let value = UInt32(ns.substring(with: m.range(at: 2)), radix: hex ? 16 : 10)
                out += value.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ns.substring(with: m.range)
                last = m.range.location + m.range.length
            }
            s = out + ns.substring(from: last)
        }
        var words = s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        // No separators at the ends or twice in a row.
        words = words.enumerated().filter { i, w in w != "·" || (i > 0 && words[i - 1] != "·") }.map(\.element)
        while words.first == "·" { words.removeFirst() }
        while words.last == "·" { words.removeLast() }
        return words.joined(separator: " ")
    }
}

import Foundation
import SnazzyCore

/// Ideas from the room: students post short notes and vote; the host
/// moderates (hide, delete, close) and the assistant turns them into a deck.
public struct BrainstormBoard: Sendable, Equatable {
    public struct Note: Sendable, Equatable, Identifiable {
        public let id: String
        public var text: String
        public var author: String
        public var created: Date
        public var voters: Set<String>
        public var hidden: Bool
        /// Who posted it (browser ID), so one person can't flood the board.
        let poster: String

        public var votes: Int { voters.count }
    }

    public enum BoardError: LocalizedError, Equatable {
        case closed, empty, tooLong, full, tooFast, unknownNote

        public var errorDescription: String? {
            switch self {
            case .closed: "The board is closed."
            case .empty: "Write an idea first."
            case .tooLong: "Keep ideas under \(BrainstormBoard.maxTextLength) characters."
            case .full: "The board is full."
            case .tooFast: "Wait a moment before posting again."
            case .unknownNote: "That idea is no longer on the board."
            }
        }
    }

    public static let maxTextLength = 280
    public static let maxAuthorLength = 40
    public static let maxNotes = 300
    public static let maxNotesPerPerson = 20
    /// Minimum time between posts from one browser.
    public static let postInterval: TimeInterval = 3

    public var topic: String
    public var isOpen: Bool
    public private(set) var notes: [Note] = []
    /// Bumped on every change, so viewers can tell when to refresh.
    public private(set) var revision = 0

    public init(topic: String = "", isOpen: Bool = true) {
        self.topic = topic
        self.isOpen = isOpen
    }

    // MARK: From the room

    @discardableResult
    public mutating func add(text: String, author: String, poster: String, now: Date = Date()) throws -> Note {
        guard isOpen else { throw BoardError.closed }
        let clean = Self.clean(text, max: Self.maxTextLength + 1)
        guard !clean.isEmpty else { throw BoardError.empty }
        guard clean.count <= Self.maxTextLength else { throw BoardError.tooLong }
        guard notes.count < Self.maxNotes else { throw BoardError.full }
        let mine = notes.filter { $0.poster == poster }
        guard mine.count < Self.maxNotesPerPerson else { throw BoardError.full }
        if let last = mine.map(\.created).max(), now.timeIntervalSince(last) < Self.postInterval { throw BoardError.tooFast }
        let name = Self.clean(author, max: Self.maxAuthorLength)
        let note = Note(id: UUID().uuidString.prefix(8).lowercased(), text: clean, author: name.isEmpty ? "Anonymous" : name,
                        created: now, voters: [], hidden: false, poster: poster)
        notes.append(note)
        revision += 1
        return note
    }

    /// Toggles a vote (one per browser per idea). Returns whether it's now voted.
    @discardableResult
    public mutating func vote(_ id: String, voter: String) throws -> Bool {
        guard isOpen else { throw BoardError.closed }
        guard let i = notes.firstIndex(where: { $0.id == id && !$0.hidden }) else { throw BoardError.unknownNote }
        let on = !notes[i].voters.contains(voter)
        if on { notes[i].voters.insert(voter) } else { notes[i].voters.remove(voter) }
        revision += 1
        return on
    }

    // MARK: Host

    public mutating func setHidden(_ id: String, _ hidden: Bool) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].hidden = hidden
        revision += 1
    }

    public mutating func delete(_ id: String) {
        notes.removeAll { $0.id == id }
        revision += 1
    }

    public mutating func clear() {
        notes.removeAll()
        revision += 1
    }

    public mutating func setTopic(_ topic: String) {
        self.topic = Self.clean(topic, max: 200)
        revision += 1
    }

    public mutating func setOpen(_ open: Bool) {
        isOpen = open
        revision += 1
    }

    // MARK: Views

    /// Visible ideas, most votes first (then oldest first).
    public var ranked: [Note] {
        notes.filter { !$0.hidden }.sorted { $0.votes != $1.votes ? $0.votes > $1.votes : $0.created < $1.created }
    }

    /// What viewers see (hidden ideas and voter IDs left out; `mine` marks the
    /// viewer's own votes).
    public func publicJSON(for voter: String? = nil) -> JSONValue {
        [
            "revision": .number(Double(revision)),
            "topic": .string(topic),
            "open": .bool(isOpen),
            "notes": .array(ranked.map { n in
                [
                    "id": .string(n.id), "text": .string(n.text), "author": .string(n.author),
                    "votes": .number(Double(n.votes)), "voted": .bool(voter.map { n.voters.contains($0) } ?? false),
                ]
            }),
        ]
    }

    /// For the assistant: the ideas with votes, as plain text.
    public var summaryText: String {
        let lines = ranked.map { "- \($0.text) (\($0.votes) vote\($0.votes == 1 ? "" : "s"), \($0.author))" }
        return (topic.isEmpty ? "" : "Topic: \(topic)\n") + (lines.isEmpty ? "No ideas yet." : lines.joined(separator: "\n"))
    }

    /// Single line, trimmed, control characters removed, capped.
    static func clean(_ s: String, max: Int) -> String {
        let scalars = s.unicodeScalars.map { $0.properties.generalCategory == .control || $0 == "\u{2028}" || $0 == "\u{2029}" ? " " : Character($0) }
        let joined = String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(joined.prefix(max))
    }
}

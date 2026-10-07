import Foundation
import SnazzyCore

/// A saved chat: the provider-neutral history plus a title.
public struct Conversation: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var created: Date
    public var updated: Date
    public var messages: [ChatMessage]
    /// Tokens used across the conversation.
    public var inputTokens: Int
    public var outputTokens: Int

    public init(id: UUID = UUID(), title: String = "New conversation", created: Date = Date(),
                messages: [ChatMessage] = [], inputTokens: Int = 0, outputTokens: Int = 0) {
        self.id = id
        self.title = title
        self.created = created
        self.updated = created
        self.messages = messages
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    /// A title from the first user message.
    public static func title(from text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "New conversation" }
        return trimmed.count > 60 ? String(trimmed.prefix(57)) + "…" : trimmed
    }

    /// History up to (not including) the user message with this ID; used to
    /// edit or retry a turn. Earlier turns are kept unchanged.
    public func truncated(before messageID: UUID) -> [ChatMessage] {
        guard let i = messages.firstIndex(where: { $0.id == messageID }) else { return messages }
        return Array(messages[..<i])
    }
}

public struct ConversationSummary: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var updated: Date
}

/// One JSON file per conversation in a directory.
public struct ConversationStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Application Support/Snazzy Pro/Conversations` (inside the sandbox container).
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Snazzy Pro/Conversations", directoryHint: .isDirectory)
    }

    private func url(_ id: UUID) -> URL { directory.appending(path: "\(id.uuidString).json") }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public func save(_ conversation: Conversation) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(conversation).write(to: url(conversation.id), options: .atomic)
    }

    public func load(_ id: UUID) throws -> Conversation {
        try Self.decoder.decode(Conversation.self, from: Data(contentsOf: url(id)))
    }

    public func delete(_ id: UUID) throws {
        try? FileManager.default.removeItem(at: url(id))
    }

    /// Newest first. Unreadable files are skipped.
    public func list() -> [ConversationSummary] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? Self.decoder.decode(Conversation.self, from: Data(contentsOf: $0)) }
            .map { ConversationSummary(id: $0.id, title: $0.title, updated: $0.updated) }
            .sorted { $0.updated > $1.updated }
    }
}

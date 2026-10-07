import Foundation
import Testing
@testable import Assistant
@testable import SnazzyCore

@Suite struct ConversationTests {
    @Test func storeRoundTripAndListing() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "snazzy-conv-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConversationStore(directory: dir)
        #expect(store.list().isEmpty)

        var a = Conversation(title: "First", messages: [
            .user("hello"),
            ChatMessage(role: .assistant, parts: [
                .opaque(provider: .anthropic, block: ["type": "thinking", "thinking": "x", "signature": "s"]),
                .text("hi"), .toolCall(ToolCall(id: "t1", name: "list_devices", arguments: [:])),
            ]),
            ChatMessage(role: .tool, parts: [.toolResult(ToolResult(callID: "t1", name: "list_devices", content: "{}"))]),
            ChatMessage(role: .user, parts: [.image(mediaType: "image/png", data: Data([1, 2, 3])), .text("look")]),
        ])
        a.updated = Date(timeIntervalSince1970: 1000)
        var b = Conversation(title: "Second")
        b.updated = Date(timeIntervalSince1970: 2000)
        try store.save(a)
        try store.save(b)

        let loaded = try store.load(a.id)
        #expect(loaded.messages == a.messages)
        #expect(store.list().map(\.title) == ["Second", "First"])
        try store.delete(b.id)
        #expect(store.list().map(\.title) == ["First"])
    }

    @Test func titlesAndTruncation() {
        #expect(Conversation.title(from: "  Make a deck\nwith details") == "Make a deck")
        #expect(Conversation.title(from: String(repeating: "a", count: 80)).count == 58)
        let first = ChatMessage.user("one"), second = ChatMessage.user("two")
        let c = Conversation(messages: [first, ChatMessage(role: .assistant, parts: [.text("ok")]), second])
        #expect(c.truncated(before: second.id).count == 2)
        #expect(c.truncated(before: first.id).isEmpty)
    }
}

import AppKit

/// Shows exactly what would be sent to a cloud AI provider and asks first.
/// Used whenever a developer feature would send text (transcripts, diffs,
/// screen text) to a cloud model.
@MainActor
enum CloudReview {
    static func confirm(provider: String, what: String, text: String, note: String? = nil) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Send \(what) to \(provider)?"
        alert.informativeText = (note.map { $0 + "\n\n" } ?? "") +
            "This is exactly what will be sent (\(text.count.formatted()) characters). Nothing else, and no audio or video."
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 260))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let view = NSTextView(frame: scroll.bounds)
        view.isEditable = false
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.string = text.count > 40_000 ? String(text.prefix(40_000)) + "\n… (\(text.count - 40_000) more characters)" : text
        view.autoresizingMask = [.width]
        scroll.documentView = view
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Don't Send")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
}

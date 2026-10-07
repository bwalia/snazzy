import Foundation
import SnazzyCore

/// A timestamped record of a working session with the assistant: messages,
/// tool calls, builder steps and voice clips, in
/// `~/Movies/Snazzy Pro/Sessions/<date> <title>/`. Screen and camera video of
/// the session come with the recorder (phase 4).
@MainActor
final class SessionLog {
    private(set) var folder: URL?
    private var handle: FileHandle?
    private let conversationID: UUID
    private var title: String

    static var root: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appending(path: "Snazzy Pro/Sessions", directoryHint: .isDirectory)
    }

    init(conversationID: UUID, title: String) {
        self.conversationID = conversationID
        self.title = title
    }

    /// Folder for voice clips (created on first use).
    func audioFolder() -> URL? {
        ensureOpen()
        return folder?.appending(path: "audio", directoryHint: .isDirectory)
    }

    func log(_ type: String, _ fields: [String: JSONValue] = [:]) {
        ensureOpen()
        guard let handle else { return }
        var entry = fields
        entry["t"] = .string(Self.iso.string(from: Date()))
        entry["type"] = .string(type)
        let line = JSONValue.object(entry).compactString + "\n"
        try? handle.write(contentsOf: Data(line.utf8))
    }

    func close() {
        try? handle?.close()
        handle = nil
    }

    private func ensureOpen() {
        guard handle == nil else { return }
        let safeTitle = title.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
        let name = "\(Self.folderStamp.string(from: Date())) \(safeTitle.prefix(50))".trimmingCharacters(in: .whitespaces)
        let dir = Self.root.appending(path: name, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appending(path: "session.jsonl")
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil)
            }
            handle = try FileHandle(forWritingTo: file)
            try handle?.seekToEnd()
            folder = dir
            let header: [String: JSONValue] = ["conversation": .string(conversationID.uuidString), "title": .string(title)]
            let line = JSONValue.object(header.merging(["type": "session_start", "t": .string(Self.iso.string(from: Date()))]) { a, _ in a }).compactString + "\n"
            try handle?.write(contentsOf: Data(line.utf8))
        } catch {
            Log.app.error("Session log unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let folderStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()
}

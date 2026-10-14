import Foundation

/// Kits, interviews and self-ID answers on disk:
/// `<root>/Kits/<id>.json`, `<root>/Interviews/<id>.json`, `<root>/SelfID/<key>.json`.
/// Files are written atomically and readable only by the user.
public final class InterviewStore: @unchecked Sendable {
    public let root: URL
    private let lock = NSLock()

    public init(root: URL) {
        self.root = root
    }

    var kitsDir: URL { root.appendingPathComponent("Kits", isDirectory: true) }
    var interviewsDir: URL { root.appendingPathComponent("Interviews", isDirectory: true) }
    var selfIDDir: URL { root.appendingPathComponent("SelfID", isDirectory: true) }

    // MARK: Kits

    public func kits() -> [RoleKit] {
        load(RoleKit.self, from: kitsDir).sorted { $0.updated > $1.updated }
    }

    public func save(_ kit: RoleKit) throws {
        try write(kit, to: kitsDir.appendingPathComponent("\(kit.id.uuidString).json"))
    }

    public func deleteKit(_ id: UUID) throws {
        try remove(kitsDir.appendingPathComponent("\(id.uuidString).json"))
    }

    // MARK: Interviews

    public func interviews() -> [InterviewSession] {
        load(InterviewSession.self, from: interviewsDir).sorted { $0.created > $1.created }
    }

    public func interview(_ id: UUID) -> InterviewSession? {
        let url = interviewsDir.appendingPathComponent("\(id.uuidString).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? InterviewJSON.decoder.decode(InterviewSession.self, from: data)
    }

    public func save(_ session: InterviewSession) throws {
        try write(session, to: interviewsDir.appendingPathComponent("\(session.id.uuidString).json"))
    }

    /// Deletes an interview and its self-ID answers.
    public func deleteInterview(_ session: InterviewSession) throws {
        try remove(interviewsDir.appendingPathComponent("\(session.id.uuidString).json"))
        if let key = session.selfIDKey { try remove(selfIDDir.appendingPathComponent("\(key).json")) }
    }

    /// Deletes interviews past their `deleteAfter` date; returns how many.
    @discardableResult
    public func purgeExpired(now: Date = Date()) -> Int {
        var n = 0
        for s in interviews() where (s.deleteAfter ?? .distantFuture) < now {
            if (try? deleteInterview(s)) != nil { n += 1 }
        }
        return n
    }

    // MARK: Self-ID

    public func save(_ selfID: SelfID) throws {
        try write(selfID, to: selfIDDir.appendingPathComponent("\(selfID.key).json"))
    }

    public func selfIDs() -> [SelfID] { load(SelfID.self, from: selfIDDir) }

    // MARK: Files

    private func load<T: Decodable>(_ type: T.Type, from dir: URL) -> [T] {
        lock.withLock {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            return files.filter { $0.pathExtension == "json" }.compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? InterviewJSON.decoder.decode(T.self, from: data)
            }
        }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try lock.withLock {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try InterviewJSON.encoder.encode(value)
            try data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    private func remove(_ url: URL) throws {
        try lock.withLock {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }
}

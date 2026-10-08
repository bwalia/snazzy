import Foundation
import SnazzyCore

public enum ProjectKind: String, Codable, CaseIterable, Sendable {
    /// An interactive app prototype (HTML/CSS/JS).
    case prototype
    /// A presentation as an HTML slide deck.
    case presentation
}

public struct BuilderProject: Codable, Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var kind: ProjectKind
    public var created: Date
}

public struct WorkspaceError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Projects built by the assistant, one folder each, inside a root folder.
/// All paths are resolved inside the project: nothing outside it can be
/// read or written.
public struct Workspace: Sendable {
    public let root: URL
    public static let maxFileBytes = 2_000_000

    public init(root: URL) { self.root = root }

    /// `~/Library/Application Support/Snazzy Pro/Projects` (inside the sandbox container).
    public static func defaultRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Snazzy Pro/Projects", directoryHint: .isDirectory)
    }

    /// Lower-case, dash-separated ASCII folder name (accents and other scripts are
    /// transliterated: "Café 日本" → "cafe-ri-ben"). ASCII because it's also the host of
    /// the project's `snazzy-project://` URL, where anything else gets encoded.
    public static func slug(_ name: String) -> String {
        let latin = name.applyingTransform(.toLatin, reverse: false)?.applyingTransform(.stripCombiningMarks, reverse: false) ?? name
        let parts = latin.lowercased().split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }.map(String.init)
        let slug = parts.joined(separator: "-")
        return slug.isEmpty ? "project" : String(slug.prefix(60))
    }

    public func projectURL(_ name: String) -> URL { root.appending(path: Self.slug(name), directoryHint: .isDirectory) }

    public func listProjects() -> [BuilderProject] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { dir in
            let meta = dir.appending(path: ".snazzy-project.json")
            guard let data = try? Data(contentsOf: meta) else { return nil }
            return try? JSONDecoder.iso.decode(BuilderProject.self, from: data)
        }
        .sorted { $0.created > $1.created }
    }

    /// Creates a project with starter files (or returns the existing one).
    @discardableResult
    public func createProject(name: String, kind: ProjectKind, title: String? = nil) throws -> BuilderProject {
        let slug = Self.slug(name)
        let dir = projectURL(slug)
        let meta = dir.appending(path: ".snazzy-project.json")
        if let data = try? Data(contentsOf: meta), let existing = try? JSONDecoder.iso.decode(BuilderProject.self, from: data) {
            return existing
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let project = BuilderProject(name: slug, kind: kind, created: Date())
        try JSONEncoder.iso.encode(project).write(to: meta)
        for (path, content) in Templates.files(for: kind, title: title ?? name) {
            try write(project: slug, path: path, content: content)
        }
        return project
    }

    public func deleteProject(_ name: String) throws {
        let dir = projectURL(name)
        guard FileManager.default.fileExists(atPath: dir.path) else { throw WorkspaceError("No project named \(name)") }
        try FileManager.default.removeItem(at: dir)
    }

    /// Resolves a relative path inside a project; rejects anything that escapes it.
    public func resolve(project: String, path: String) throws -> URL {
        let dir = projectURL(project).standardizedFileURL
        let cleaned = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !cleaned.hasPrefix("/"), !cleaned.hasPrefix("~") else {
            throw WorkspaceError("Use a relative path inside the project, like \"index.html\" or \"js/app.js\".")
        }
        let url = dir.appending(path: cleaned).standardizedFileURL
        guard url.path.hasPrefix(dir.path + "/") else {
            throw WorkspaceError("Path \"\(path)\" is outside the project.")
        }
        // Projects never contain symlinks (the tools and imports can't make them), so any
        // symlink on the way, even a dangling one, is refused: it could lead outside.
        var step = dir
        for part in url.path.dropFirst(dir.path.count + 1).split(separator: "/") {
            step.append(path: String(part))
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: step.path)) != nil {
                throw WorkspaceError("Path \"\(path)\" is outside the project.")
            }
        }
        guard !url.lastPathComponent.hasPrefix(".snazzy") else { throw WorkspaceError("That file is reserved.") }
        return url
    }

    public func write(project: String, path: String, content: String) throws {
        guard content.utf8.count <= Self.maxFileBytes else { throw WorkspaceError("File too large (max 2 MB).") }
        let url = try resolve(project: project, path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url, options: .atomic)
    }

    public func read(project: String, path: String) throws -> String {
        let url = try resolve(project: project, path: path)
        guard let data = try? Data(contentsOf: url) else { throw WorkspaceError("No file \"\(path)\" in \(project).") }
        guard let text = String(data: data, encoding: .utf8) else { throw WorkspaceError("\"\(path)\" is not a text file.") }
        return text
    }

    public func delete(project: String, path: String) throws {
        let url = try resolve(project: project, path: path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw WorkspaceError("No file \"\(path)\".") }
        try FileManager.default.removeItem(at: url)
    }

    /// Relative file paths, sorted, excluding metadata.
    public func files(project: String) -> [String] {
        let dir = projectURL(project).standardizedFileURL
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: [String] = []
        for case let url as URL in e {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let rel = String(url.standardizedFileURL.path.dropFirst(dir.path.count + 1))
            if !rel.hasPrefix(".snazzy") { out.append(rel) }
        }
        return out.sorted()
    }
}

extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}

extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

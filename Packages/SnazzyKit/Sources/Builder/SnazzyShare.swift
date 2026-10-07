import Compression
import Foundation
import SnazzyCore

/// A `.snazzy` share file: a Builder project, presets and background images,
/// passed between Snazzy Pro users by AirDrop, Messages, Mail or a file.
///
/// Never included: API keys (they live in the Keychain and aren't in presets),
/// conversations and recordings.
///
/// On disk: an 8-byte magic header, then zlib-compressed JSON. Reading is
/// defensive (size caps while decompressing, path checks on import), because
/// the file may come from anyone.
public struct SnazzyShare: Codable, Sendable, Equatable {
    public static let fileExtension = "snazzy"
    public static let typeIdentifier = "com.snazzy.pro.share"
    static let magic = Data("SNZSHR01".utf8)

    /// Limits for files received from others.
    public static let maxCompressedBytes = 200_000_000
    public static let maxExpandedBytes = 300_000_000
    public static let maxFiles = 2_000
    public static let maxImages = 50
    public static let maxPresets = 50

    public struct Project: Codable, Sendable, Equatable {
        public var name: String
        public var kind: ProjectKind
        public var files: [File]

        public init(name: String, kind: ProjectKind, files: [File]) {
            self.name = name
            self.kind = kind
            self.files = files
        }
    }

    public struct File: Codable, Sendable, Equatable {
        public var path: String
        public var data: Data

        public init(path: String, data: Data) {
            self.path = path
            self.data = data
        }
    }

    public struct Image: Codable, Sendable, Equatable {
        /// The ID presets use to refer to it (`CameraBackground.image(id:)`).
        public var id: String
        public var name: String
        public var data: Data

        public init(id: String, name: String, data: Data) {
            self.id = id
            self.name = name
            self.data = data
        }
    }

    public var format = "snazzy-share"
    public var version = 1
    public var title: String
    public var created: Date
    /// Optional note from the sender ("Here's the deck for Monday").
    public var note: String
    public var project: Project?
    public var presets: [SettingsPreset]
    public var backgrounds: [Image]

    public init(title: String, note: String = "", project: Project?, presets: [SettingsPreset] = [], backgrounds: [Image] = [], created: Date = Date()) {
        self.title = title
        self.note = note
        self.project = project
        self.presets = presets
        self.backgrounds = backgrounds
        self.created = created
    }

    public var isEmpty: Bool { project == nil && presets.isEmpty && backgrounds.isEmpty }

    /// One line per part, for "here's what will be shared / imported" screens.
    public var contentsSummary: [String] {
        var out: [String] = []
        if let p = project {
            let bytes = p.files.reduce(0) { $0 + $1.data.count }
            out.append("\(p.kind == .presentation ? "Slide deck" : "Prototype") “\(p.name)”: \(p.files.count) file\(p.files.count == 1 ? "" : "s"), \(Self.formatBytes(bytes))")
        }
        for preset in presets { out.append("Preset “\(preset.name)”") }
        for image in backgrounds { out.append("Background image “\(image.name)” (\(Self.formatBytes(image.data.count)))") }
        return out
    }

    public static func formatBytes(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }

    // MARK: Encoding

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(self)
        guard json.count <= Self.maxExpandedBytes else { throw WorkspaceError("This is too big to share (over \(Self.formatBytes(Self.maxExpandedBytes))).") }
        let compressed = try (json as NSData).compressed(using: .zlib) as Data
        return Self.magic + compressed
    }

    public static func decode(_ data: Data) throws -> SnazzyShare {
        guard data.count <= maxCompressedBytes else { throw WorkspaceError("This file is too big to open.") }
        guard data.prefix(magic.count) == magic else { throw WorkspaceError("This isn't a Snazzy Pro share file.") }
        let json = try inflate(data.dropFirst(magic.count), limit: maxExpandedBytes)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let share: SnazzyShare
        do { share = try decoder.decode(SnazzyShare.self, from: json) } catch {
            throw WorkspaceError("This share file is damaged or from a newer version of Snazzy Pro.")
        }
        guard share.format == "snazzy-share" else { throw WorkspaceError("This isn't a Snazzy Pro share file.") }
        guard share.version <= 1 else { throw WorkspaceError("This file needs a newer version of Snazzy Pro.") }
        try share.validate()
        return share
    }

    /// Checks everything that will be written to disk on import.
    func validate() throws {
        if let p = project {
            guard p.files.count <= Self.maxFiles else { throw WorkspaceError("Too many files in this project.") }
            for f in p.files {
                guard Self.isSafeRelativePath(f.path) else { throw WorkspaceError("Unsafe file path in share: \(f.path)") }
            }
            guard Set(p.files.map(\.path)).count == p.files.count else { throw WorkspaceError("Duplicate files in share.") }
        }
        guard backgrounds.count <= Self.maxImages, presets.count <= Self.maxPresets else { throw WorkspaceError("Too many items in this share file.") }
    }

    /// Relative, no `..`, no hidden or reserved components, no backslashes or control characters.
    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.count < 512, !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\\") else { return false }
        guard !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") }
    }

    /// zlib (raw deflate, as NSData.compressed(using: .zlib) writes) with an output cap.
    static func inflate(_ data: Data, limit: Int) throws -> Data {
        var output = Data()
        var input = data[...]
        let filter = try InputFilter(.decompress, using: .zlib) { (length: Int) -> Data? in
            let chunk = input.prefix(length)
            input = input.dropFirst(chunk.count)
            return chunk.isEmpty ? nil : Data(chunk)
        }
        do {
            while let page = try filter.readData(ofLength: 1 << 16), !page.isEmpty {
                output.append(page)
                guard output.count <= limit else { throw WorkspaceError("This file is too big to open.") }
            }
        } catch let e as WorkspaceError {
            throw e
        } catch {
            throw WorkspaceError("This share file is damaged.")
        }
        return output
    }
}

// MARK: - Background references in presets

extension SnazzyShare {
    /// IDs of user background images a preset uses (`{"image": {"id": …}}` anywhere in it).
    public static func imageIDs(in preset: SettingsPreset) -> Set<String> {
        guard let json = try? toJSON(preset) else { return [] }
        var ids = Set<String>()
        func walk(_ v: JSONValue) {
            switch v {
            case .object(let o):
                if let id = o["image"]?["id"]?.stringValue, o.count == 1 { ids.insert(id) }
                o.values.forEach(walk)
            case .array(let a): a.forEach(walk)
            default: break
            }
        }
        walk(json)
        return ids
    }

    /// The preset with background image IDs replaced (images get new IDs when imported).
    public static func remapImages(in preset: SettingsPreset, _ map: [String: String]) -> SettingsPreset {
        guard !map.isEmpty, let json = try? toJSON(preset) else { return preset }
        func walk(_ v: JSONValue) -> JSONValue {
            switch v {
            case .object(var o):
                if o.count == 1, let id = o["image"]?["id"]?.stringValue, let new = map[id] {
                    return ["image": ["id": .string(new)]]
                }
                for (k, child) in o { o[k] = walk(child) }
                return .object(o)
            case .array(let a): return .array(a.map(walk))
            default: return v
            }
        }
        return (try? fromJSON(walk(json), SettingsPreset.self)) ?? preset
    }
}

private func toJSON<T: Encodable>(_ value: T) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
}

private func fromJSON<T: Decodable>(_ json: JSONValue, _ type: T.Type) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONEncoder().encode(json))
}

// MARK: - Workspace

extension Workspace {
    /// A project's files for sharing (hidden files and Snazzy metadata left out).
    public func shareProject(_ name: String) throws -> SnazzyShare.Project {
        guard let project = listProjects().first(where: { $0.name == Workspace.slug(name) }) else { throw WorkspaceError("No project named \(name)") }
        var files: [SnazzyShare.File] = []
        var total = 0
        for path in self.files(project: project.name) where SnazzyShare.isSafeRelativePath(path) {
            let data = try Data(contentsOf: try resolve(project: project.name, path: path))
            total += data.count
            guard total <= SnazzyShare.maxExpandedBytes else { throw WorkspaceError("This project is too big to share.") }
            files.append(.init(path: path, data: data))
        }
        return .init(name: project.name, kind: project.kind, files: files)
    }

    /// Imports a shared project under a free name ("deck", "deck-2", …). Returns the new project.
    @discardableResult
    public func importProject(_ shared: SnazzyShare.Project) throws -> BuilderProject {
        let base = Workspace.slug(shared.name).isEmpty ? "shared" : Workspace.slug(shared.name)
        let existing = Set(listProjects().map(\.name))
        var name = base
        var n = 2
        while existing.contains(name) || FileManager.default.fileExists(atPath: projectURL(name).path) {
            name = "\(base)-\(n)"
            n += 1
        }
        let dir = projectURL(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let project = BuilderProject(name: name, kind: shared.kind, created: Date())
        try JSONEncoder.iso.encode(project).write(to: dir.appending(path: ".snazzy-project.json"))
        do {
            for file in shared.files {
                guard SnazzyShare.isSafeRelativePath(file.path) else { throw WorkspaceError("Unsafe file path: \(file.path)") }
                let url = try resolve(project: name, path: file.path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try file.data.write(to: url, options: .atomic)
            }
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        return project
    }
}

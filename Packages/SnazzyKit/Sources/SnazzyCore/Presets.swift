import Foundation

/// A named snapshot of Snazzy Pro's settings that can be loaded later, e.g.
/// "Q3 deck, iPad bottom-right" or "Demo: LG screen, no inset".
/// API keys are never part of a preset (they stay in the Keychain).
public struct SettingsPreset: Codable, Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var notes: String
    public var created: Date
    public var updated: Date
    /// Microphone, screen/window, inset camera, layout and per-device crop/rotation.
    public var capture: CaptureSetup?
    /// Models per task, effort, voice and session options.
    public var app: AppSettings?

    public init(name: String, notes: String = "", capture: CaptureSetup?, app: AppSettings?, date: Date = Date()) {
        self.name = name
        self.notes = notes
        self.created = date
        self.updated = date
        self.capture = capture
        self.app = app
    }
}

/// Which parts of a preset to apply.
public struct PresetParts: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let capture = PresetParts(rawValue: 1)
    public static let models = PresetParts(rawValue: 2)
    public static let all: PresetParts = [.capture, .models]
}

public struct PresetStore: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Snazzy Pro/Presets", directoryHint: .isDirectory)
    }

    /// File-safe name (presets are matched case-insensitively by name).
    static func fileName(_ name: String) -> String {
        let cleaned = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let slug = String(cleaned).split(separator: "-").joined(separator: "-")
        return (slug.isEmpty ? "preset" : String(slug.prefix(80))) + ".json"
    }

    private func url(_ name: String) -> URL { directory.appending(path: Self.fileName(name)) }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Saves (or replaces) a preset; keeps the original creation date.
    public func save(_ preset: SettingsPreset) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var p = preset
        if let existing = load(preset.name) {
            p.created = existing.created
            p.updated = Date()
        }
        try Self.encoder.encode(p).write(to: url(p.name), options: .atomic)
    }

    public func load(_ name: String) -> SettingsPreset? {
        if let data = try? Data(contentsOf: url(name)), let p = try? Self.decoder.decode(SettingsPreset.self, from: data) {
            return p
        }
        // Fall back to a case-insensitive / partial name match.
        let all = list()
        let lower = name.lowercased()
        return all.first { $0.name.lowercased() == lower } ?? all.first { $0.name.lowercased().contains(lower) }
    }

    public func delete(_ name: String) throws {
        guard let p = load(name) else { throw PresetError("No preset named “\(name)”.") }
        try FileManager.default.removeItem(at: url(p.name))
    }

    /// Most recently updated first.
    public func list() -> [SettingsPreset] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? Self.decoder.decode(SettingsPreset.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updated > $1.updated }
    }
}

public struct PresetError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

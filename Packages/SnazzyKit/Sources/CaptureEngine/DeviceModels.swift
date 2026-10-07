import CoreGraphics
import Foundation
import SnazzyCore

public struct CaptureDeviceInfo: Identifiable, Hashable, Sendable {
    public var id: String  // AVCaptureDevice.uniqueID
    public var name: String
    public var modelID: String
    public var manufacturer: String
    public var kind: DeviceKind
    /// Continuity Camera, USB, built-in…
    public var transport: String

    public init(id: String, name: String, modelID: String, manufacturer: String, kind: DeviceKind, transport: String) {
        self.id = id
        self.name = name
        self.modelID = modelID
        self.manufacturer = manufacturer
        self.kind = kind
        self.transport = transport
    }
}

public struct MicrophoneInfo: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var manufacturer: String
    public var isDefault: Bool

    public init(id: String, name: String, manufacturer: String, isDefault: Bool) {
        self.id = id
        self.name = name
        self.manufacturer = manufacturer
        self.isDefault = isDefault
    }
}

public struct DisplayInfo: Identifiable, Hashable, Sendable {
    public var id: UInt32  // CGDirectDisplayID
    public var name: String
    public var width: Int
    public var height: Int
    public var isMain: Bool

    public init(id: UInt32, name: String, width: Int, height: Int, isMain: Bool) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
        self.isMain = isMain
    }
}

public struct WindowInfo: Identifiable, Hashable, Sendable {
    public var id: UInt32  // CGWindowID
    public var app: String
    public var title: String
    public var width: Int
    public var height: Int

    public init(id: UInt32, app: String, title: String, width: Int, height: Int) {
        self.id = id
        self.app = app
        self.title = title
        self.width = width
        self.height = height
    }
}

/// Finds a device from a free-text query (what a user or model says):
/// exact ID, exact name, then case-insensitive substring of the name, then
/// every query word in the name.
public enum DeviceMatcher {
    public static func match<T>(_ query: String, in items: [T], id: (T) -> String, name: (T) -> String) -> T? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        let lower = q.lowercased()
        if let exact = items.first(where: { id($0) == q }) { return exact }
        if let exact = items.first(where: { name($0).lowercased() == lower }) { return exact }
        if let sub = items.first(where: { name($0).lowercased().contains(lower) }) { return sub }
        let words = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { !["my", "the", "a", "mic", "microphone", "camera", "use"].contains($0) }
        guard !words.isEmpty else { return nil }
        return items.first { item in words.allSatisfy { name(item).lowercased().contains($0) } }
    }
}

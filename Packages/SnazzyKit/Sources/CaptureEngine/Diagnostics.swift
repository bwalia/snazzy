import Foundation
import Observation
import SnazzyCore

/// Device events, stalls, dropped frames and sync offsets, for the Diagnostics
/// panel. Everything is also sent to the unified log.
@MainActor @Observable
public final class Diagnostics {
    public struct Entry: Identifiable, Hashable, Sendable {
        public enum Level: String, Sendable { case info, warning, error }
        public let id = UUID()
        public let date: Date
        public let level: Level
        public let category: String
        public let message: String
    }

    public static let shared = Diagnostics()
    public private(set) var entries: [Entry] = []
    private let limit = 1000

    public init() {}

    public func log(_ message: String, category: String = "device", level: Entry.Level = .info) {
        entries.append(Entry(date: Date(), level: level, category: category, message: message))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        switch level {
        case .info: Log.capture.info("[\(category, privacy: .public)] \(message, privacy: .public)")
        case .warning: Log.capture.notice("[\(category, privacy: .public)] \(message, privacy: .public)")
        case .error: Log.capture.error("[\(category, privacy: .public)] \(message, privacy: .public)")
        }
    }

    public func clear() { entries.removeAll() }
}

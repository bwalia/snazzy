import Foundation

/// Between the iPhone app and the Apple Watch app (WatchConnectivity). The
/// watch has no link to the Mac: the iPhone relays its commands to the Mac and
/// the Mac's status back. Values are JSON in property-list dictionaries.
public enum WatchLink {
    /// iPhone → watch: a `WatchState`.
    public static let stateKey = "state"
    /// Watch → iPhone: a `RemoteCommand`. The reply has `okKey` and maybe `messageKey`.
    public static let commandKey = "command"
    /// Watch → iPhone: "send me the current state" (the reply has `stateKey`).
    public static let helloKey = "hello"
    public static let okKey = "ok"
    public static let messageKey = "message"

    /// Commands the watch may send (not chat: its replies have nowhere to go).
    public static func allows(_ command: RemoteCommand) -> Bool {
        switch command {
        case .startRecording, .pauseRecording, .resumeRecording, .stopRecording, .nextSlide, .previousSlide, .goToSlide, .prompter, .ping:
            true
        case .openPresentWindow, .chat:
            false
        }
    }

    public static func encode<T: Encodable>(_ value: T) -> Data? { try? JSONEncoder().encode(value) }

    public static func decode<T: Decodable>(_ type: T.Type, _ value: Any?) -> T? {
        guard let data = value as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// What the watch shows.
public struct WatchState: Codable, Sendable, Equatable {
    /// Why there's no status, e.g. "Connecting to Studio…" (nil when connected).
    public var problem: String?
    /// The Mac's status, trimmed for the watch (no notes, mic level or teleprompter position).
    public var status: RemoteStatus?
    /// When `status.elapsed` was measured, so the watch can keep the timer running.
    public var sentAt: Date

    public init(problem: String?, status: RemoteStatus?, sentAt: Date = Date()) {
        self.problem = problem
        self.status = status.map(Self.trim)
        self.sentAt = sentAt
    }

    static func trim(_ s: RemoteStatus) -> RemoteStatus {
        var s = s
        s.notes = nil
        s.micLevel = 0
        // The watch shows play/pause, not the scrolling position (which
        // changes all the time and would flood the watch).
        s.prompter?.progress = 0
        s.prompter?.script = nil
        return s
    }

    /// Same apart from the timer, which the watch keeps running itself.
    public func matches(_ other: WatchState) -> Bool {
        var a = self, b = other
        a.sentAt = .distantPast
        b.sentAt = .distantPast
        a.status?.elapsed = 0
        b.status?.elapsed = 0
        return a == b
    }

    /// Recording time now: counts on from `sentAt` while recording.
    public func elapsed(at now: Date = Date()) -> Double {
        guard let s = status else { return 0 }
        return s.recording == "recording" ? s.elapsed + max(0, now.timeIntervalSince(sentAt)) : s.elapsed
    }
}

import os

/// Central place for `os.Logger` instances. Never log secrets (API keys,
/// Authorization headers) — log provider names and status codes only.
public enum Log {
    public static let subsystem = "com.snazzy.pro"

    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let settings = Logger(subsystem: subsystem, category: "settings")
    public static let keychain = Logger(subsystem: subsystem, category: "keychain")
    public static let assistant = Logger(subsystem: subsystem, category: "assistant")
    public static let provider = Logger(subsystem: subsystem, category: "provider")
    public static let capture = Logger(subsystem: subsystem, category: "capture")
}

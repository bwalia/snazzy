import Foundation

/// A `.snazzy_interview` file: one interview's results (kit snapshot, transcript,
/// flags, evaluation, decision), as JSON. Saved when no OpsAPI is connected, and
/// uploadable to OpsAPI later. Never contains the link token or self-ID answers.
public enum InterviewFile {
    public static let fileExtension = "snazzy_interview"
    public static let format = "snazzy-interview"
    public static let version = 1
    public static let maxSize = 1_000_000

    struct Wrapper: Codable {
        var format: String
        var version: Int
        var exportedAt: Date
        var app: String
        var interview: InterviewSession
    }

    public static func encode(_ session: InterviewSession, app: String, now: Date = Date()) throws -> Data {
        var copy = session
        copy.linkTokenHash = nil
        copy.selfIDKey = nil
        // Local file paths stay on this Mac (the recording isn't in the file).
        copy.recordingFiles = []
        return try InterviewJSON.encoder.encode(Wrapper(format: format, version: version, exportedAt: now, app: app, interview: copy))
    }

    public static func decode(_ data: Data) throws -> InterviewSession {
        guard data.count <= maxSize else { throw InterviewFileError("The file is too large to be interview results.") }
        guard let w = try? InterviewJSON.decoder.decode(Wrapper.self, from: data), w.format == format else {
            throw InterviewFileError("This isn't a Snazzy Interview results file.")
        }
        guard w.version <= version else {
            throw InterviewFileError("This file was made by a newer Snazzy Pro. Update to open it.")
        }
        return w.interview
    }

    /// "2026-10-14 Sam Taylor - Customer Support Team Lead.snazzy_interview", safe for any file system.
    public static func fileName(for s: InterviewSession) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmm"
        let name = s.candidate.name.isEmpty ? "Candidate" : s.candidate.name
        let raw = "\(f.string(from: s.startedAt ?? s.created)) \(name) - \(s.kit.title)"
        let safe = raw.map { "/\\:*?\"<>|".contains($0) || $0.isNewline ? "-" : $0 }
        return String(String(safe).prefix(150)) + "." + fileExtension
    }
}

public struct InterviewFileError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Snazzy Pro ↔ OpsAPI's interview management: send results, fetch kits. Uses
/// an integration token (`snz_…`) made in the OpsAPI dashboard.
public struct OpsAPILink: Sendable {
    public var baseURL: URL
    public var token: String
    var session: URLSession

    public init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    public struct Ping: Decodable, Sendable {
        public var namespace: String?
        public var active: Bool?
    }

    public struct Uploaded: Decodable, Sendable {
        public var interviewUuid: String?
        public var applicationUuid: String?
        public var dashboardUrl: String?
    }

    struct Envelope<T: Decodable>: Decodable {
        var success: Bool?
        var data: T?
        var error: String?
        var message: String?
    }

    func request(_ path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var r = URLRequest(url: baseURL.appendingPathComponent("api/v2/public/ats/integration").appendingPathComponent(path))
        r.httpMethod = method
        r.timeoutInterval = 30
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    func call<T: Decodable>(_ r: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: r)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let env = try? InterviewJSON.decoder.decode(Envelope<T>.self, from: data)
        guard (200..<300).contains(status), let value = env?.data else {
            let why = env?.error ?? env?.message ?? HTTPURLResponse.localizedString(forStatusCode: status)
            switch status {
            case 401, 403: throw InterviewFileError("OpsAPI didn't accept the integration token. Make a new one in the dashboard (Interviews › Settings).")
            case 402: throw InterviewFileError("Interviews aren't active for this OpsAPI workspace: \(why)")
            default: throw InterviewFileError("OpsAPI: \(why) (\(status))")
            }
        }
        return value
    }

    public func ping() async throws -> Ping { try await call(request("ping")) }

    /// Sends one interview's results (the same JSON as a `.snazzy_interview` file).
    public func upload(_ session: InterviewSession, app: String) async throws -> Uploaded {
        try await call(request("interviews", method: "POST", body: InterviewFile.encode(session, app: app)))
    }

    /// Approved kits made in the dashboard.
    public func kits() async throws -> [RoleKit] { try await call(request("kits")) }
}

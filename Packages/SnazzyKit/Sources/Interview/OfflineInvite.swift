import Foundation

/// An interview by invite link that the candidate takes offline, at their own
/// Mac: OpsAPI sends the kit (without rating anchors) and the notice once, this
/// Mac runs the interview with a model that runs here (or none: the questions
/// are fixed), and the transcript goes back once at the end. OpsAPI evaluates
/// it; nothing the candidate's Mac says about scores or decisions is sent or kept.
///
/// The invite token itself is kept in the Keychain (`keychainAccount`), never here.
public struct OfflineInvite: Codable, Hashable, Sendable {
    /// OpsAPI's API address.
    public var api: URL
    /// The notice OpsAPI wrote for this interview, shown to the candidate as is.
    public var notice: String
    public var noticeHash: String
    /// The last moment OpsAPI accepts the results.
    public var uploadBy: Date?
    /// The interview's id at OpsAPI.
    public var interviewUUID: String?
    public var uploadedAt: Date?
    /// Why the last attempt to send the results failed (they're tried again).
    public var lastError: String?

    public init(api: URL, notice: String, noticeHash: String, uploadBy: Date?, interviewUUID: String?) {
        self.api = api
        self.notice = notice
        self.noticeHash = noticeHash
        self.uploadBy = uploadBy
        self.interviewUUID = interviewUUID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        api = try c.decode(URL.self, forKey: .api)
        notice = try c.decodeIfPresent(String.self, forKey: .notice) ?? ""
        noticeHash = try c.decodeIfPresent(String.self, forKey: .noticeHash) ?? ""
        uploadBy = try c.decodeIfPresent(Date.self, forKey: .uploadBy)
        interviewUUID = try c.decodeIfPresent(String.self, forKey: .interviewUUID)
        uploadedAt = try c.decodeIfPresent(Date.self, forKey: .uploadedAt)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
    }

    enum CodingKeys: String, CodingKey {
        case api, notice, noticeHash, uploadBy, interviewUUID = "interviewUuid", uploadedAt, lastError
    }

    /// The Keychain account holding the invite token for an interview.
    public static func keychainAccount(for session: UUID) -> String { "interview.invite.\(session.uuidString)" }

    public var isSent: Bool { uploadedAt != nil }

    /// Still waiting to be sent, and OpsAPI would still take it.
    public func isPending(now: Date = Date()) -> Bool {
        uploadedAt == nil && (uploadBy.map { $0 > now } ?? true)
    }
}

/// What OpsAPI sends when an offline interview is first opened on a device.
public struct OfflineStart: Decodable, Sendable {
    public struct Who: Decodable, Sendable {
        public var name: String
    }

    public var kit: RoleKit
    public var notice: String
    public var noticeHash: String
    public var candidate: Who?
    public var pack: InviteClient.Pack?
    public var uploadBy: Date?
    public var interviewUuid: String?

    enum CodingKeys: String, CodingKey { case kit, notice, noticeHash, candidate, pack, uploadBy, interviewUuid }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kit = try c.decode(RoleKit.self, forKey: .kit)
        notice = try c.decode(String.self, forKey: .notice)
        noticeHash = try c.decode(String.self, forKey: .noticeHash)
        candidate = try c.decodeIfPresent(Who.self, forKey: .candidate)
        pack = try c.decodeIfPresent(InviteClient.Pack.self, forKey: .pack)
        uploadBy = c.looseDate(.uploadBy)
        interviewUuid = try c.decodeIfPresent(String.self, forKey: .interviewUuid)
    }
}

extension KeyedDecodingContainer {
    /// A date OpsAPI wrote as ISO 8601 (with or without fractions) or as Postgres prints it
    /// ("2026-10-18 20:00:00.123456+00"); nil if missing or unreadable.
    func looseDate(_ key: Key) -> Date? {
        if let d = try? decodeIfPresent(Date.self, forKey: key) { return d }
        guard let text = try? decodeIfPresent(String.self, forKey: key) else { return nil }
        return LooseDate.parse(text)
    }
}

enum LooseDate {
    static func parse(_ text: String) -> Date? {
        var t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "T")
        // "+00" → "+00:00"
        if let r = t.range(of: #"[+-]\d{2}$"#, options: .regularExpression) { t.replaceSubrange(r, with: t[r] + ":00") }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: t) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: t)
    }
}

extension InviteClient {
    /// Opens an offline interview on this device (the first device keeps it): the
    /// kit, the notice and, if the recruiter made one, the encrypted pack.
    public func offline(deviceID: String) async throws -> OfflineStart {
        try await call(request("offline", body: ["device_id": deviceID]))
    }

    /// The body sent with the results: the `.snazzy_interview` file, without the
    /// evaluation or any review (OpsAPI evaluates, and a person decides).
    public static func resultBody(_ session: InterviewSession, deviceID: String, app: String, now: Date = Date()) throws -> Data {
        var copy = session
        copy.evaluation = nil
        copy.review = nil
        let file = try JSONSerialization.jsonObject(with: InterviewFile.encode(copy, app: app, now: now))
        return try JSONSerialization.data(withJSONObject: ["device_id": deviceID, "interview": file])
    }

    /// Sends a finished offline interview's results, once.
    public func submit(_ session: InterviewSession, deviceID: String, app: String) async throws -> CandidateView {
        var r = try request("result", body: [:])
        r.httpBody = try Self.resultBody(session, deviceID: deviceID, app: app)
        return try await call(r)
    }
}

// MARK: - The recruiter's side: results and accounts

extension OpsAPILink {
    /// One interview in OpsAPI's list (any delivery).
    public struct RemoteInterview: Decodable, Sendable, Identifiable {
        public struct Who: Decodable, Sendable {
            public var name: String?
            public var email: String?
        }

        public var uuid: String
        public var candidate: Who?
        public var jobTitle: String?
        public var kitTitle: String?
        public var state: String
        public var delivery: String?
        public var evaluationStatus: String?
        public var decision: String?
        public var startedAt: Date?
        public var endedAt: Date?
        public var updatedAt: Date?
        public var resultUploadedAt: Date?
        public var dashboardUrl: String?
        public var id: String { uuid }

        enum CodingKeys: String, CodingKey {
            case uuid, candidate, jobTitle, kitTitle, state, delivery, evaluationStatus, decision, startedAt, endedAt,
                 updatedAt, resultUploadedAt, dashboardUrl
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            uuid = try c.decode(String.self, forKey: .uuid)
            candidate = try? c.decodeIfPresent(Who.self, forKey: .candidate)
            jobTitle = try? c.decodeIfPresent(String.self, forKey: .jobTitle)
            kitTitle = try? c.decodeIfPresent(String.self, forKey: .kitTitle)
            state = (try? c.decodeIfPresent(String.self, forKey: .state)) ?? "invited"
            delivery = try? c.decodeIfPresent(String.self, forKey: .delivery)
            evaluationStatus = try? c.decodeIfPresent(String.self, forKey: .evaluationStatus)
            decision = try? c.decodeIfPresent(String.self, forKey: .decision)
            startedAt = c.looseDate(.startedAt)
            endedAt = c.looseDate(.endedAt)
            updatedAt = c.looseDate(.updatedAt)
            resultUploadedAt = c.looseDate(.resultUploadedAt)
            dashboardUrl = try? c.decodeIfPresent(String.self, forKey: .dashboardUrl)
        }

        public var isFinished: Bool { !["invited", "in_progress", "paused"].contains(state) }
    }

    struct RemoteFile: Decodable {
        struct Wrapper: Decodable {
            var format: String
            var version: Int
            var interview: InterviewSession
        }
        var uuid: String
        var file: Wrapper
    }

    func request(_ path: String, query: [String: String]) -> URLRequest {
        var r = request(path)
        if var c = r.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }), !query.isEmpty {
            c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            r.url = c.url
        }
        return r
    }

    /// Interviews in this OpsAPI workspace, newest first (`since`: changed after then).
    public func interviews(since: Date? = nil, page: Int = 1, perPage: Int = 100) async throws -> [RemoteInterview] {
        var query = ["page": String(page), "per_page": String(perPage)]
        if let since { query["since"] = ISO8601DateFormatter().string(from: since) }
        return try await call(request("interviews", query: query))
    }

    /// One interview's full results (transcript, OpsAPI's evaluation, any review), as the app keeps them.
    public func interview(_ uuid: String) async throws -> InterviewSession {
        let remote: RemoteFile = try await call(request("interviews/\(uuid)"))
        guard remote.file.format == InterviewFile.format else { throw InterviewFileError("OpsAPI sent results in a format this app doesn't know.") }
        guard remote.file.version <= InterviewFile.version else {
            throw InterviewFileError("These results need a newer Snazzy Pro. Update to fetch them.")
        }
        return remote.file.interview
    }
}

/// A recruiter's OpsAPI account, made or signed into from Snazzy Pro. Either way
/// the app gets an integration token (`snz_…`) for one Hiring workspace, kept in
/// the Keychain; the password is sent once, over https, and never kept.
public enum RecruiterAccount {
    public struct Workspace: Decodable, Sendable, Hashable, Identifiable {
        public var uuid: String
        public var name: String
        public var id: String { uuid }
    }

    public struct Linked: Decodable, Sendable {
        public var token: String
        public var namespace: Workspace
        public var active: Bool?
        public var dashboardUrl: String?
    }

    /// Signing in: the token, or the workspaces to choose from when there are several.
    public enum SignIn: Sendable {
        case linked(Linked)
        case choose([Workspace])
    }

    struct SignInReply: Decodable {
        var token: String?
        var namespace: Workspace?
        var active: Bool?
        var dashboardUrl: String?
        var choose: [Workspace]?
    }

    struct Envelope<T: Decodable>: Decodable {
        var data: T?
        var error: String?
        var code: String?
    }

    public struct Problem: LocalizedError, Equatable {
        public var message: String
        /// OpsAPI's error code, e.g. "email_taken", "mfa_required", "no_workspace".
        public var code: String?
        public var errorDescription: String? { message }
    }

    /// Only https leaves this Mac (http only to this Mac, for testing).
    public static func checkedBase(_ text: String) throws -> URL {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard let base = URL(string: text), let scheme = base.scheme, let host = base.host(), !host.isEmpty else {
            throw Problem(message: "That isn't a web address.")
        }
        guard scheme == "https" || ["localhost", "127.0.0.1"].contains(host) else {
            throw Problem(message: "Use an https address, so your password and candidates' answers are encrypted on the way.")
        }
        return base
    }

    static func request(_ base: URL, _ action: String, body: [String: String]) throws -> URLRequest {
        var r = URLRequest(url: base.appendingPathComponent("api/v2/public/ats/recruiters").appendingPathComponent(action))
        r.httpMethod = "POST"
        r.timeoutInterval = 30
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body.filter { !$0.value.isEmpty })
        return r
    }

    static func call<T: Decodable>(_ r: URLRequest, session: URLSession) async throws -> T {
        let (data, response) = try await session.data(for: r)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let env = try? InterviewJSON.decoder.decode(Envelope<T>.self, from: data)
        if (200..<300).contains(status), let value = env?.data { return value }
        if let why = env?.error { throw Problem(message: why, code: env?.code) }
        switch status {
        case 404: throw Problem(message: "That OpsAPI doesn't offer Hiring accounts. Check the address.")
        case 429: throw Problem(message: "Too many attempts. Please wait a while and try again.")
        default: throw Problem(message: "OpsAPI didn't answer (\(status)). Please try again.")
        }
    }

    /// Makes a recruiter account and a Hiring workspace for the company.
    public static func register(at base: URL, company: String, firstName: String, lastName: String, email: String,
                                password: String, deviceName: String, session: URLSession = .shared) async throws -> Linked {
        let company = company.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !company.isEmpty else { throw Problem(message: "Enter your company's name.") }
        guard !firstName.trimmingCharacters(in: .whitespaces).isEmpty, !lastName.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw Problem(message: "Enter your first and last name.")
        }
        guard email.contains("@"), email.contains(".") else { throw Problem(message: "Enter your work email address.") }
        guard password.count >= 8 else { throw Problem(message: "Choose a password of at least 8 characters.") }
        let r = try request(base, "register", body: [
            "company": company, "first_name": firstName.trimmingCharacters(in: .whitespaces),
            "last_name": lastName.trimmingCharacters(in: .whitespaces), "email": email, "password": password,
            "device_name": deviceName,
        ])
        let linked: Linked = try await call(r, session: session)
        guard linked.token.hasPrefix("snz_") else { throw Problem(message: "OpsAPI sent an unusable token.") }
        return linked
    }

    /// Signs into an existing account, for one of its Hiring workspaces.
    public static func signIn(at base: URL, email: String, password: String, workspace: String? = nil,
                              deviceName: String, session: URLSession = .shared) async throws -> SignIn {
        let r = try request(base, "sign-in", body: [
            "email": email.trimmingCharacters(in: .whitespacesAndNewlines), "password": password,
            "namespace_uuid": workspace ?? "", "device_name": deviceName,
        ])
        let reply: SignInReply = try await call(r, session: session)
        if let token = reply.token, token.hasPrefix("snz_"), let ns = reply.namespace {
            return .linked(Linked(token: token, namespace: ns, active: reply.active, dashboardUrl: reply.dashboardUrl))
        }
        if let choose = reply.choose, !choose.isEmpty { return .choose(choose) }
        throw Problem(message: "OpsAPI didn't send a token.")
    }
}

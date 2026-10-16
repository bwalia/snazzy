import Foundation

/// An interview invite from OpsAPI, as the candidate receives it: the web link
/// (`https://…/i/<token>`) or the app link
/// (`snazzypro://interview?link=<web link>&api=<OpsAPI address>`).
public struct InviteLink: Equatable, Sendable {
    public var token: String
    /// OpsAPI's API address (from the app link; for a web link, the link's own host).
    public var api: URL

    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return nil }
        var web = url
        var api: URL?
        if scheme == "snazzypro" {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard url.host() == "interview", let link = items.first(where: { $0.name == "link" })?.value,
                  let linkURL = URL(string: link) else { return nil }
            web = linkURL
            api = items.first(where: { $0.name == "api" })?.value.flatMap(URL.init(string:))
        }
        guard let webScheme = web.scheme?.lowercased(), ["https", "http"].contains(webScheme) else { return nil }
        // OpsAPI puts its API address on the web link too (?api=), for links pasted into the app.
        if api == nil {
            api = URLComponents(url: web, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "api" })?.value.flatMap(URL.init(string:))
        }
        let parts = web.pathComponents
        guard let i = parts.lastIndex(of: "i"), i + 1 < parts.count else { return nil }
        let token = parts[i + 1]
        guard token.count >= 20, token.count <= 100,
              token.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        var root = URLComponents()
        root.scheme = web.scheme
        root.host = web.host()
        root.port = web.port
        guard let base = api ?? root.url else { return nil }
        // Answers travel encrypted: https, except on this Mac (testing).
        guard base.scheme == "https" || ["localhost", "127.0.0.1"].contains(base.host() ?? "") else { return nil }
        self.token = token
        self.api = base
    }
}

/// What the candidate sees of an interview OpsAPI runs (no evaluation, no flags).
public struct CandidateView: Codable, Sendable, Equatable {
    public struct Turn: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var role: String
        public var text: String
        public var kind: String?
        public var questionId: String?
    }

    public struct SelfIDQuestion: Codable, Sendable, Equatable {
        public var id: String
        public var label: String
        public var options: [String]
    }

    public var state: String
    public var roleTitle: String
    public var organisation: String?
    public var interviewerName: String?
    public var minutes: Int?
    public var allowPause: Bool?
    public var allowedAdjustments: [String]?
    public var notice: String
    public var noticeHash: String
    public var nextSteps: String?
    public var turns: [Turn]
    public var choices: [String]?
    public var progress: Double?
    public var secondsLeft: Int?
    public var questionCount: Int?
    public var selfId: [SelfIDQuestion]?
    public var hasPack: Bool?

    public var isFinished: Bool { !["invited", "in_progress", "paused"].contains(state) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decode(String.self, forKey: .state)
        roleTitle = try c.decodeIfPresent(String.self, forKey: .roleTitle) ?? ""
        organisation = try c.decodeIfPresent(String.self, forKey: .organisation)
        interviewerName = try c.decodeIfPresent(String.self, forKey: .interviewerName)
        minutes = try c.decodeIfPresent(Int.self, forKey: .minutes)
        allowPause = try c.decodeIfPresent(Bool.self, forKey: .allowPause)
        allowedAdjustments = try c.decodeIfPresent([String].self, forKey: .allowedAdjustments)
        notice = try c.decodeIfPresent(String.self, forKey: .notice) ?? ""
        noticeHash = try c.decodeIfPresent(String.self, forKey: .noticeHash) ?? ""
        nextSteps = try c.decodeIfPresent(String.self, forKey: .nextSteps)
        turns = (try? c.decodeIfPresent([Turn].self, forKey: .turns)) ?? []
        choices = try? c.decodeIfPresent([String].self, forKey: .choices)
        progress = try? c.decodeIfPresent(Double.self, forKey: .progress)
        secondsLeft = (try? c.decodeIfPresent(Double.self, forKey: .secondsLeft)).map { Int($0) }
        questionCount = try c.decodeIfPresent(Int.self, forKey: .questionCount)
        selfId = try? c.decodeIfPresent([SelfIDQuestion].self, forKey: .selfId)
        hasPack = try c.decodeIfPresent(Bool.self, forKey: .hasPack)
    }

    /// The interview deck's slide for where the interview is (AutoInterview.deck layout:
    /// title, how it works, [eligibility], one per question, your questions, thank you).
    public func slideIndex(for kit: RoleKit) -> Int {
        let firstQuestion = 2 + (kit.eligibility.isEmpty ? 0 : 1)
        if state == "invited" { return 0 }
        if isFinished { return firstQuestion + kit.questions.count + 1 }
        for t in turns.reversed() where t.role == "interviewer" {
            switch t.kind {
            case "eligibility": return 2
            case "closing": return firstQuestion + kit.questions.count + 1
            case "answer": return firstQuestion + kit.questions.count
            case "opening": return 1
            default:
                if let q = t.questionId, let i = kit.questions.firstIndex(where: { $0.id == q }) { return firstQuestion + i }
                if let q = t.questionId, kit.eligibility.contains(where: { $0.id == q }) { return 2 }
                if t.text.contains("questions for me") || t.text.contains("other questions") { return firstQuestion + kit.questions.count }
            }
        }
        return 1
    }
}

/// The candidate's app talking to OpsAPI with an invite link (no account, no passcode).
public struct InviteClient: Sendable {
    public var link: InviteLink
    var session: URLSession

    public init(link: InviteLink, session: URLSession = .shared) {
        self.link = link
        self.session = session
    }

    public struct Pack: Decodable, Sendable {
        public var url: String
        public var key: String
        public var sha256: String
        public var sizeBytes: Int64?
        public var title: String?
    }

    struct Envelope<T: Decodable>: Decodable {
        var data: T?
        var error: String?
    }

    func request(_ action: String?, body: [String: Any]?) throws -> URLRequest {
        var url = link.api.appendingPathComponent("api/v2/public/ats/interviews").appendingPathComponent(link.token)
        if let action { url = url.appendingPathComponent(action) }
        var r = URLRequest(url: url)
        r.timeoutInterval = 120  // the interviewer model answers within this
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            r.httpMethod = "POST"
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    func call<T: Decodable>(_ r: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: r)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let env = try? InterviewJSON.decoder.decode(Envelope<T>.self, from: data)
        guard (200..<300).contains(status), let value = env?.data else {
            if let why = env?.error { throw InterviewFileError(why) }
            switch status {
            case 404: throw InterviewFileError("This interview link isn't valid.")
            case 410: throw InterviewFileError("This interview link has expired. Please contact the hiring team.")
            case 429: throw InterviewFileError("Too many requests. Please wait a moment and try again.")
            default: throw InterviewFileError("The interview service didn't answer (\(status)). Please try again.")
            }
        }
        return value
    }

    public func view() async throws -> CandidateView { try await call(request(nil, body: nil)) }

    public func start(noticeHash: String, adjustments: [String]) async throws -> CandidateView {
        try await call(request("start", body: ["notice_hash": noticeHash, "adjustments": adjustments]))
    }

    public func answer(_ text: String, input: String) async throws -> CandidateView {
        try await call(request("answer", body: ["text": text, "input": input]))
    }

    /// repeat | rephrase | pause | resume | person | withdraw | adjustment
    public func event(_ type: String, text: String? = nil) async throws -> CandidateView {
        var body: [String: Any] = ["type": type]
        if let text { body["text"] = text }
        return try await call(request("event", body: body))
    }

    public func selfID(_ answers: [String: String]) async throws -> CandidateView {
        try await call(request("self-id", body: ["answers": answers]))
    }

    /// Redeems the invite for its pack. The first device to do this keeps the invite.
    public func pack(deviceID: String) async throws -> Pack {
        try await call(request("pack", body: ["device_id": deviceID]))
    }
}

// MARK: - The recruiter's side: packs and bulk invites

extension OpsAPILink {
    public struct PackUpload: Decodable, Sendable {
        public var uuid: String
        public var uploadUrl: String?
        public var status: String?
    }

    public struct InviteResults: Decodable, Sendable {
        public struct Item: Decodable, Sendable, Identifiable {
            public var name: String?
            public var email: String?
            public var uuid: String?
            public var url: String?
            public var appUrl: String?
            public var error: String?
            public var id: String { uuid ?? (name ?? "") + (email ?? "") + (error ?? "") }
        }
        public var invited: Int
        public var failed: Int
        public var results: [Item]
    }

    /// One candidate to invite.
    public struct Invitee: Equatable, Sendable {
        public var name: String
        public var email: String
        public init(name: String, email: String) {
            self.name = name
            self.email = email
        }

        /// One per line: "Name, email" (or tab-separated, or "Name <email>", or just an email).
        public static func parse(_ text: String) -> [Invitee] {
            text.split(whereSeparator: \.isNewline).compactMap { raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.lowercased().hasPrefix("name,") else { return nil }
                if let lt = line.firstIndex(of: "<"), let gt = line.lastIndex(of: ">"), lt < gt {
                    return Invitee(name: line[..<lt].trimmingCharacters(in: .whitespaces.union(.init(charactersIn: "\""))),
                                   email: String(line[line.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces))
                }
                let parts = line.split(whereSeparator: { $0 == "," || $0 == "\t" || $0 == ";" }).map {
                    $0.trimmingCharacters(in: .whitespaces.union(.init(charactersIn: "\"")))
                }
                let email = parts.first { $0.contains("@") } ?? ""
                let name = parts.first { !$0.contains("@") && !$0.isEmpty } ?? (email.split(separator: "@").first.map(String.init) ?? "")
                return name.isEmpty ? nil : Invitee(name: name, email: email)
            }
        }
    }

    /// Starts a pack: OpsAPI returns a signed S3 link to upload the encrypted file to.
    public func createPack(_ sealed: InterviewPack.Sealed, title: String) async throws -> PackUpload {
        let body = try JSONSerialization.data(withJSONObject: [
            "title": title, "size_bytes": sealed.size, "sha256": sealed.sha256, "key": sealed.keyBase64,
        ] as [String: Any])
        return try await call(request("packs", method: "POST", body: body))
    }

    /// Uploads the encrypted file to S3 with the signed link (never to OpsAPI itself).
    public func uploadPack(_ sealed: InterviewPack.Sealed, to link: String, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard let url = URL(string: link) else { throw InterviewFileError("OpsAPI sent an unusable upload link.") }
        var r = URLRequest(url: url)
        r.httpMethod = "PUT"
        r.timeoutInterval = 3600
        let delegate = UploadProgress(progress)
        let (_, response) = try await session.upload(for: r, fromFile: sealed.file, delegate: delegate)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw InterviewFileError("The pack upload failed (\(status)). Please try again.") }
    }

    public func completePack(_ uuid: String) async throws -> PackUpload {
        try await call(request("packs/\(uuid)/complete", method: "POST", body: Data("{}".utf8)))
    }

    /// Invites many candidates at once to an approved kit (and pack): each gets their own link.
    public func invite(kit: RoleKit, packUUID: String?, invitees: [Invitee], days: Int) async throws -> InviteResults {
        var body: [String: Any] = [
            "kit": try JSONSerialization.jsonObject(with: InterviewJSON.encoder.encode(kit)),
            "candidates": invitees.map { ["name": $0.name, "email": $0.email] },
            "expires_in_days": days,
        ]
        if let packUUID { body["pack_uuid"] = packUUID }
        var r = request("invites", method: "POST", body: try JSONSerialization.data(withJSONObject: body))
        r.timeoutInterval = 300
        return try await call(r)
    }
}

final class UploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    let report: (@Sendable (Double) -> Void)?
    init(_ report: (@Sendable (Double) -> Void)?) { self.report = report }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        report?(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}

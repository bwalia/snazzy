import Foundation
import Testing
@testable import Interview

/// Answers requests from a table of handlers, one per host, so suites can run in parallel.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Data) -> (Int, Data)
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    private static let lock = NSLock()

    static func session(host: String, _ handler: @escaping Handler) -> URLSession {
        lock.withLock { handlers[host] = handler }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host() ?? ""
        guard let handler = Self.lock.withLock({ Self.handlers[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        let (status, data) = handler(request, body)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }
func object(_ data: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }

@Suite struct OfflineInviteTests {
    func approvedKit() throws -> RoleKit {
        var kit = try sampleKit()
        kit.approvedAt = Date(timeIntervalSince1970: 1_792_000_000)
        kit.approvedBy = "Recruiter"
        return kit
    }

    @Test func theCandidatesKitHasNoRatingAnchors() throws {
        let kit = try approvedKit()
        #expect(kit.competencies.contains { !$0.anchors.level3.isEmpty })
        let safe = kit.forCandidate
        #expect(safe.competencies.allSatisfy { $0.anchors == Competency.Anchors() })
        #expect(safe.questions == kit.questions)
        #expect(safe.competencies.map(\.name) == kit.competencies.map(\.name))
        #expect(safe.competencies.map(\.weight) == kit.competencies.map(\.weight))
    }

    @Test func opensAnOfflineInterview() async throws {
        let kit = try approvedKit().forCandidate
        let kitData = try InterviewJSON.encoder.encode(kit)
        let session = StubProtocol.session(host: "offline.test") { r, body in
            #expect(r.httpMethod == "POST")
            #expect(r.url?.path == "/api/v2/public/ats/interviews/\(String(repeating: "t", count: 32))/offline")
            #expect(object(body)["device_id"] as? String == "device-1234567890abcdef")
            return (200, json(["success": true, "data": [
                "kit": try! JSONSerialization.jsonObject(with: kitData), "notice": "Offline notice", "notice_hash": "abc123",
                "candidate": ["name": "Sam Taylor"], "pack": NSNull(),
                "upload_by": "2026-10-25 20:00:00.5+00", "interview_uuid": "ivw-1",
            ]]))
        }
        let client = InviteClient(link: InviteLink(token: String(repeating: "t", count: 32), api: URL(string: "https://offline.test")!), session: session)
        let start = try await client.offline(deviceID: "device-1234567890abcdef")
        #expect(start.kit == kit)
        #expect(start.notice == "Offline notice")
        #expect(start.noticeHash == "abc123")
        #expect(start.candidate?.name == "Sam Taylor")
        #expect(start.pack == nil)
        #expect(start.interviewUuid == "ivw-1")
        #expect(start.uploadBy == Date(timeIntervalSince1970: 1_792_958_400.5))
    }

    @Test func resultsGoWithoutEvaluationReviewOrSecrets() throws {
        var s = InterviewSession(kit: try approvedKit(), candidate: Candidate(name: "Sam Taylor", email: "sam@example.com"), channel: .thisMac)
        s.state = .completed
        s.linkTokenHash = "secret-hash"
        s.selfIDKey = "self-id"
        s.recordingFiles = ["/Users/sam/Movies/x.mov"]
        s.review = Review(reviewer: "Me", decision: .advance)
        s.offline = OfflineInvite(api: URL(string: "https://api.example.com")!, notice: "n", noticeHash: "h", uploadBy: nil, interviewUUID: "u")
        let body = object(try InviteClient.resultBody(s, deviceID: "device-1", app: "Snazzy Pro 1.0"))
        #expect(body["device_id"] as? String == "device-1")
        let file = body["interview"] as? [String: Any] ?? [:]
        #expect(file["format"] as? String == "snazzy-interview")
        let inner = file["interview"] as? [String: Any] ?? [:]
        #expect(inner["state"] as? String == "completed")
        for key in ["evaluation", "review", "link_token_hash", "self_id_key", "offline"] { #expect(inner[key] == nil, "\(key)") }
        #expect((inner["recording_files"] as? [Any])?.isEmpty == true)
        // The same body decodes as a results file.
        let data = try JSONSerialization.data(withJSONObject: file)
        #expect(try InterviewFile.decode(data).id == s.id)
    }

    @Test func sendsResultsAndReadsTheReply() async throws {
        var s = InterviewSession(kit: try approvedKit(), candidate: Candidate(name: "Sam"), channel: .thisMac)
        s.state = .completed
        let session = StubProtocol.session(host: "result.test") { r, body in
            #expect(r.url?.lastPathComponent == "result")
            #expect(r.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect((object(body)["interview"] as? [String: Any])?["format"] as? String == "snazzy-interview")
            return (200, json(["success": true, "data": ["state": "completed", "role_title": "Lead", "delivery": "offline", "turns": []]]))
        }
        let client = InviteClient(link: InviteLink(token: String(repeating: "r", count: 32), api: URL(string: "https://result.test")!), session: session)
        let v = try await client.submit(s, deviceID: "device-1", app: "test")
        #expect(v.isOffline)
        #expect(v.isFinished)
    }

    @Test func alreadySentSaysSo() async throws {
        let session = StubProtocol.session(host: "sent.test") { _, _ in
            (409, json(["success": false, "error": "This interview's results were already sent.", "code": "already_sent"]))
        }
        let client = InviteClient(link: InviteLink(token: String(repeating: "s", count: 32), api: URL(string: "https://sent.test")!), session: session)
        let s = InterviewSession(kit: try approvedKit(), candidate: Candidate(name: "Sam"), channel: .thisMac)
        await #expect(throws: InterviewFileError.self) { _ = try await client.submit(s, deviceID: "d", app: "t") }
    }

    @Test func bulkInvitesCanBeOffline() async throws {
        let kit = try approvedKit()
        let session = StubProtocol.session(host: "invite.test") { r, body in
            let b = object(body)
            #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer snz_test_token_123456789")
            #expect(b["delivery"] as? String == "offline")
            #expect((b["candidates"] as? [[String: String]])?.first?["email"] == "a@example.com")
            return (201, json(["success": true, "data": ["invited": 1, "failed": 0, "results": [
                ["name": "A", "email": "a@example.com", "uuid": "u1", "url": "https://x/i/tok", "app_url": "snazzypro://interview?link=x"],
            ]]]))
        }
        let link = OpsAPILink(baseURL: URL(string: "https://invite.test")!, token: "snz_test_token_123456789", session: session)
        let r = try await link.invite(kit: kit, packUUID: nil, invitees: [.init(name: "A", email: "a@example.com")], days: 7, offline: true)
        #expect(r.invited == 1)
        #expect(r.results.first?.appUrl == "snazzypro://interview?link=x")
    }

    @Test func fetchesResultsForEveryCandidate() async throws {
        var done = InterviewSession(kit: try approvedKit(), candidate: Candidate(name: "Sam Taylor"), channel: .thisMac)
        done.state = .completed
        let fileData = try InterviewFile.encode(done, app: "OpsAPI")
        let session = StubProtocol.session(host: "results.test") { r, _ in
            if r.url?.path == "/api/v2/public/ats/integration/interviews" {
                let q = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                #expect(q.contains { $0.name == "since" && $0.value == "2026-10-01T00:00:00Z" })
                return (200, json(["success": true, "data": [
                    ["uuid": "i1", "candidate": ["name": "Sam Taylor", "email": NSNull()], "job_title": "Lead", "state": "completed",
                     "delivery": "offline", "evaluation_status": "done", "decision": NSNull(),
                     "ended_at": "2026-10-18 20:01:02.345678+00", "updated_at": "2026-10-18T20:05:00Z"],
                    ["uuid": "i2", "state": "invited", "delivery": "online", "started_at": NSNull()],
                ]]))
            }
            #expect(r.url?.path == "/api/v2/public/ats/integration/interviews/i1")
            return (200, json(["success": true, "data": ["uuid": "i1", "delivery": "offline", "file": try! JSONSerialization.jsonObject(with: fileData)]]))
        }
        let link = OpsAPILink(baseURL: URL(string: "https://results.test")!, token: "snz_x", session: session)
        let list = try await link.interviews(since: Date(timeIntervalSince1970: 1_790_812_800))
        #expect(list.map(\.uuid) == ["i1", "i2"])
        #expect(list[0].isFinished && !list[1].isFinished)
        #expect(abs((list[0].endedAt?.timeIntervalSince1970 ?? 0) - 1_792_353_662.345) < 0.01)
        #expect(list[0].candidate?.email == nil)
        let full = try await link.interview("i1")
        #expect(full.id == done.id)
        #expect(full.state == .completed)
    }

    @Test func registersARecruiter() async throws {
        let session = StubProtocol.session(host: "register.test") { r, body in
            let b = object(body)
            #expect(r.url?.path == "/api/v2/public/ats/recruiters/register")
            #expect(b["company"] as? String == "Acme Ltd")
            #expect(b["email"] as? String == "jo@acme.test")
            #expect(b["password"] as? String == "correct horse")
            if b["email"] as? String == "taken@acme.test" {
                return (409, json(["success": false, "error": "That email already has an account: sign in instead.", "code": "email_taken"]))
            }
            return (201, json(["success": true, "data": ["token": "snz_abcdefghijklmnopqrstuvwxyz", "namespace": ["uuid": "ns1", "name": "Acme Ltd"],
                                                         "active": false, "dashboard_url": "https://dash/ats"]]))
        }
        let base = URL(string: "https://register.test")!
        let linked = try await RecruiterAccount.register(at: base, company: " Acme Ltd ", firstName: "Jo", lastName: "Bloggs",
                                                         email: "jo@acme.test", password: "correct horse", deviceName: "Jo's Mac", session: session)
        #expect(linked.token.hasPrefix("snz_"))
        #expect(linked.namespace.name == "Acme Ltd")
        #expect(linked.active == false)
        #expect(linked.dashboardUrl == "https://dash/ats")
        await #expect(throws: RecruiterAccount.Problem(message: "Choose a password of at least 8 characters.")) {
            _ = try await RecruiterAccount.register(at: base, company: "Acme", firstName: "Jo", lastName: "B", email: "jo@acme.test",
                                                    password: "short", deviceName: "", session: session)
        }
    }

    @Test func registeringATakenEmailSaysSignIn() async throws {
        let session = StubProtocol.session(host: "taken.test") { _, _ in
            (409, json(["success": false, "error": "That email already has an account: sign in instead.", "code": "email_taken"]))
        }
        do {
            _ = try await RecruiterAccount.register(at: URL(string: "https://taken.test")!, company: "Acme", firstName: "Jo", lastName: "B",
                                                    email: "taken@acme.test", password: "long enough", deviceName: "", session: session)
            Issue.record("expected an error")
        } catch let p as RecruiterAccount.Problem {
            #expect(p.code == "email_taken")
        }
    }

    @Test func signsInChoosingAWorkspace() async throws {
        let session = StubProtocol.session(host: "signin.test") { _, body in
            let b = object(body)
            #expect(b["device_name"] as? String == "Mac")
            if b["namespace_uuid"] == nil {
                return (200, json(["success": true, "data": ["choose": [["uuid": "a", "name": "Acme"], ["uuid": "b", "name": "Beta"]]]]))
            }
            #expect(b["namespace_uuid"] as? String == "b")
            return (200, json(["success": true, "data": ["token": "snz_0123456789abcdefghij", "namespace": ["uuid": "b", "name": "Beta"], "active": true]]))
        }
        let base = URL(string: "https://signin.test")!
        guard case .choose(let options) = try await RecruiterAccount.signIn(at: base, email: "jo@x.test", password: "pw", deviceName: "Mac", session: session) else {
            Issue.record("expected a choice")
            return
        }
        #expect(options.map(\.name) == ["Acme", "Beta"])
        guard case .linked(let l) = try await RecruiterAccount.signIn(at: base, email: "jo@x.test", password: "pw", workspace: "b", deviceName: "Mac", session: session) else {
            Issue.record("expected a token")
            return
        }
        #expect(l.namespace.uuid == "b")
        #expect(l.active == true)
    }

    @Test func accountsOnlyOverHTTPS() throws {
        #expect(throws: RecruiterAccount.Problem.self) { try RecruiterAccount.checkedBase("http://api.example.com") }
        #expect(try RecruiterAccount.checkedBase("api.example.com").absoluteString == "https://api.example.com")
        #expect(try RecruiterAccount.checkedBase("http://localhost:4010").port == 4010)
        #expect(throws: RecruiterAccount.Problem.self) { try RecruiterAccount.checkedBase("not a url") }
    }

    @Test func offlineInvitesKeepTheirRecordAndOldFilesStillOpen() throws {
        var s = InterviewSession(kit: try approvedKit(), candidate: Candidate(name: "Sam"), channel: .thisMac)
        var invite = OfflineInvite(api: URL(string: "https://api.example.com")!, notice: "n", noticeHash: "h",
                                   uploadBy: Date(timeIntervalSince1970: 2_000_000_000), interviewUUID: "u")
        invite.lastError = "offline"
        s.offline = invite
        let back = try InterviewJSON.decoder.decode(InterviewSession.self, from: InterviewJSON.encoder.encode(s))
        #expect(back.offline == invite)
        #expect(back.offline?.isPending(now: Date(timeIntervalSince1970: 1_900_000_000)) == true)
        #expect(back.offline?.isPending(now: Date(timeIntervalSince1970: 2_100_000_000)) == false)
        invite.uploadedAt = Date()
        #expect(!invite.isPending())
        // Sessions saved before this field existed.
        var old = object(try InterviewJSON.encoder.encode(s))
        old.removeValue(forKey: "offline")
        #expect(try InterviewJSON.decoder.decode(InterviewSession.self, from: json(old)).offline == nil)
        #expect(OfflineInvite.keychainAccount(for: s.id) == "interview.invite.\(s.id.uuidString)")
    }

    @Test func readsDatesTheWayOpsAPIWritesThem() {
        #expect(LooseDate.parse("2026-10-18T20:00:00Z") == Date(timeIntervalSince1970: 1_792_353_600))
        #expect(LooseDate.parse("2026-10-18T20:00:00.250Z") == Date(timeIntervalSince1970: 1_792_353_600.25))
        #expect(LooseDate.parse("2026-10-18 20:00:00+00") == Date(timeIntervalSince1970: 1_792_353_600))
        #expect(LooseDate.parse("2026-10-18 21:00:00+01:00") == Date(timeIntervalSince1970: 1_792_353_600))
        #expect(LooseDate.parse("yesterday") == nil)
    }

    @Test func theCandidateViewSaysHowItRuns() throws {
        let v = try InterviewJSON.decoder.decode(CandidateView.self, from: json(["state": "invited", "delivery": "offline"]))
        #expect(v.isOffline)
        let old = try InterviewJSON.decoder.decode(CandidateView.self, from: json(["state": "invited"]))
        #expect(!old.isOffline)
    }
}

/// OpsAPI's real reply to `/offline` (docs/specs/fixtures/offline-start.json, from the shared kit).
@Suite struct OfflineContractTests {
    @Test func decodesOpsAPIsOfflineReply() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/specs/fixtures/offline-start.json")
        let env = try InterviewJSON.decoder.decode(InviteClient.Envelope<OfflineStart>.self, from: Data(contentsOf: url))
        let start = try #require(env.data)
        #expect(start.kit.competencies.allSatisfy { $0.anchors == Competency.Anchors() })
        #expect(start.notice.contains("on your own computer"))
        #expect(start.uploadBy != nil)
        #expect(start.interviewUuid == "00000000-0000-4000-8000-000000000001")
        #expect(start.kit.isApproved)
    }

    @Test func kitsApprovedAtOlderOpsAPIsStillCountAsApproved() throws {
        var kit = object(try InterviewJSON.encoder.encode(try sampleKit()))
        kit["approved_at"] = "2026-10-18 10:00:00+00"
        let decoded = try InterviewJSON.decoder.decode(RoleKit.self, from: json(kit))
        #expect(decoded.approvedAt == Date(timeIntervalSince1970: 1_792_317_600))
    }
}

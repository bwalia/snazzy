import AppKit
import Foundation
import Observation
import SnazzyCore

/// Opt-in sharing to places the user owns: an S3-compatible bucket, a GitHub
/// release (video) or a GitHub Gist (summary and captions). Every upload is
/// confirmed first, and a local log lets the user delete remote copies.
@MainActor @Observable
final class ShareService {
    enum Target: String, CaseIterable, Codable {
        case s3, github, gist

        var label: String {
            switch self {
            case .s3: "S3 bucket"
            case .github: "GitHub release"
            case .gist: "GitHub Gist (summary and captions)"
            }
        }
    }

    struct Record: Codable, Identifiable, Hashable {
        var id = UUID()
        var recordingID: String
        var file: String
        var target: Target
        var url: String
        var date: Date
        var expires: Date?
        /// What's needed to delete it: S3 key, release asset id, or gist id.
        var remoteRef: String
        var deleted = false
    }

    struct Outcome {
        var record: Record
        var slack: String
        var githubComment: String
        var jira: String
    }

    private(set) var records: [Record] = []
    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private let session = URLSession(configuration: .ephemeral)

    static let s3AccessAccount = "share.s3.access-key"
    static let s3SecretAccount = "share.s3.secret-key"
    static let githubAccount = "github.token"

    private var logURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Snazzy Pro/shares.json")
    }

    init(app: AppModel) {
        self.app = app
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        records = (try? d.decode([Record].self, from: Data(contentsOf: logURL))) ?? []
    }

    private func saveLog() {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = .prettyPrinted
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? e.encode(records).write(to: logURL, options: .atomic)
    }

    func secret(_ account: String) -> String? { (try? app.secrets.secret(for: account)) ?? nil }

    var configuredTargets: [Target] {
        var t: [Target] = []
        let s = app.developer.settings
        if s.s3 != nil, secret(Self.s3AccessAccount) != nil, secret(Self.s3SecretAccount) != nil { t.append(.s3) }
        if secret(Self.githubAccount) != nil {
            if let repo = s.githubShareRepo, repo.contains("/") { t.append(.github) }
            t.append(.gist)
        }
        return t
    }

    // MARK: Share

    /// Uploads after asking. Returns links and ready-to-paste messages.
    func share(_ item: RecordingItem, to target: Target) async throws -> Outcome {
        let s = app.developer.settings
        guard s.shareEnabled else { throw app.developer.disabled("Sharing") }
        guard configuredTargets.contains(target) else {
            throw CaptureActionError(message: "\(target.label) isn't set up. Add it in Settings › Developer › Share.")
        }
        // What will be uploaded.
        let files: [URL] = target == .gist
            ? [item.sidecar("md"), item.sidecar("srt")].filter { FileManager.default.fileExists(atPath: $0.path) }
            : [item.url]
        guard !files.isEmpty else {
            throw CaptureActionError(message: "Nothing to put in a Gist yet. Make captions or a summary first.")
        }
        let size = files.reduce(Int64(0)) { $0 + ((try? FileManager.default.attributesOfItem(atPath: $1.path)[.size] as? Int64) ?? 0) }
        let destination: String = switch target {
        case .s3: "\(s.s3!.bucket)/\(s.s3!.prefix)\(item.url.lastPathComponent) at \(URL(string: s.s3!.endpoint)?.host() ?? s.s3!.endpoint). The link works for \(s.shareLinkHours) hours."
        case .github: "a release asset in \(s.githubShareRepo!). Anyone who can see that repository can download it."
        case .gist: "a secret GitHub Gist. Anyone with the link can read it."
        }
        guard confirm(files: files, size: size, destination: destination) else {
            throw CaptureActionError(message: "Not shared. The upload was cancelled.")
        }

        app.developer.setBusy("Uploading \(item.id)…")
        defer { app.developer.setBusy(nil) }
        var record: Record
        switch target {
        case .s3: record = try await uploadS3(item)
        case .github: record = try await uploadRelease(item)
        case .gist: record = try await uploadGist(item, files: files)
        }
        records.insert(record, at: 0)
        saveLog()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.url, forType: .string)
        app.chat.logSession("shared", ["recording": .string(item.id), "target": .string(target.rawValue)])
        return outcome(record, item: item)
    }

    private func confirm(files: [URL], size: Int64, destination: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Upload \(files.count == 1 ? files[0].lastPathComponent : "\(files.count) files")?"
        alert.informativeText = "\(files.map(\.lastPathComponent).joined(separator: ", "))\n\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))\n\nGoes to \(destination)"
        alert.addButton(withTitle: "Upload")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: S3

    private func s3Signer() throws -> (SigV4, S3Destination) {
        guard let dest = app.developer.settings.s3, let access = secret(Self.s3AccessAccount), let key = secret(Self.s3SecretAccount) else {
            throw CaptureActionError(message: "S3 isn't set up.")
        }
        return (SigV4(accessKey: access, secretKey: key, region: dest.region.isEmpty ? "us-east-1" : dest.region), dest)
    }

    static func objectURL(_ dest: S3Destination, key: String) -> URL? {
        guard var base = URLComponents(string: dest.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let encodedKey = key.split(separator: "/").map { SigV4.encode(String($0)) }.joined(separator: "/")
        if dest.pathStyle {
            base.percentEncodedPath = "/\(SigV4.encode(dest.bucket))/\(encodedKey)"
        } else {
            base.host = "\(dest.bucket).\(base.host ?? "")"
            base.percentEncodedPath = "/\(encodedKey)"
        }
        return base.url
    }

    private func uploadS3(_ item: RecordingItem) async throws -> Record {
        let (signer, dest) = try s3Signer()
        let key = dest.prefix + item.url.lastPathComponent
        guard let url = Self.objectURL(dest, key: key) else { throw CaptureActionError(message: "The S3 endpoint isn't a valid URL.") }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(item.url.pathExtension == "mp4" ? "video/mp4" : "video/quicktime", forHTTPHeaderField: "Content-Type")
        signer.sign(&request)
        let (data, response) = try await session.upload(for: request, fromFile: item.url)
        try Self.check(response, data, "S3")
        let hours = min(max(app.developer.settings.shareLinkHours, 1), 168)
        let link = signer.presignedURL(url: url, expires: hours * 3600)
        return Record(recordingID: item.id, file: item.url.lastPathComponent, target: .s3, url: link.absoluteString,
                      date: Date(), expires: Date().addingTimeInterval(Double(hours) * 3600), remoteRef: key)
    }

    // MARK: GitHub

    private func github(_ path: String, method: String = "GET", body: Data? = nil, host: String = "api.github.com",
                        contentType: String = "application/json") async throws -> (Data, Int) {
        guard let token = secret(Self.githubAccount) else { throw CaptureActionError(message: "No GitHub token. Add one in Settings › Developer.") }
        var request = URLRequest(url: URL(string: "https://\(host)\(path)")!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let body {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func uploadRelease(_ item: RecordingItem) async throws -> Record {
        guard let repo = app.developer.settings.githubShareRepo else { throw CaptureActionError(message: "No GitHub repository set.") }
        let tag = "snazzy-pro-shares"
        var (data, status) = try await github("/repos/\(repo)/releases/tags/\(tag)")
        if status == 404 {
            let body = try (["tag_name": .string(tag), "name": "Snazzy Pro recordings", "prerelease": true,
                             "body": "Recordings shared from Snazzy Pro."] as JSONValue).encoded()
            (data, status) = try await github("/repos/\(repo)/releases", method: "POST", body: body)
        }
        guard (200..<300).contains(status), let release = try? JSONValue.parse(data), let releaseID = release["id"]?.intValue else {
            throw CaptureActionError(message: "GitHub release: HTTP \(status) \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        let name = item.url.lastPathComponent.replacingOccurrences(of: " ", with: ".")
        let videoData = try Data(contentsOf: item.url, options: .mappedIfSafe)
        let (assetData, assetStatus) = try await github(
            "/repos/\(repo)/releases/\(releaseID)/assets?name=\(SigV4.encode(name))", method: "POST", body: videoData,
            host: "uploads.github.com", contentType: item.url.pathExtension == "mp4" ? "video/mp4" : "video/quicktime")
        guard (200..<300).contains(assetStatus), let asset = try? JSONValue.parse(assetData),
              let link = asset["browser_download_url"]?.stringValue, let assetID = asset["id"]?.intValue else {
            throw CaptureActionError(message: "GitHub upload: HTTP \(assetStatus) \(String(decoding: assetData.prefix(200), as: UTF8.self))")
        }
        return Record(recordingID: item.id, file: item.url.lastPathComponent, target: .github, url: link, date: Date(),
                      remoteRef: "\(repo)#\(assetID)")
    }

    private func uploadGist(_ item: RecordingItem, files: [URL]) async throws -> Record {
        var contents: [String: JSONValue] = [:]
        for f in files { contents[f.lastPathComponent] = ["content": .string((try? String(contentsOf: f, encoding: .utf8)) ?? "")] }
        let body = try (["description": .string("Snazzy Pro: \(item.id)"), "public": false, "files": .object(contents)] as JSONValue).encoded()
        let (data, status) = try await github("/gists", method: "POST", body: body)
        guard (200..<300).contains(status), let gist = try? JSONValue.parse(data),
              let link = gist["html_url"]?.stringValue, let id = gist["id"]?.stringValue else {
            throw CaptureActionError(message: "GitHub Gist: HTTP \(status) \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        return Record(recordingID: item.id, file: files.map(\.lastPathComponent).joined(separator: ", "), target: .gist,
                      url: link, date: Date(), remoteRef: id)
    }

    // MARK: Delete remote copy

    func deleteRemote(_ record: Record) async throws {
        switch record.target {
        case .s3:
            let (signer, dest) = try s3Signer()
            guard let url = Self.objectURL(dest, key: record.remoteRef) else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            signer.sign(&request, payloadHash: SigV4.emptyPayloadHash)
            let (data, response) = try await session.data(for: request)
            try Self.check(response, data, "S3")
        case .github:
            let parts = record.remoteRef.split(separator: "#")
            guard parts.count == 2 else { return }
            let (data, status) = try await github("/repos/\(parts[0])/releases/assets/\(parts[1])", method: "DELETE")
            guard (200..<300).contains(status) || status == 404 else {
                throw CaptureActionError(message: "GitHub: HTTP \(status) \(String(decoding: data.prefix(200), as: UTF8.self))")
            }
        case .gist:
            let (data, status) = try await github("/gists/\(record.remoteRef)", method: "DELETE")
            guard (200..<300).contains(status) || status == 404 else {
                throw CaptureActionError(message: "GitHub: HTTP \(status) \(String(decoding: data.prefix(200), as: UTF8.self))")
            }
        }
        if let i = records.firstIndex(where: { $0.id == record.id }) { records[i].deleted = true }
        saveLog()
    }

    /// Checks an S3 connection by uploading and deleting a tiny file.
    func testS3() async throws {
        let (signer, dest) = try s3Signer()
        guard let url = Self.objectURL(dest, key: dest.prefix + ".snazzy-test") else { throw CaptureActionError(message: "Invalid endpoint") }
        var put = URLRequest(url: url)
        put.httpMethod = "PUT"
        let body = Data("ok".utf8)
        signer.sign(&put, payloadHash: SigV4.sha256Hex(body))
        let (d1, r1) = try await session.upload(for: put, from: body)
        try Self.check(r1, d1, "S3")
        var del = URLRequest(url: url)
        del.httpMethod = "DELETE"
        signer.sign(&del, payloadHash: SigV4.emptyPayloadHash)
        _ = try await session.data(for: del)
    }

    static func check(_ response: URLResponse, _ data: Data, _ service: String) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = String(decoding: data.prefix(300), as: UTF8.self)
            let code = body.range(of: "<Code>").flatMap { r in body[r.upperBound...].range(of: "</Code>").map { String(body[r.upperBound..<$0.lowerBound]) } }
            throw CaptureActionError(message: "\(service) said HTTP \(status)\(code.map { " (\($0))" } ?? "").")
        }
    }

    // MARK: Ready-to-paste text

    func outcome(_ record: Record, item: RecordingItem) -> Outcome {
        let summary = (try? String(contentsOf: item.sidecar("md"), encoding: .utf8)) ?? ""
        let title = summary.split(separator: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) } ?? item.id
        let bullets = summary.split(separator: "\n").filter { $0.hasPrefix("- ") }.prefix(5).map { String($0.dropFirst(2)) }
        let expiry = record.expires.map { " (link works until \($0.formatted(date: .abbreviated, time: .shortened)))" } ?? ""
        let slack = "*\(title)*\n<\(record.url)|Watch the recording>\(expiry)" + bullets.map { "\n• \($0)" }.joined()
        let github = "### 🎬 \(title)\n\n[Watch the recording](\(record.url))\(expiry)" + (bullets.isEmpty ? "" : "\n\n" + bullets.map { "- \($0)" }.joined(separator: "\n"))
        let jira = "h3. \(title)\n[Watch the recording|\(record.url)]\(expiry)" + bullets.map { "\n* \($0)" }.joined()
        return Outcome(record: record, slack: slack, githubComment: github, jira: jira)
    }
}

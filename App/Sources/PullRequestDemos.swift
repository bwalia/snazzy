import AppKit
import Foundation
import SnazzyCore

/// Feature 4: load a pull request (or a pushed local branch) so the assistant
/// can plan a short demo deck and script.
extension DeveloperController {
    static let bookmarksKey = "SnazzyPro.repoBookmarks"

    /// Repository folders the user granted (security-scoped bookmarks).
    var grantedRepositories: [URL] {
        let datas = UserDefaults.standard.array(forKey: Self.bookmarksKey) as? [Data] ?? []
        return datas.compactMap { data in
            var stale = false
            return try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
        }
    }

    /// Asks the user to pick a repository folder and remembers it.
    @discardableResult
    func grantRepository() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a git repository folder (the one containing .git)"
        panel.prompt = "Allow"
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        else { return nil }
        var list = UserDefaults.standard.array(forKey: Self.bookmarksKey) as? [Data] ?? []
        list.removeAll { d in
            var s = false
            return (try? URL(resolvingBookmarkData: d, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &s))?.path == url.path
        }
        list.append(data)
        UserDefaults.standard.set(list, forKey: Self.bookmarksKey)
        return url
    }

    func removeRepository(_ url: URL) {
        let list = (UserDefaults.standard.array(forKey: Self.bookmarksKey) as? [Data] ?? []).filter { d in
            var s = false
            return (try? URL(resolvingBookmarkData: d, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &s))?.path != url.path
        }
        UserDefaults.standard.set(list, forKey: Self.bookmarksKey)
    }

    // MARK: GitHub API

    private func githubGET(_ path: String, accept: String = "application/vnd.github+json") async throws -> (Data, Int) {
        var request = URLRequest(url: URL(string: "https://api.github.com\(path)")!)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let token = share.secret(ShareService.githubAccount) { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 403 || status == 429, (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" {
            throw CaptureActionError(message: "GitHub's rate limit was reached. Add a GitHub token in Settings › Developer for a higher limit.")
        }
        return (data, status)
    }

    func loadPullRequest(_ refText: String, number: Int?, offMac: String?) async throws -> JSONValue {
        guard settings.pullRequestDemosEnabled else { throw disabled("Pull-request demos") }
        guard let ref = GitRefs.parse(refText, number: number), let n = ref.number else {
            throw CaptureActionError(message: "Use owner/repo and a PR number, e.g. octocat/hello-world#12 or the PR's URL.")
        }
        busy = "Loading \(ref.slug)#\(n)…"
        defer { busy = nil }
        let (prData, status) = try await githubGET("/repos/\(ref.slug)/pulls/\(n)")
        guard status == 200, let pr = try? JSONValue.parse(prData) else {
            throw CaptureActionError(message: status == 404
                ? "Couldn't find \(ref.slug)#\(n). For a private repository, add a GitHub token in Settings › Developer."
                : "GitHub said HTTP \(status).")
        }
        let (filesData, _) = try await githubGET("/repos/\(ref.slug)/pulls/\(n)/files?per_page=100")
        let files = (try? JSONValue.parse(filesData))?.arrayValue ?? []
        let (diffData, _) = try await githubGET("/repos/\(ref.slug)/pulls/\(n)", accept: "application/vnd.github.diff")
        let (diff, truncated) = GitRefs.cap(String(decoding: diffData, as: UTF8.self), limit: settings.maxDiffCharacters)
        let result: JSONValue = [
            "pull_request": .string("\(ref.slug)#\(n)"),
            "title": pr["title"] ?? "",
            "author": pr["user"]?["login"] ?? "",
            "url": pr["html_url"] ?? "",
            "base": pr["base"]?["ref"] ?? "", "head": pr["head"]?["ref"] ?? "",
            "state": pr["state"] ?? "",
            "description": .string(String((pr["body"]?.stringValue ?? "").prefix(4000))),
            "stats": ["files": pr["changed_files"] ?? 0, "additions": pr["additions"] ?? 0, "deletions": pr["deletions"] ?? 0],
            "files": .array(files.prefix(100).map { ["file": $0["filename"] ?? "", "status": $0["status"] ?? "",
                                                     "additions": $0["additions"] ?? 0, "deletions": $0["deletions"] ?? 0] }),
            "diff": .string(diff),
            "diff_truncated": .bool(truncated),
            "next_steps": "Plan a 2–4 slide demo deck (what changed, why, how to test) with create_project (kind presentation), put a short talk script in each slide's speaker notes, then ask the user whether to record now.",
        ]
        try reviewIfCloud(result, what: "this pull request (title, description, file list and diff)", offMac: offMac)
        app.chat.logSession("pull_request_loaded", ["pull_request": .string("\(ref.slug)#\(n)"), "diff_truncated": .bool(truncated)])
        return result
    }

    /// A local branch, compared with `base` through GitHub (the branch must be pushed).
    func loadGitChanges(path: String?, base: String, offMac: String?) async throws -> JSONValue {
        guard settings.pullRequestDemosEnabled else { throw disabled("Pull-request demos") }
        let repos = grantedRepositories
        guard !repos.isEmpty else {
            throw CaptureActionError(message: "Choose the repository folder first: Builder › Demo from Local Branch… (or Settings › Developer).")
        }
        let q = (path ?? "").trimmingCharacters(in: .whitespaces)
        guard let folder = q.isEmpty ? repos.last : repos.first(where: { $0.path == q || $0.lastPathComponent.caseInsensitiveCompare(q) == .orderedSame || $0.path.hasSuffix(q) }) else {
            throw CaptureActionError(message: "“\(q)” isn't one of the allowed folders: \(repos.map(\.lastPathComponent).joined(separator: ", ")).")
        }
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        let git = folder.appending(path: ".git")
        guard let head = try? String(contentsOf: git.appending(path: "HEAD"), encoding: .utf8),
              let config = try? String(contentsOf: git.appending(path: "config"), encoding: .utf8) else {
            throw CaptureActionError(message: "\(folder.lastPathComponent) doesn't look like a git repository (no readable .git folder).")
        }
        guard let branch = GitRefs.branch(fromHEAD: head) else {
            throw CaptureActionError(message: "The repository isn't on a branch (detached HEAD). Check out a branch first.")
        }
        guard let remote = GitRefs.remoteURL(fromConfig: config), let ref = GitRefs.parse(remote) else {
            throw CaptureActionError(message: "This repository has no GitHub 'origin' remote.")
        }
        busy = "Comparing \(branch) with \(base)…"
        defer { busy = nil }
        let compare = "/repos/\(ref.slug)/compare/\(SigV4.encode(base))...\(SigV4.encode(branch))"
        let (jsonData, status) = try await githubGET(compare)
        guard status == 200, let json = try? JSONValue.parse(jsonData) else {
            throw CaptureActionError(message: status == 404
                ? "GitHub doesn't have branch “\(branch)” yet. Push it first (git push -u origin \(branch)). Snazzy Pro can't run git itself inside the App Store sandbox, so it compares through GitHub."
                : "GitHub said HTTP \(status).")
        }
        let (diffData, _) = try await githubGET(compare, accept: "application/vnd.github.diff")
        let (diff, truncated) = GitRefs.cap(String(decoding: diffData, as: UTF8.self), limit: settings.maxDiffCharacters)
        let commits = json["commits"]?.arrayValue ?? []
        let result: JSONValue = [
            "repository": .string(ref.slug), "branch": .string(branch), "base": .string(base),
            "commits": .array(commits.suffix(20).map { .string(String(($0["commit"]?["message"]?.stringValue ?? "").prefix(200))) }),
            "files": .array((json["files"]?.arrayValue ?? []).prefix(100).map { ["file": $0["filename"] ?? "", "status": $0["status"] ?? "",
                                                                                 "additions": $0["additions"] ?? 0, "deletions": $0["deletions"] ?? 0] }),
            "diff": .string(diff),
            "diff_truncated": .bool(truncated),
            "note": "Only changes pushed to GitHub are included.",
            "next_steps": "Plan a 2–4 slide demo deck (what changed, why, how to test) with create_project (kind presentation), put a short talk script in the speaker notes, then ask the user whether to record now.",
        ]
        try reviewIfCloud(result, what: "the changes on \(branch) (commit messages, file list and diff)", offMac: offMac)
        return result
    }

    /// When the result leaves this Mac, shows exactly what will be sent and asks.
    func reviewIfCloud(_ result: JSONValue, what: String, offMac: String?) throws {
        guard let offMac else { return }
        guard CloudReview.confirm(provider: offMac, what: what, text: result.compactString,
                                  note: "Use a local model to keep code on this Mac.")
        else { throw CaptureActionError(message: "Not sent. The user chose to keep this code on their Mac.") }
    }
}

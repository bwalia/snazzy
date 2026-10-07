import Foundation

/// Parsing for GitHub references and local git metadata (no `git` binary:
/// the App Store sandbox can't run it).
public enum GitRefs {
    public struct PullRequestRef: Equatable, Sendable {
        public var owner: String
        public var repo: String
        public var number: Int?
        public var slug: String { "\(owner)/\(repo)" }
    }

    /// Accepts "owner/repo", "owner/repo#123", PR or repo URLs, and SSH remotes.
    public static func parse(_ text: String, number: Int? = nil) -> PullRequestRef? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var n = number
        if let hash = s.lastIndex(of: "#"), let v = Int(s[s.index(after: hash)...]) {
            n = n ?? v
            s = String(s[..<hash])
        }
        for prefix in ["https://github.com/", "http://github.com/", "github.com/", "git@github.com:", "ssh://git@github.com/"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
        let parts = s.split(separator: "/").map(String.init)
        guard parts.count >= 2, isName(parts[0]), isName(parts[1]) else { return nil }
        if parts.count >= 4, parts[2] == "pull" || parts[2] == "pulls", let v = Int(parts[3]) { n = n ?? v }
        return PullRequestRef(owner: parts[0], repo: parts[1], number: n)
    }

    static func isName(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 100 && s.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) } && s != "." && s != ".."
    }

    /// The current branch from `.git/HEAD` ("ref: refs/heads/feature/x").
    public static func branch(fromHEAD text: String) -> String? {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("ref: refs/heads/") else { return nil }  // detached HEAD
        return String(line.dropFirst("ref: refs/heads/".count))
    }

    /// A remote's URL from `.git/config`.
    public static func remoteURL(fromConfig text: String, remote: String = "origin") -> String? {
        var inRemote = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inRemote = line == "[remote \"\(remote)\"]"
            } else if inRemote, line.hasPrefix("url") {
                return line.split(separator: "=", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) }
            }
        }
        return nil
    }

    /// Cuts a diff to `limit` characters at a line boundary.
    public static func cap(_ diff: String, limit: Int) -> (text: String, truncated: Bool) {
        guard diff.count > limit else { return (diff, false) }
        let prefix = diff.prefix(limit)
        let cut = prefix.lastIndex(of: "\n").map { prefix[..<$0] } ?? prefix
        return (String(cut) + "\n… (diff cut at \(limit.formatted()) of \(diff.count.formatted()) characters)", true)
    }
}

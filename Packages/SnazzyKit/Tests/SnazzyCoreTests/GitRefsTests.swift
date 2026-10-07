import Foundation
import Testing
@testable import SnazzyCore

@Suite struct GitRefsTests {
    @Test func parsesReferences() {
        #expect(GitRefs.parse("bwalia/snazzy")?.slug == "bwalia/snazzy")
        #expect(GitRefs.parse("bwalia/snazzy#123")?.number == 123)
        #expect(GitRefs.parse("https://github.com/bwalia/snazzy/pull/45/files") == .init(owner: "bwalia", repo: "snazzy", number: 45))
        #expect(GitRefs.parse("git@github.com:bwalia/snazzy.git")?.slug == "bwalia/snazzy")
        #expect(GitRefs.parse("bwalia/snazzy", number: 7)?.number == 7)
        #expect(GitRefs.parse("not a repo") == nil)
        #expect(GitRefs.parse("../etc/passwd") == nil)
    }

    @Test func readsGitMetadata() {
        #expect(GitRefs.branch(fromHEAD: "ref: refs/heads/feature/login\n") == "feature/login")
        #expect(GitRefs.branch(fromHEAD: "a1b2c3d4e5\n") == nil)
        let config = """
            [core]
            \trepositoryformatversion = 0
            [remote "upstream"]
            \turl = https://github.com/other/fork.git
            [remote "origin"]
            \turl = git@github.com:bwalia/snazzy.git
            \tfetch = +refs/heads/*:refs/remotes/origin/*
            """
        #expect(GitRefs.remoteURL(fromConfig: config) == "git@github.com:bwalia/snazzy.git")
        #expect(GitRefs.remoteURL(fromConfig: config, remote: "upstream") == "https://github.com/other/fork.git")
    }

    @Test func capsDiffsAtLineBoundaries() {
        let diff = (1...100).map { "+ line \($0)" }.joined(separator: "\n")
        let (text, truncated) = GitRefs.cap(diff, limit: 50)
        #expect(truncated)
        #expect(text.hasPrefix("+ line 1\n"))
        #expect(text.contains("diff cut at 50"))
        // Every kept line is a complete diff line (no line cut in half).
        #expect(text.components(separatedBy: "\n").dropLast().allSatisfy { $0.range(of: #"^\+ line \d+$"#, options: .regularExpression) != nil })
        #expect(GitRefs.cap("short", limit: 50) == ("short", false))
    }
}

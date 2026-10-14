import Foundation
import Testing
@testable import MyGitApp

@Suite struct LocalRepoResolverTests {
    @Test(arguments: [
        ("git@github.com:acme/app.git", "acme/app"),
        ("git@github.com:acme/app", "acme/app"),
        ("https://github.com/acme/app.git", "acme/app"),
        ("https://github.com/acme/app/", "acme/app"),
        ("https://token@github.com/acme/app.git", "acme/app"),
        ("ssh://git@github.com/acme/app.git", "acme/app"),
        ("ssh://git@github.com:22/acme/app.git", "acme/app"),
        ("git@github.com-work:acme/app.git", "acme/app"),
        ("  git@github.com:acme/my.repo.git\n", "acme/my.repo"),
    ])
    func parsesGitHubRemotes(remote: String, expected: String) {
        #expect(LocalRepoResolver.parseGitHubRemote(remote) == expected)
    }

    @Test(arguments: ["git@gitlab.com:acme/app.git", "https://bitbucket.org/acme/app", "/local/path", "github.com"])
    func rejectsNonGitHubRemotes(remote: String) {
        #expect(LocalRepoResolver.parseGitHubRemote(remote) == nil)
    }

    @Test func parsesRemotesFromConfig() {
        let config = """
        [core]
        \trepositoryformatversion = 0
        [remote "upstream"]
        \turl = https://github.com/upstream/app.git
        \tfetch = +refs/heads/*:refs/remotes/upstream/*
        [remote "origin"]
        \turl = git@github.com:me/app.git
        [branch "main"]
        \tremote = origin
        """
        let remotes = LocalRepoResolver.parseRemotes(config: config)
        #expect(remotes.map(\.name) == ["upstream", "origin"])
        #expect(remotes[1].url == "git@github.com:me/app.git")
    }

    @Test func resolvesClonesWorktreesAndScans() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mga-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default

        // Regular clone preferring origin over upstream.
        let clone = root.appendingPathComponent("projects/app")
        try fm.createDirectory(at: clone.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "[remote \"upstream\"]\n\turl = https://github.com/up/app\n[remote \"origin\"]\n\turl = git@github.com:me/app.git\n"
            .write(to: clone.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)
        try "ref: refs/heads/feature/x\n".write(to: clone.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)

        // Worktree: `.git` file → gitdir with commondir pointing back at the clone.
        let wtGitDir = clone.appendingPathComponent(".git/worktrees/wt")
        try fm.createDirectory(at: wtGitDir, withIntermediateDirectories: true)
        try "../..\n".write(to: wtGitDir.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        try "0123456789abcdef\n".write(to: wtGitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        let worktree = root.appendingPathComponent("projects/nested/wt")
        try fm.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: \(wtGitDir.path)\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        // Non-GitHub repo and a plain folder.
        let other = root.appendingPathComponent("projects/other")
        try fm.createDirectory(at: other.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "[remote \"origin\"]\n\turl = git@gitlab.com:x/y.git\n".write(to: other.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: root.appendingPathComponent("projects/node_modules/pkg/.git"), withIntermediateDirectories: true)

        let info = try #require(LocalRepoResolver.resolve(path: clone.path))
        #expect(info.nameWithOwner == "me/app")
        #expect(info.branch == "feature/x")

        let wt = try #require(LocalRepoResolver.resolve(path: worktree.path))
        #expect(wt.nameWithOwner == "me/app")
        #expect(wt.branch == "0123456")

        #expect(LocalRepoResolver.resolve(path: root.path) == nil)

        let scanned = LocalRepoResolver.scan(parent: root.appendingPathComponent("projects"))
        #expect(scanned.map(\.folderName) == ["app", "wt", "other"])
        #expect(scanned.last?.nameWithOwner == nil)
    }
}

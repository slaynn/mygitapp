import Foundation
import Testing
@testable import GitGardenerCore

@Suite struct PruneLogTests {
    private struct Fixture {
        let tmp: URL
        let origin: URL
        let repo: URL
        let log: PruneLog
        let commit: String
    }

    @discardableResult
    private func git(_ args: String..., in dir: URL) throws -> String {
        try Git(path: dir).run(["-c", "user.name=T", "-c", "user.email=t@t"] + args)
    }

    private func exists(_ ref: String, in dir: URL) -> Bool {
        (try? git("rev-parse", "--verify", "--quiet", ref, in: dir)) != nil
    }

    /// A clone whose pushed branch "feature" was deleted locally and on origin; its entry is logged.
    private func makeFixture(deletedOnOrigin: Bool = true) throws -> Fixture {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("gg-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let base = tmp.resolvingSymlinksInPath()
        let origin = base.appendingPathComponent("origin.git")
        let repo = base.appendingPathComponent("proj")
        try fm.createDirectory(at: origin, withIntermediateDirectories: true)
        try git("init", "--bare", "-b", "main", in: origin)
        try git("clone", origin.path, repo.path, in: base)
        try git("checkout", "-b", "main", in: repo)
        try "a".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git("add", "a.txt", in: repo)
        try git("commit", "-m", "a", in: repo)
        try git("push", "-u", "origin", "main", in: repo)
        try git("checkout", "-b", "feature", in: repo)
        try "b".write(to: repo.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try git("add", "b.txt", in: repo)
        try git("commit", "-m", "b", in: repo)
        try git("push", "-u", "origin", "feature", in: repo)
        let commit = try git("rev-parse", "HEAD", in: repo)
        try git("checkout", "main", in: repo)
        try git("branch", "-D", "feature", in: repo)
        try git("push", "origin", "--delete", "feature", in: repo)
        let log = PruneLog(fileURL: base.appendingPathComponent("log/prune-log.json"))
        try log.append(.init(repoPath: repo.path, branch: "feature", commit: commit, deletedOnOrigin: deletedOnOrigin))
        return Fixture(tmp: tmp, origin: origin, repo: repo, log: log, commit: commit)
    }

    @Test func restoreRecreatesLocalAndOriginBranch() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.tmp) }
        let entry = try #require(f.log.entries().first)
        #expect(f.log.isRestorable(entry))

        try f.log.restore(entry)

        #expect(try git("rev-parse", "feature", in: f.repo) == f.commit)
        #expect(exists("refs/heads/feature", in: f.origin))
        #expect(try git("rev-parse", "--abbrev-ref", "feature@{upstream}", in: f.repo) == "origin/feature")
        #expect(try f.log.entries().isEmpty)
    }

    @Test func restoreNeverMovesABranchRecreatedOnOrigin() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.tmp) }
        // Someone pushed a new "feature" at an ancestor: a plain push would fast-forward it.
        try git("push", "origin", "main:refs/heads/feature", in: f.repo)
        let theirs = try git("rev-parse", "main", in: f.repo)
        let entry = try #require(f.log.entries().first)

        #expect(throws: (any Error).self) { try f.log.restore(entry) }
        #expect(try git("rev-parse", "refs/heads/feature", in: f.origin) == theirs)
        #expect(!exists("refs/heads/feature", in: f.repo))
    }

    @Test func notRestorableWhenBranchExistsLocally() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.tmp) }
        try git("branch", "feature", f.commit, in: f.repo)
        let entry = try #require(f.log.entries().first)
        #expect(!f.log.isRestorable(entry))
    }

    @Test func notRestorableWhenCommitIsMissing() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.tmp) }
        let missing = PruneLog.Entry(
            repoPath: f.repo.path, branch: "ghost", commit: String(repeating: "0", count: 40), deletedOnOrigin: false
        )
        #expect(!f.log.isRestorable(missing))
    }

    @Test func entriesDropsThoseOlderThanThirtyDays() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.tmp) }
        let old = Date().addingTimeInterval(-31 * 86_400)
        try f.log.append(.init(repoPath: f.repo.path, branch: "old", commit: f.commit, date: old, deletedOnOrigin: false))

        #expect(try f.log.entries().map(\.branch) == ["feature"])
        #expect(try f.log.entries().map(\.branch) == ["feature"])
    }

    @Test func failedPushLeavesNothingHalfRestored() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.tmp) }
        try git("remote", "set-url", "origin", f.tmp.appendingPathComponent("missing.git").path, in: f.repo)
        let entry = try #require(f.log.entries().first)

        #expect(throws: (any Error).self) { try f.log.restore(entry) }
        #expect(!exists("refs/heads/feature", in: f.repo))
        #expect(f.log.isRestorable(entry))
    }
}

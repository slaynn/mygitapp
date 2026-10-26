import Foundation
import Testing
@testable import GitGardenerCore

@Suite struct RepoReaderTests {
    @discardableResult
    private func git(_ args: String..., in dir: URL) throws -> String {
        try Git(path: dir).run(args)
    }

    private func commit(_ message: String, in dir: URL) throws {
        try git("-c", "user.name=T", "-c", "user.email=t@t", "commit", "--allow-empty", "-m", message, in: dir)
    }

    @Test func scansBranchesWorktreesAndOriginOnly() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("gg-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let resolvedTmp = tmp.resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: tmp) }
        let root = resolvedTmp.appendingPathComponent("root")
        let origin = resolvedTmp.appendingPathComponent("origin.git")
        let repo = root.appendingPathComponent("proj")
        let other = resolvedTmp.appendingPathComponent("other")
        let wt = resolvedTmp.appendingPathComponent("wt")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: origin, withIntermediateDirectories: true)
        try git("init", "--bare", "-b", "main", in: origin)

        try git("clone", origin.path, repo.path, in: tmp)
        try git("checkout", "-b", "main", in: repo)
        try commit("init", in: repo)
        try git("push", "-u", "origin", "main", in: repo)
        for name in ["pushed-ahead", "gone-branch"] {
            try git("checkout", "-b", name, in: repo)
            try git("push", "-u", "origin", name, in: repo)
        }
        try git("checkout", "pushed-ahead", in: repo)
        try commit("a1", in: repo)
        try commit("a2", in: repo)
        try git("checkout", "-b", "local-only", "main", in: repo)
        try git("checkout", "main", in: repo)

        try git("clone", origin.path, other.path, in: tmp)
        try git("checkout", "-b", "remote-only", in: other)
        try commit("r", in: other)
        try git("push", "origin", "remote-only", in: other)
        try git("push", "origin", "--delete", "gone-branch", in: other)
        try git("fetch", "--prune", in: repo)

        try git("worktree", "add", "-b", "wt-branch", wt.path, in: repo)
        try "x".write(to: wt.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)

        let r = try RepoReader.read(at: repo)
        func branch(_ n: String) -> Repo.Branch? { r.branches.first { $0.name == n } }
        #expect(branch("pushed-ahead")?.location == .tracked(ahead: 2, behind: 0))
        #expect(branch("local-only")?.location == .localOnly)
        #expect(branch("gone-branch")?.location == .gone)
        #expect(r.originOnlyBranches == ["remote-only"])
        #expect(r.worktrees.count == 1)
        #expect(r.worktrees.first?.dirtyFileCount == 1)
        #expect(branch("wt-branch")?.worktreePath?.resolvingSymlinksInPath().path == wt.resolvingSymlinksInPath().path)
        #expect(branch("main")?.isCheckedOutInMainFolder == true)
    }

    @Test func worktreeWithDeletedFolderDoesNotBreakTheScan() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("gg-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: tmp) }
        let root = tmp.appendingPathComponent("root")
        let repo = root.appendingPathComponent("proj")
        let wt = tmp.appendingPathComponent("wt")
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        try git("init", "-b", "main", in: repo)
        try commit("init", in: repo)
        try git("worktree", "add", "-b", "wt-branch", wt.path, in: repo)
        try fm.removeItem(at: wt)

        let r = try RepoReader.read(at: repo)

        #expect(r.worktrees.map(\.dirtyFileCount) == [0])
    }

    @Test func refusesAFolderWithoutItsOwnGitDirectory() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("gg-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: tmp) }
        let inside = tmp.appendingPathComponent("inside")
        try fm.createDirectory(at: inside, withIntermediateDirectories: true)
        try git("init", "-b", "main", in: tmp)

        #expect(throws: RepoReader.NotARepo.self) { try RepoReader.read(at: inside) }
    }
}

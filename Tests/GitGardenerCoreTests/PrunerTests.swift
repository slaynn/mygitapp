import Foundation
import Testing
@testable import GitGardenerCore

@Suite struct PrunerTests {
    private struct Fixture {
        let repo: URL
        let worktree: URL
        let tmp: URL
        let pruner: Pruner
        let log: PruneLog
    }

    @discardableResult
    private func git(_ args: String..., in dir: URL) throws -> String {
        try Git(path: dir).run(["-c", "user.name=T", "-c", "user.email=t@t"] + args)
    }

    private func commit(_ file: String, in dir: URL) throws {
        try file.write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        try git("add", file, in: dir)
        try git("commit", "-m", file, in: dir)
    }

    private func exists(_ ref: String, in dir: URL) -> Bool {
        (try? git("rev-parse", "--verify", "--quiet", ref, in: dir)) != nil
    }

    private func makeFixture() throws -> Fixture {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("gg-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let base = tmp.resolvingSymlinksInPath()
        let origin = base.appendingPathComponent("origin.git")
        let repo = base.appendingPathComponent("proj")
        let worktree = base.appendingPathComponent("wt")
        try fm.createDirectory(at: origin, withIntermediateDirectories: true)
        try git("init", "--bare", "-b", "main", in: origin)
        try git("clone", origin.path, repo.path, in: base)
        try git("checkout", "-b", "main", in: repo)
        try commit("base.txt", in: repo)
        try git("push", "-u", "origin", "main", in: repo)

        for name in ["merged-local", "merged-origin", "merged-worktree", "merged-keep", "remote-only"] {
            try git("checkout", "-b", name, "main", in: repo)
            try commit("\(name).txt", in: repo)
            try git("push", "-u", "origin", name, in: repo)
            try git("checkout", "main", in: repo)
            try git("merge", "--no-ff", "-m", name, name, in: repo)
        }
        try git("push", "origin", "main", in: repo)
        try git("branch", "-D", "remote-only", in: repo)

        try git("checkout", "-b", "reviewed", "main~5", in: repo)
        try commit("reviewed.txt", in: repo)
        try git("push", "-u", "origin", "reviewed", in: repo)
        try git("checkout", "main", in: repo)

        try git("worktree", "add", worktree.path, "merged-worktree", in: repo)
        try "x".write(to: worktree.appendingPathComponent("dirty.txt"), atomically: true, encoding: .utf8)
        try git("worktree", "add", base.appendingPathComponent("wt-keep").path, "merged-keep", in: repo)

        let log = PruneLog(fileURL: base.appendingPathComponent("log/prune-log.json"))
        let pruner = Pruner(analyzer: BranchAnalyzer(conductorDatabaseURL: nil, t3Directory: nil, usesGitHub: false), log: log)
        return Fixture(repo: repo, worktree: worktree, tmp: tmp, pruner: pruner, log: log)
    }

    private func target(
        _ fixture: Fixture, _ branch: String?, verdict: SafetyVerdict = .safe, worktree: URL? = nil,
        keepsBranch: Bool = false, originOnly: Bool = false
    ) -> Pruner.Target {
        Pruner.Target(
            repoPath: fixture.repo, branch: branch, worktreePath: worktree,
            keepsBranch: keepsBranch, isOriginOnly: originOnly, verdict: verdict
        )
    }

    @Test func prunesLocallyAndRecordsCommit() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.tmp) }
        let commit = try git("rev-parse", "merged-local", in: f.repo)

        let plan = try await f.pruner.prepare([target(f, "merged-local")], alsoOnOrigin: false)
        let outcomes = await f.pruner.execute(plan)

        #expect(outcomes.allSatisfy { $0.errorMessage == nil })
        #expect(!exists("refs/heads/merged-local", in: f.repo))
        #expect(exists("origin/merged-local", in: f.repo))
        let entries = try f.log.entries()
        #expect(entries.count == 1)
        #expect(entries[0].branch == "merged-local")
        #expect(entries[0].commit == commit)
        #expect(entries[0].deletedOnOrigin == false)
    }

    @Test func prunesOnOriginWhenOptedIn() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.tmp) }

        let plan = try await f.pruner.prepare([target(f, "merged-origin")], alsoOnOrigin: true)
        _ = await f.pruner.execute(plan)

        #expect(!exists("refs/heads/merged-origin", in: f.repo))
        #expect(!exists("origin/merged-origin", in: f.repo))
        #expect(try f.log.entries().map(\.deletedOnOrigin) == [true])
    }

    @Test func reviewBranchBecomesRiskyWhenDeletedOnOrigin() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.tmp) }

        let plan = try await f.pruner.prepare([target(f, "reviewed", verdict: .review)], alsoOnOrigin: true)

        #expect(plan.items.map(\.verdict) == [.risky])
        #expect(plan.changedVerdicts.count == 1)
        #expect(plan.requiresTypedConfirmation)
    }

    @Test func prunesDirtyWorktreeAndItsBranch() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.tmp) }

        let plan = try await f.pruner.prepare(
            [target(f, "merged-worktree", verdict: .risky, worktree: f.worktree)], alsoOnOrigin: false
        )
        let outcomes = await f.pruner.execute(plan)

        #expect(outcomes.allSatisfy { $0.errorMessage == nil })
        #expect(!FileManager.default.fileExists(atPath: f.worktree.path))
        #expect(!exists("refs/heads/merged-worktree", in: f.repo))
    }

    @Test func keepsBranchWhenAsked() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.tmp) }
        let worktree = f.worktree.deletingLastPathComponent().appendingPathComponent("wt-keep")

        let plan = try await f.pruner.prepare(
            [target(f, "merged-keep", worktree: worktree, keepsBranch: true)], alsoOnOrigin: false
        )
        _ = await f.pruner.execute(plan)

        #expect(!FileManager.default.fileExists(atPath: worktree.path))
        #expect(exists("refs/heads/merged-keep", in: f.repo))
        #expect(try f.log.entries().isEmpty)
    }

    @Test func excludesBlockedTargets() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.tmp) }

        let plan = try await f.pruner.prepare([target(f, "main")], alsoOnOrigin: false)
        _ = await f.pruner.execute(plan)

        #expect(plan.items.isEmpty)
        #expect(exists("refs/heads/main", in: f.repo))
    }

    @Test func prunesOriginOnlyBranchOnOrigin() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.tmp) }
        let commit = try git("rev-parse", "origin/remote-only", in: f.repo)

        let plan = try await f.pruner.prepare([target(f, "remote-only", originOnly: true)], alsoOnOrigin: false)
        _ = await f.pruner.execute(plan)

        #expect(!exists("origin/remote-only", in: f.repo))
        let entries = try f.log.entries()
        #expect(entries.map(\.commit) == [commit])
        #expect(entries.map(\.deletedOnOrigin) == [true])
    }

    @Test func refusesWhenBranchMovedSinceThePlan() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.tmp) }

        let plan = try await f.pruner.prepare([target(f, "merged-local")], alsoOnOrigin: false)
        try git("checkout", "merged-local", in: f.repo)
        try commit("late.txt", in: f.repo)
        try git("checkout", "main", in: f.repo)
        let outcomes = await f.pruner.execute(plan)

        #expect(outcomes.first?.errorMessage != nil)
        #expect(exists("refs/heads/merged-local", in: f.repo))
        #expect(try f.log.entries().isEmpty)
    }

    @Test func refusesWorktreeThatBecameDirtySinceThePlan() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.tmp) }
        let worktree = f.worktree.deletingLastPathComponent().appendingPathComponent("wt-keep")

        let plan = try await f.pruner.prepare([target(f, "merged-keep", worktree: worktree)], alsoOnOrigin: false)
        #expect(plan.items.map(\.verdict) == [.safe])
        try "x".write(to: worktree.appendingPathComponent("late.txt"), atomically: true, encoding: .utf8)
        let outcomes = await f.pruner.execute(plan)

        #expect(outcomes.first?.errorMessage != nil)
        #expect(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("late.txt").path))
        #expect(exists("refs/heads/merged-keep", in: f.repo))
    }

    @Test func leavesOriginAloneWhenItMovedSinceThePlan() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.tmp) }

        let plan = try await f.pruner.prepare([target(f, "remote-only", originOnly: true)], alsoOnOrigin: false)
        let newer = try git("commit-tree", "origin/remote-only^{tree}", "-p", "origin/remote-only", "-m", "late", in: f.repo)
        try git("push", "origin", "\(newer):refs/heads/remote-only", in: f.repo)
        try git("update-ref", "refs/remotes/origin/remote-only", plan.items[0].commit, in: f.repo)
        let outcomes = await f.pruner.execute(plan)

        #expect(outcomes.first?.errorMessage != nil)
        #expect(try git("ls-remote", "origin", "refs/heads/remote-only", in: f.repo).hasPrefix(newer))
    }

    @Test func originCopyWithUnknownCommitsIsRisky() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.tmp) }
        let newer = try git("commit-tree", "merged-origin^{tree}", "-p", "merged-origin", "-m", "pushed by someone else", in: f.repo)
        try git("push", "origin", "\(newer):refs/heads/merged-origin", in: f.repo)

        let plan = try await f.pruner.prepare([target(f, "merged-origin")], alsoOnOrigin: true)

        #expect(plan.items.map(\.verdict) == [.risky])
        #expect(plan.requiresTypedConfirmation)
    }

    @Test func keptBranchIsLeftOnOrigin() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.tmp) }
        let worktree = f.worktree.deletingLastPathComponent().appendingPathComponent("wt-keep")

        let plan = try await f.pruner.prepare(
            [target(f, "merged-keep", worktree: worktree, keepsBranch: true)], alsoOnOrigin: true
        )
        _ = await f.pruner.execute(plan)

        #expect(plan.items.map(\.deletesOnOrigin) == [false])
        #expect(exists("origin/merged-keep", in: f.repo))
    }

    @Test func skipsTargetsThatNoLongerMatchTheScan() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.tmp) }

        let plan = try await f.pruner.prepare(
            [target(f, "main"), target(f, "vanished"), target(f, "merged-worktree", verdict: .risky)],
            alsoOnOrigin: false
        )

        #expect(plan.items.isEmpty)
        #expect(plan.skipped.map(\.reason) == [.blocked, .changed, .changed])
    }

    @Test func refusesToPruneWhenPruneLogIsUnreadable() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.tmp) }
        let file = f.tmp.resolvingSymlinksInPath().appendingPathComponent("log/prune-log.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "not json".write(to: file, atomically: true, encoding: .utf8)

        await #expect(throws: (any Error).self) {
            try await f.pruner.prepare([target(f, "merged-local")], alsoOnOrigin: false)
        }
        #expect(exists("refs/heads/merged-local", in: f.repo))
    }

    @Test func refusesDirtyWorktreeWithNewChangesSinceThePlan() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.tmp) }

        let plan = try await f.pruner.prepare(
            [target(f, "merged-worktree", verdict: .risky, worktree: f.worktree)], alsoOnOrigin: false
        )
        #expect(plan.items.map(\.dirtyFileCount) == [1])
        try "y".write(to: f.worktree.appendingPathComponent("later.txt"), atomically: true, encoding: .utf8)
        let outcomes = await f.pruner.execute(plan)

        #expect(outcomes.first?.errorMessage != nil)
        #expect(FileManager.default.fileExists(atPath: f.worktree.appendingPathComponent("later.txt").path))
        #expect(exists("refs/heads/merged-worktree", in: f.repo))
    }

    @Test func listsIgnoredFilesTheWorktreeRemovalDeletes() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.tmp) }
        let worktree = f.worktree.deletingLastPathComponent().appendingPathComponent("wt-keep")
        let info = f.repo.appendingPathComponent(".git/info")
        try FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
        try ".env\n".write(to: info.appendingPathComponent("exclude"), atomically: true, encoding: .utf8)
        try "SECRET=1".write(to: worktree.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        let plan = try await f.pruner.prepare([target(f, "merged-keep", worktree: worktree)], alsoOnOrigin: false)

        #expect(plan.items.map(\.verdict) == [.safe])
        #expect(plan.items.map(\.ignoredFiles) == [[".env"]])
    }

    @Test func logsWhatWasReallyDeletedWhenOriginFails() async throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.tmp) }

        let plan = try await f.pruner.prepare([target(f, "merged-origin")], alsoOnOrigin: true)
        try git("remote", "set-url", "origin", f.tmp.appendingPathComponent("missing.git").path, in: f.repo)
        let outcomes = await f.pruner.execute(plan)

        #expect(outcomes.first?.errorMessage != nil)
        #expect(!exists("refs/heads/merged-origin", in: f.repo))
        #expect(try f.log.entries().map(\.deletedOnOrigin) == [false])
    }

    @Test func deletesNothingWhenThePruneLogCannotBeWritten() async throws {
        let f = try makeFixture()
        let folder = f.tmp.resolvingSymlinksInPath().appendingPathComponent("log")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: f.tmp)
        }

        let plan = try await f.pruner.prepare([target(f, "merged-local")], alsoOnOrigin: false)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        let outcomes = await f.pruner.execute(plan)

        #expect(outcomes.first?.errorMessage != nil)
        #expect(exists("refs/heads/merged-local", in: f.repo))
    }
}

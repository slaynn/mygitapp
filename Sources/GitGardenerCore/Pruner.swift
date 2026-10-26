import Foundation

public struct Pruner: Sendable {
    public struct Target: Identifiable, Sendable {
        public var id: String { "\(repoPath.path)#\(branch ?? worktreePath?.path ?? "")" }
        public let repoPath: URL
        public let branch: String?
        public let worktreePath: URL?
        public var keepsBranch: Bool
        public let isOriginOnly: Bool
        /// The verdict the user saw; `Plan` carries the fresh one.
        public let verdict: SafetyVerdict

        public init(
            repoPath: URL, branch: String?, worktreePath: URL?,
            keepsBranch: Bool, isOriginOnly: Bool, verdict: SafetyVerdict
        ) {
            self.repoPath = repoPath
            self.branch = branch
            self.worktreePath = worktreePath
            self.keepsBranch = keepsBranch
            self.isOriginOnly = isOriginOnly
            self.verdict = verdict
        }
    }

    public struct Plan: Sendable {
        public struct Item: Sendable {
            public let target: Target
            public let verdict: SafetyVerdict
            /// What the branch pointed to when the plan was made (origin's commit for Origin Only).
            let commit: String
            /// Origin's commit to delete; nil when origin is left untouched.
            let originCommit: String?
            /// `git status` of the Worktree the user confirmed losing; execution refuses any other state.
            let worktreeChanges: String
            /// Ignored files and folders (`.env`, `node_modules/`...) the Worktree removal deletes as well.
            public let ignoredFiles: [String]

            public var deletesOnOrigin: Bool { originCommit != nil }
            public var dirtyFileCount: Int { worktreeChanges.isEmpty ? 0 : worktreeChanges.split(separator: "\n").count }
        }

        public struct Skipped: Sendable {
            public enum Reason: Sendable {
                /// The fresh verdict is Blocked.
                case blocked
                /// The branch, its Worktree or its Branch Location no longer match the selection.
                case changed
            }

            public let target: Target
            public let reason: Reason
        }

        public let items: [Item]
        public let changedVerdicts: [Item]
        public let skipped: [Skipped]
        public let alsoOnOrigin: Bool
        /// Losing unpushed work, or touching the shared origin, needs more than one click.
        public var requiresTypedConfirmation: Bool { items.contains { $0.verdict == .risky || $0.deletesOnOrigin } }
    }

    public struct Outcome: Sendable {
        public let target: Target
        public let errorMessage: String?
    }

    private struct Refusal: Error, CustomStringConvertible {
        let description: String
    }

    private let analyzer: BranchAnalyzer
    private let log: PruneLog

    public init(analyzer: BranchAnalyzer, log: PruneLog) {
        self.analyzer = analyzer
        self.log = log
    }

    public func prepare(_ targets: [Target], alsoOnOrigin: Bool) async throws -> Plan {
        // An unreadable Prune Log would make every deletion unrecoverable: refuse before deleting anything.
        _ = try log.entries()

        var fresh: [URL: (repo: Repo, reports: [String: BranchAnalyzer.Report])] = [:]
        for path in Set(targets.map(\.repoPath)) {
            let git = Git(path: path)
            if try git.run("remote").split(separator: "\n").contains("origin") {
                _ = try git.run("fetch", "--prune", "origin")
            }
            let repo = try RepoReader.read(at: path)
            fresh[path] = (repo, analyzer.analyze(repo))
        }

        var items: [Plan.Item] = []
        var skipped: [Plan.Skipped] = []
        for target in targets {
            guard let branch = target.branch, let scan = fresh[target.repoPath], let report = scan.reports[branch],
                  let item = item(for: target, branch: branch, in: scan.repo, verdict: report.verdict, alsoOnOrigin: alsoOnOrigin)
            else {
                skipped.append(Plan.Skipped(target: target, reason: .changed))
                continue
            }
            if item.verdict == .blocked {
                skipped.append(Plan.Skipped(target: target, reason: .blocked))
            } else {
                items.append(item)
            }
        }
        return Plan(
            items: items,
            changedVerdicts: items.filter { $0.verdict != $0.target.verdict },
            skipped: skipped,
            alsoOnOrigin: alsoOnOrigin
        )
    }

    /// nil when the fresh scan no longer matches what the user selected.
    private func item(
        for target: Target, branch: String, in repo: Repo, verdict freshVerdict: SafetyVerdict, alsoOnOrigin: Bool
    ) -> Plan.Item? {
        let local = repo.branches.first { $0.name == branch }
        if target.isOriginOnly {
            guard local == nil, repo.originOnlyBranches.contains(branch) else { return nil }
        } else {
            guard let local, Self.sameFolder(local.worktreePath, target.worktreePath) else { return nil }
        }

        let git = Git(path: repo.path)
        let originCommit = try? git.run("rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(branch)")
        let localCommit = try? git.run("rev-parse", "--verify", "--quiet", "refs/heads/\(branch)")
        guard let commit = target.isOriginOnly ? originCommit : localCommit else { return nil }

        var verdict = freshVerdict
        let deletesOnOrigin = target.isOriginOnly || (alsoOnOrigin && !target.keepsBranch && originCommit != nil)
        if deletesOnOrigin {
            if verdict == .review { verdict = .risky }
            // Origin may hold commits the local verdict never saw (pushed since, or an unrelated same-named branch).
            if !target.isOriginOnly, let originCommit,
               (try? git.run("merge-base", "--is-ancestor", originCommit, commit)) == nil {
                verdict = max(verdict, .risky)
            }
        }
        guard let status = try? Self.status(of: target.worktreePath) else { return nil }
        // A Dirty Worktree is Risky even when it was dirtied after the fresh scan.
        if !status.changes.isEmpty { verdict = max(verdict, .risky) }
        return Plan.Item(
            target: target,
            verdict: verdict,
            commit: commit,
            originCommit: deletesOnOrigin ? originCommit : nil,
            worktreeChanges: status.changes,
            ignoredFiles: status.ignored
        )
    }

    /// No Worktree, or a folder deleted by hand: nothing left to lose.
    private static func status(of worktree: URL?) throws -> (changes: String, ignored: [String]) {
        guard let worktree, FileManager.default.fileExists(atPath: worktree.path) else { return ("", []) }
        let lines = try Git(path: worktree).run("status", "--porcelain", "--ignored").split(separator: "\n")
        return (
            lines.filter { !$0.hasPrefix("!! ") }.joined(separator: "\n"),
            lines.filter { $0.hasPrefix("!! ") }.map { String($0.dropFirst(3)) }
        )
    }

    private static func sameFolder(_ a: URL?, _ b: URL?) -> Bool {
        a?.resolvingSymlinksInPath().path == b?.resolvingSymlinksInPath().path
    }

    public func execute(_ plan: Plan) async -> [Outcome] {
        plan.items.map { item in
            Outcome(target: item.target, errorMessage: prune(item))
        }
    }

    /// Returns an error message, or nil on success.
    private func prune(_ item: Plan.Item) -> String? {
        let target = item.target
        guard let branch = target.branch else { return "Nothing to prune without a branch" }
        let git = Git(path: target.repoPath)
        let deletesBranch = !target.keepsBranch && !target.isOriginOnly
        var logged: PruneLog.Entry?
        var deletedBranch = false
        var deletedOnOrigin = false
        var failure: String?

        do {
            // Nothing is deleted if the branch moved since the user confirmed.
            let ref = target.isOriginOnly ? "refs/remotes/origin/\(branch)" : "refs/heads/\(branch)"
            guard try git.run("rev-parse", "--verify", "--quiet", ref) == item.commit else {
                throw Refusal(description: "\(branch) changed since the confirmation, nothing was deleted")
            }
            if let worktree = target.worktreePath {
                let changes = try Self.status(of: worktree).changes
                guard changes == item.worktreeChanges else {
                    throw Refusal(description: "\(worktree.path) has different uncommitted changes since the confirmation, nothing was deleted")
                }
                try git.run(["worktree", "remove"] + (changes.isEmpty ? [] : ["--force"]) + ["--", worktree.path])
            }
            if deletesBranch || item.deletesOnOrigin {
                // Logged before deleting: a crash or a failed write must never leave a commit nobody can find again.
                let entry = PruneLog.Entry(
                    repoPath: target.repoPath.path, branch: branch, commit: item.commit, deletedOnOrigin: item.deletesOnOrigin
                )
                try log.append(entry)
                logged = entry
            }
            if deletesBranch {
                try git.run("branch", "-D", "--", branch)
                deletedBranch = true
            }
            if let originCommit = item.originCommit {
                // The lease refuses the deletion if someone pushed to origin since the plan was made.
                try git.run("push", "--force-with-lease=refs/heads/\(branch):\(originCommit)", "origin", ":refs/heads/\(branch)")
                deletedOnOrigin = true
            }
        } catch {
            failure = "\(error)"
        }

        // After a partial failure the entry must say what was really deleted, or restore would push a branch still on origin.
        if let logged, deletedBranch != deletesBranch || deletedOnOrigin != item.deletesOnOrigin {
            do {
                try log.remove(logged)
                if deletedBranch || deletedOnOrigin {
                    try log.append(PruneLog.Entry(
                        repoPath: logged.repoPath, branch: branch, commit: item.commit, date: logged.date, deletedOnOrigin: deletedOnOrigin
                    ))
                }
            } catch {
                failure = (failure ?? "") + " (Prune Log: \(error))"
            }
        }
        return failure
    }
}

import Foundation

public struct BranchAnalyzer: Sendable {
    public static let defaultConductorDatabaseURL: URL? = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.conductor.app/conductor.db")
    public static let defaultT3Directory: URL? = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".t3")

    public struct Report: Sendable {
        public let verdict: SafetyVerdict
        /// Why the branch is Blocked; empty for any other verdict.
        public let blockReasons: [BlockReason]
        public let mergedInto: [String]
        public let pullRequest: PullRequest?
        public let conductor: ConductorState?
        public let t3: T3Thread?
    }

    public enum BlockReason: Sendable {
        case protectedBranch, checkedOutInMainFolder, activeConductorWorkspace, activeT3Thread
    }

    public struct PullRequest: Sendable {
        public let number: Int
        public let state: String
        public let url: URL
    }

    public enum ConductorState: Sendable {
        case active, archived
    }

    /// The T3 Code thread working in a branch's Worktree (or that worked on the branch, once archived).
    public struct T3Thread: Sendable, Equatable {
        /// nil when T3 Code's database could not be read.
        public let title: String?
        public let isActive: Bool
    }

    private struct GitHubPullRequest: Decodable {
        let number: Int
        let headRefName: String
        let baseRefName: String
        let headRefOid: String
        let isCrossRepository: Bool
        let state: String
        let url: URL
    }

    private let baseBranchOverrides: [String: [String]]
    private let conductor: ConductorCatalog
    private let t3: T3Catalog
    private let githubPath: String?

    public init(
        baseBranchOverrides: [String: [String]] = [:],
        conductorDatabaseURL: URL? = BranchAnalyzer.defaultConductorDatabaseURL,
        t3Directory: URL? = BranchAnalyzer.defaultT3Directory,
        usesGitHub: Bool = true
    ) {
        self.baseBranchOverrides = baseBranchOverrides
        conductor = ConductorCatalog(databaseURL: conductorDatabaseURL)
        t3 = T3Catalog(directory: t3Directory)
        githubPath = usesGitHub ? Self.resolveGitHubPath() : nil
    }

    /// Reports are computed in parallel, each handed to `onReport` as soon as it is ready.
    public func analyze(_ repo: Repo, onReport: @escaping @Sendable (String, Report) -> Void = { _, _ in }) -> [String: Report] {
        let detector = MergeDetector(repoPath: repo.path, overrides: baseBranchOverrides[repo.path.path])
        // `gh` is a network call: it runs while the local merge checks do.
        let pullRequests = Background { githubPullRequests(for: repo) }

        let jobs: [() -> (String, Report)] =
            repo.branches.map { branch in
                {
                    let worktree = repo.worktrees.first { $0.branch == branch.name }
                    return (branch.name, report(
                        name: branch.name, ref: "refs/heads/\(branch.name)", location: branch.location,
                        isCheckedOutInMainFolder: branch.isCheckedOutInMainFolder,
                        worktree: worktree, worktreePath: branch.worktreePath,
                        repo: repo, detector: detector, pullRequests: pullRequests
                    ))
                }
            } + repo.originOnlyBranches.map { name in
                {
                    (name, report(
                        name: name, ref: "refs/remotes/origin/\(name)", location: nil,
                        isCheckedOutInMainFolder: false, worktree: nil, worktreePath: nil,
                        repo: repo, detector: detector, pullRequests: pullRequests
                    ))
                }
            }

        let lock = NSLock()
        nonisolated(unsafe) var reports: [String: Report] = [:]
        DispatchQueue.concurrentPerform(iterations: jobs.count) { index in
            let (name, report) = jobs[index]()
            lock.withLock { reports[name] = report }
            onReport(name, report)
        }
        return reports
    }

    /// The Base Branches merges are checked against: the override, or the auto-detected ones that exist.
    public func baseBranches(of repo: Repo) -> [String] {
        MergeDetector(repoPath: repo.path, overrides: baseBranchOverrides[repo.path.path]).baseBranches
    }

    /// `location` is nil for Origin Only branches.
    private func report(
        name: String, ref: String, location: Repo.BranchLocation?,
        isCheckedOutInMainFolder: Bool, worktree: Repo.Worktree?, worktreePath: URL?,
        repo: Repo, detector: MergeDetector, pullRequests allPullRequests: Background<[String: [GitHubPullRequest]]>
    ) -> Report {
        var mergedInto = detector.mergedInto(ref)
        let pullRequests = allPullRequests.wait()[name] ?? []
        // A merged PR only vouches for the exact commit it merged: a reused branch name or a fork's
        // same-named branch with newer commits must not be reported as Merged.
        let tip = try? Git(path: repo.path).run("rev-parse", "--verify", "--quiet", ref)
        for pr in pullRequests where pr.state == "MERGED" && !pr.isCrossRepository && pr.headRefOid == tip
            && detector.baseBranches.contains(pr.baseRefName) {
            if !mergedInto.contains(pr.baseRefName) { mergedInto.append(pr.baseRefName) }
        }
        let conductorState = conductor.state(repoPath: repo.path, branch: name, worktreePath: worktreePath)
        let t3Thread = t3.thread(repoPath: repo.path, branch: name, worktreePath: worktreePath)
        let latest = pullRequests.max { $0.number < $1.number }

        var blockReasons: [BlockReason] = []
        if detector.protectedBranches.contains(name) { blockReasons.append(.protectedBranch) }
        if isCheckedOutInMainFolder { blockReasons.append(.checkedOutInMainFolder) }
        if conductorState == .active { blockReasons.append(.activeConductorWorkspace) }
        if t3Thread?.isActive == true { blockReasons.append(.activeT3Thread) }

        var verdict: SafetyVerdict
        if !blockReasons.isEmpty {
            verdict = .blocked
        } else if !mergedInto.isEmpty {
            verdict = .safe
        } else if case let .tracked(ahead, _) = location, ahead == 0 {
            verdict = .review
        } else {
            verdict = .risky
        }
        if let worktree, worktree.dirtyFileCount > 0 {
            verdict = max(verdict, .risky)
        }
        return Report(
            verdict: verdict,
            blockReasons: blockReasons,
            mergedInto: mergedInto,
            pullRequest: latest.map { PullRequest(number: $0.number, state: $0.state, url: $0.url) },
            conductor: conductorState,
            t3: t3Thread
        )
    }

    /// A value computed on another thread, waited for only when needed.
    private final class Background<Value: Sendable>: @unchecked Sendable {
        private let group = DispatchGroup()
        private var value: Value?

        init(_ work: @escaping @Sendable () -> Value) {
            group.enter()
            // A dedicated thread: on the GCD pool, the `concurrentPerform` workers blocked in `wait()`
            // can take every thread and the work never starts (deadlock).
            Thread {
                self.value = work()
                self.group.leave()
            }.start()
        }

        func wait() -> Value {
            group.wait()
            return value!
        }
    }

    private func githubPullRequests(for repo: Repo) -> [String: [GitHubPullRequest]] {
        guard let githubPath,
              let output = try? Git.execute(
                  githubPath,
                  ["pr", "list", "--state", "all", "--limit", "500", "--json", "number,headRefName,headRefOid,isCrossRepository,baseRefName,state,url"],
                  currentDirectory: repo.path
              ),
              let pullRequests = try? JSONDecoder().decode([GitHubPullRequest].self, from: Data(output.utf8))
        else { return [:] }
        return Dictionary(grouping: pullRequests, by: \.headRefName)
    }

    static func resolveGitHubPath() -> String? {
        let fm = FileManager.default
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
        if let path = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) { return path }
        // Login shells may print banners: only trust a last line that is an executable file.
        let output = try? Git.execute("/bin/zsh", ["-lc", "command -v gh"])
        let path = output?.split(separator: "\n").last.map(String.init)
        return path.flatMap { fm.isExecutableFile(atPath: $0) ? $0 : nil }
    }
}
